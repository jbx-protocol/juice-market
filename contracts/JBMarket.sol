// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@jbx-protocol/contracts-v2/contracts/interfaces/IJBSplitsStore.sol';
import '@jbx-protocol/contracts-v2/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/contracts-v2/contracts/libraries/JBTokens.sol';
import '@jbx-protocol/contracts-v2/contracts/JBETHERC20ProjectPayer.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@paulrberg/contracts/math/PRBMath.sol';

import './interfaces/IJBMarket.sol';

//*********************************************************************//
// --------------------------- custom errors ------------------------- //
//*********************************************************************//
error UNAUTHORIZED();
error MARKET_LACKS_UNAUTHORIZATION();
error NOTHING_TO_SETTLE();
error NOT_LISTED();
error INSUFFICIENT_AMOUNT();
error UNKOWN_COLLECTION();
error EMPTY_COLLECTION();
error TERMINAL_IN_SPLIT_ZERO_ADDRESS();

contract JBMarket is IJBMarket, JBETHERC20ProjectPayer, ReentrancyGuard {
  event Settle(IERC721 indexed collection, uint256 indexed itemId, address caller);

  //*********************************************************************//
  // ---------------- public immutable stored properties --------------- //
  //*********************************************************************//

  /**
    @notice
    The contract that stores splits for each project.
  */
  IJBSplitsStore public immutable splitsStore;

  /**
    @notice
    The ID of the project that should receive market fees.
  */
  uint256 public immutable projectId;

  //*********************************************************************//
  // --------------------- public stored properties -------------------- //
  //*********************************************************************//

  /**
    @notice
    The minimum price acceptable to purchase an item, as a fixed point number with 18 decimals.

    _collection The collection to which the item being given a minimum belongs.
    _item The item being given a minimum belongs.
  */
  mapping(IERC721 => mapping(uint256 => uint256)) public override minPrice;

  /**
    @notice
    The pending purchase amount to settle once an item has been bought.

    _collection The collection to which the item belongs whose purchase settlement is pending.
    _item The item whose purchase settlement is pending.
  */
  mapping(IERC721 => mapping(uint256 => uint256)) public override pendingSettleAmount;

  /**
    @notice
    The owner who was sent the item whose purchase amount is pending settlement

    _collection The collection to which the item belongs whose purchase settlement is pending.
    _item The item whose purchase settlement is pending.
  */
  mapping(IERC721 => mapping(uint256 => address)) public override ownerOfPendingSettlement;

  //*********************************************************************//
  // -------------------------- constructor ---------------------------- //
  //*********************************************************************//

  /** 
    @param _projectId The ID of the project that should receive market fees.
    @param _splitsStore A contract that stores splits for each project.
    @param _directory A contract storing directories of terminals and controllers for each project.
  */
  constructor(
    uint256 _projectId,
    IJBSplitsStore _splitsStore,
    IJBDirectory _directory
  ) JBETHERC20ProjectPayer(0, payable(address(0)), false, '', bytes(''), _directory, address(0)) {
    projectId = _projectId;
    splitsStore = _splitsStore;
  }

  /**
    @notice 
    List an item.

    @param _collection The collection from which items are being listed.
    @param _items The items being listed.
    @param _memo A memo to pass along to the emitted event.
   **/
  function list(
    IERC721 _collection,
    JBMarketCollectionItem[] calldata _items,
    string calldata _memo
  ) external override nonReentrant {
    // The collection must contains items.
    if (_collection == IERC721(address(0))) revert UNKOWN_COLLECTION();

    // The collection must contains items.
    if (_items.length == 0) revert EMPTY_COLLECTION();

    // List each collection item.
    for (uint256 _i; _i < _items.length; _i++) {
      // The ID of the collection item.
      uint256 _itemId = _items[_i].id;

      // The minimum price the piece should be sold for.
      uint256 _itemMinPrice = _items[_i].minPrice;

      // The splits to whom the sale funds should be routable to.
      JBSplit[] memory _splits = _items[_i].splits;

      // The address doing the listing must be owner or approved to manage this collection item.
      if (
        _collection.ownerOf(_itemId) != msg.sender &&
        _collection.getApproved(_itemId) != msg.sender &&
        !_collection.isApprovedForAll(_collection.ownerOf(_itemId), msg.sender)
      ) revert UNAUTHORIZED();

      // This market must be approved to manage this collection item.
      if (
        _collection.getApproved(_itemId) != address(this) &&
        !_collection.isApprovedForAll(_collection.ownerOf(_itemId), address(this))
      ) revert MARKET_LACKS_UNAUTHORIZATION();

      // Set the splits in the store.
      splitsStore.set(projectId, uint256(uint160(address(_collection))), _itemId, _splits);

      // Store the minimum price that the itme should be sold at.
      minPrice[_collection][_itemId] = _itemMinPrice;

      emit List(_collection, _itemId, _splits, _itemMinPrice, _memo, msg.sender);
    }
  }

  /** 
    @notice
    Buy a listed item.

    @param _collection The collection from which an item is being bought.
    @param _itemId The ID of the item being bought.
    @param _beneficiary The address to which the item should be sent once bought.
    @param _shouldSettle Whether the purchase should be settled right away.
    @param _memo A memo to pass along to the emitted event.
  */
  function buy(
    IERC721 _collection,
    uint256 _itemId,
    address _beneficiary,
    bool _shouldSettle,
    string calldata _memo
  ) external payable override nonReentrant {
    // Get a reference to the minimum price that should be accepted.
    uint256 _minPrice = minPrice[_collection][_itemId];

    // Can't buy if there's no price.
    if (_minPrice == 0) revert NOT_LISTED();

    // Can't buy if sent amount is less than the minimum.
    if (_minPrice > msg.value) revert INSUFFICIENT_AMOUNT();

    // Set the amount to be settled as a result of the purchase.
    pendingSettleAmount[_collection][_itemId] = msg.value;

    // Set the owner to whom the benenficiary of the sale.
    ownerOfPendingSettlement[_collection][_itemId] = _beneficiary;

    if (_shouldSettle) _settle(_collection, _itemId);

    // Transfer the item.
    _collection.safeTransferFrom(address(this), _beneficiary, _itemId);

    emit Buy(_collection, _itemId, _beneficiary, msg.value, _memo, msg.sender);
  }

  /** 
    @notice
    Settles a purchase to the intended splits. 

    @param _collection The collection from which a sale is being settled.
    @param _itemId The ID of the sold item whose purchase is being settled.
  */
  function settle(IERC721 _collection, uint256 _itemId) external override nonReentrant {
    _settle(_collection, _itemId);
  }

  /** 
    @notice
    Delist the item from the market. 

    @param _collection The collection to which the item being listed belongs.
    @param _itemId The ID of the item being delisted.
  */
  function delist(IERC721 _collection, uint256 _itemId) external override nonReentrant {
    // Make sure the item isn't already listed.
    if (minPrice[_collection][_itemId] == 0) revert NOT_LISTED();

    // The address doing the delisting must be owner or approved to manage this collection item.
    if (
      _collection.ownerOf(_itemId) != msg.sender &&
      _collection.getApproved(_itemId) != msg.sender &&
      !_collection.isApprovedForAll(_collection.ownerOf(_itemId), msg.sender)
    ) revert UNAUTHORIZED();

    // Set the price to 0.
    minPrice[_collection][_itemId] = 0;

    emit Delist(_collection, _itemId, msg.sender);
  }

  //*********************************************************************//
  // --------------------- private helper functions -------------------- //
  //*********************************************************************//

  /** 
    @notice
    Settles a purchase to the intended splits. 

    @param _collection The collection from which a sale is being settled.
    @param _itemId The ID of the sold item whose purchase is being settled.
  */
  function _settle(IERC721 _collection, uint256 _itemId) private {
    // Get a reference to the amount of the settlement.
    uint256 _pendingSettleAmount = pendingSettleAmount[_collection][_itemId];

    // Can't settle if there's nothing to settle.
    if (_pendingSettleAmount == 0) revert NOTHING_TO_SETTLE();

    // Set the leftover amount to the initial amount.
    uint256 _leftoverAmount = _pendingSettleAmount;

    // Get a reference to the item's settlement splits.
    JBSplit[] memory _splits = splitsStore.splitsOf(
      projectId,
      uint256(uint160(address(_collection))),
      _itemId
    );

    // Settle between all splits.
    for (uint256 i = 0; i < _splits.length; i++) {
      // Get a reference to the split being iterated on.
      JBSplit memory _split = _splits[i];

      // The amount to send towards the split.
      uint256 _settleAmount = PRBMath.mulDiv(
        _pendingSettleAmount,
        _split.percent,
        JBConstants.SPLITS_TOTAL_PERCENT
      );

      if (_settleAmount > 0) {
        // Transfer tokens to the mod.
        // If there's an allocator set, transfer to its `allocate` function.
        if (_split.allocator != IJBSplitAllocator(address(0))) {
          // Create the data to send to the allocator.
          JBSplitAllocationData memory _data = JBSplitAllocationData(
            _settleAmount,
            18,
            projectId,
            _itemId,
            _split
          );
          // Trigger the allocator's `allocate` function.
          _split.allocator.allocate{value: _settleAmount}(_data);
          // Otherwise, if a project is specified, make a payment to it.
        } else if (_split.projectId != 0) {
          _pay(
            _split.projectId,
            JBTokens.ETH,
            _settleAmount,
            _split.beneficiary,
            0,
            _split.preferClaimed,
            '',
            bytes('')
          );
        } else {
          // If there's a beneficiary, send the funds directly to the beneficiary. Otherwise send to the msg.sender.
          Address.sendValue(
            _split.beneficiary != address(0) ? _split.beneficiary : payable(msg.sender),
            _settleAmount
          );
        }
        // Subtract from the amount to be sent to the beneficiary.
        _leftoverAmount = _leftoverAmount - _settleAmount;
      }

      emit SettleToSplit(_collection, _itemId, _split, _settleAmount, msg.sender);
    }

    // The address who received the item whose purchase is being settled.
    address _ownerOfPendingSettlement = ownerOfPendingSettlement[_collection][_itemId];

    // Send any leftover amount to the owner to who received the purchased item.
    if (_leftoverAmount > 0) Address.sendValue(payable(_ownerOfPendingSettlement), _leftoverAmount);

    // Reset the pending settlement amount for the item now that it's been settled.
    pendingSettleAmount[_collection][_itemId] = 0;

    // Reset the owner of the pending settlement amount for the item now that it's been settled.
    ownerOfPendingSettlement[_collection][_itemId] = address(0);

    emit Settle(
      _collection,
      _itemId,
      _ownerOfPendingSettlement,
      _pendingSettleAmount,
      _leftoverAmount,
      msg.sender
    );
  }
}

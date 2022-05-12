// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@jbx-protocol/contracts-v2/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/contracts-v2/contracts/libraries/JBTokens.sol';
import '@jbx-protocol/contracts-v2/contracts/JBETHERC20SplitsPayer.sol';
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
error TERMINAL_NOT_FOUND();
error FEE_TOO_HIGH();
error INVALID_AMOUNT();

contract JBMarket is IJBMarket, JBETHERC20SplitsPayer {
  //*********************************************************************//
  // --------------------- private stored constants -------------------- //
  //*********************************************************************//

  /**
    @notice
    Maximum fee that can be set for a funding cycle configuration.

    @dev
    Out of MAX_FEE (50_000_000 / 1_000_000_000)
  */
  uint256 private constant _FEE_CAP = 50_000_000;

  //*********************************************************************//
  // ---------------- public immutable stored properties --------------- //
  //*********************************************************************//

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

  /**
    @notice
    The market fee percent.

    @dev
    Out of MAX_FEE (25_000_000 / 1_000_000_000)
  */
  uint256 public override fee = 25_000_000; // 2.5%

  //*********************************************************************//
  // -------------------------- constructor ---------------------------- //
  //*********************************************************************//

  /** 
    @param _projectId The ID of the project that should receive market fees.
    @param _splitsStore A contract that stores splits for each project.
    @param _owner The address that will own this contract.
  */
  constructor(
    uint256 _projectId,
    IJBSplitsStore _splitsStore,
    address _owner
  )
    JBETHERC20SplitsPayer(
      0,
      0,
      0,
      _splitsStore,
      0,
      payable(address(0)),
      false,
      '',
      bytes(''),
      false,
      _owner
    )
  {
    projectId = _projectId;
  }

  //*********************************************************************//
  // --------------------- external transactions ----------------------- //
  //*********************************************************************//

  /**
    @notice 
    List an item.

    @param _collection The collection from which items are being listed.
    @param _items The items being listed. The amount must fit in a uint88.
    @param _memo A memo to pass along to the emitted event.
   **/
  function list(
    IERC721 _collection,
    JBMarketCollectionItem[] calldata _items,
    string calldata _memo
  ) external override nonReentrant {
    // The collection must exist.
    if (_collection == IERC721(address(0))) revert UNKOWN_COLLECTION();

    // The collection must contains items.
    if (_items.length == 0) revert EMPTY_COLLECTION();

    // Get a reference to the number of items.
    uint256 _numItems = _items.length;

    // List each collection item.
    for (uint256 _i; _i < _numItems; _i++) {
      // The ID of the collection item.
      uint256 _itemId = _items[_i].id;

      // The minimum price the piece should be sold for.
      uint256 _itemMinPrice = _items[_i].minPrice;

      // The amount must fit in a uint88.
      if (_itemMinPrice > type(uint88).max) revert INVALID_AMOUNT();

      // The token that should be accepted for the sale.
      address _itemMinPriceToken = _items[_i].minPriceToken;

      // The number of decimals in the token that should be accepted.
      uint256 _itemMinPriceDecimals = uint256(_items[_i].minPriceDecimals);

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

      {
        // min price is bits 0-87.
        uint256 _packedMinPrice = uint88(_items[_i].minPrice);
        // min price token in bits 88-247.
        _packedMinPrice |= uint256(uint160(_items[_i].minPriceToken)) << 88;
        // min price decimals in bits 248-255.
        _packedMinPrice |= uint256(uint160(_items[_i].minPriceDecimals)) << 248;
        // Store the minimum price, token, and num decimals that the item should be sold at.
        minPrice[_collection][_itemId] = _packedMinPrice;
      }

      emit List(
        _collection,
        _itemId,
        _splits,
        _itemMinPrice,
        _itemMinPriceToken,
        _itemMinPriceDecimals,
        _memo,
        msg.sender
      );
    }
  }

  /** 
    @notice
    Buy a listed item.

    @param _collection The collection from which an item is being bought.
    @param _itemId The ID of the item being bought.
    @param _amount The amount being paid, in terms of the token the sale should be made in terms of.
    @param _beneficiary The address to which the item should be sent once bought.
    @param _shouldSettle Whether the purchase should be settled right away.
    @param _memo A memo to pass along to the emitted event.
  */
  function buy(
    IERC721 _collection,
    uint256 _itemId,
    uint256 _amount,
    address _beneficiary,
    bool _shouldSettle,
    string calldata _memo
  ) external payable override nonReentrant {
    // Get a reference to the packed min price.
    uint256 _packedMinPrice = minPrice[_collection][_itemId];

    // Get a reference to the minimum price that should be accepted.
    uint256 _minPrice = uint256(uint88(_packedMinPrice));

    // Get a reference to the token that the sale should be accepted in.
    address _minPriceToken = address(uint160(_packedMinPrice >> 88));

    // ETH shouldn't be sent to this contract if the sale token isn't ETH.
    if (_minPriceToken != JBTokens.ETH) {
      if (msg.value > 0) revert NO_MSG_VALUE_ALLOWED();

      // Transfer tokens to this terminal from the msg sender.
      IERC20(_minPriceToken).transferFrom(msg.sender, payable(address(this)), _amount);
    }
    // If the sale token is ETH, override _amount with msg.value.
    else _amount = msg.value;

    // Can't buy if there's no price.
    if (_minPrice == 0) revert NOT_LISTED();

    // Can't buy if sent amount is less than the minimum.
    if (_minPrice > _amount) revert INSUFFICIENT_AMOUNT();

    // The amount must fit in a uint88.
    if (_amount > type(uint88).max) revert INVALID_AMOUNT();

    // Get a reference to the number of decimals in the token that the sale should be accepted in.
    uint256 _minPriceDecimals = uint256(uint8(_packedMinPrice >> 248));

    if (_shouldSettle)
      _settle(_collection, _itemId, _amount, _minPriceToken, _minPriceDecimals, _beneficiary);
    else {
      // amount is bits 0-87.
      uint256 _packedPendingSettlementAmount = uint88(_amount);
      // amount token in bits 88-247.
      _packedPendingSettlementAmount |= uint256(uint160(_minPriceToken)) << 88;
      // amount decimals in bits 248-255.
      _packedPendingSettlementAmount |= uint256(uint160(_minPriceDecimals)) << 248;
      // Set the amount to be settled as a result of the purchase.
      pendingSettleAmount[_collection][_itemId] = _packedPendingSettlementAmount;

      // Set the benenficiary of the sale.
      ownerOfPendingSettlement[_collection][_itemId] = _beneficiary;
    }

    // Transfer the item.
    _collection.safeTransferFrom(_collection.ownerOf(_itemId), _beneficiary, _itemId);

    emit Buy(_collection, _itemId, _beneficiary, msg.value, _memo, msg.sender);
  }

  /** 
    @notice
    Settles a purchase to the intended splits. 

    @param _collection The collection from which a sale is being settled.
    @param _itemId The ID of the sold item whose purchase is being settled.
  */
  function settle(IERC721 _collection, uint256 _itemId) external override nonReentrant {
    // Get a reference to the packed min price.
    uint256 _packedPendingSettleAmount = pendingSettleAmount[_collection][_itemId];

    // Get a reference to the pending settle amount price.
    uint256 _amount = uint256(uint88(_packedPendingSettleAmount));

    // Can't settle if there's nothing to settle.
    if (_amount == 0) revert NOTHING_TO_SETTLE();

    // Get a reference to the token that the settle amount is in.
    address _amountToken = address(uint160(_packedPendingSettleAmount >> 88));

    // Get a reference to the number of decimals in the pending settle amount.
    uint256 _amountDecimals = uint256(uint8(_packedPendingSettleAmount >> 248));

    // Get the beneficiary of any leftover amount once splits are settled.
    address _leftoverBeneficiary = ownerOfPendingSettlement[_collection][_itemId];

    // Settle.
    _settle(_collection, _itemId, _amount, _amountToken, _amountDecimals, _leftoverBeneficiary);

    // Reset the pending settlement amount for the item now that it's been settled.
    pendingSettleAmount[_collection][_itemId] = 0;

    // Reset the owner of the pending settlement amount for the item now that it's been settled.
    ownerOfPendingSettlement[_collection][_itemId] = address(0);
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

  /**
    @notice
    Allows the fee to be updated.

    @dev
    Only the owner of this contract can change the fee.

    @param _fee The new fee, out of MAX_FEE.
  */
  function setFee(uint256 _fee) external virtual override onlyOwner {
    // The provided fee must be within the max.
    if (_fee > _FEE_CAP) revert FEE_TOO_HIGH();

    // Store the new fee.
    fee = _fee;

    emit SetFee(_fee, msg.sender);
  }

  //*********************************************************************//
  // --------------------- private helper functions -------------------- //
  //*********************************************************************//

  /** 
    @notice
    Settles a purchase to the intended splits. 

    @param _collection The collection from which a sale is being settled.
    @param _itemId The ID of the sold item whose purchase is being settled.
    @param _amount The amount to settle. 
    @param _token The token being used to settle.
    @param _decimals The number of decimals in the token being used to settle.
    @param _leftoverBeneficiary The address who should be the benficiary of any leftover amount once split's are settled. 
  */
  function _settle(
    IERC721 _collection,
    uint256 _itemId,
    uint256 _amount,
    address _token,
    uint256 _decimals,
    address _leftoverBeneficiary
  ) private {
    // Get the fee amount;
    uint256 _fee = fee == 0 ? 0 : _feeAmount(_amount);

    // Pay to the splits.
    uint256 _leftoverAmount = _payToSplits(
      projectId,
      uint256(uint160(address(_collection))),
      _itemId,
      _token,
      _amount - _fee,
      _decimals
    );

    // Take the fee.
    if (_fee > 0) _takeFee(_fee, _token, _leftoverBeneficiary);

    // Send any leftover amount to the owner to who received the purchased item.
    if (_leftoverAmount > 0) Address.sendValue(payable(_leftoverBeneficiary), _leftoverAmount);

    emit Settle(_collection, _itemId, _leftoverBeneficiary, _amount, _leftoverAmount, msg.sender);
  }

  /**
    @notice
    Takes a fee into the specified project.

    @param _fee The amount of the fee to take, as a floating point number with 18 decimals.
    @param _token The token the fee is being paid in.
    @param _beneficiary The address to mint the platforms tokens for.
  */
  function _takeFee(
    uint256 _fee,
    address _token,
    address _beneficiary
  ) private {
    _processFee(_fee, _token, _beneficiary); // Take the fee.
  }

  /** 
    @notice 
    Returns the fee amount based on the provided amount for the specified project.

    @param _amount The amount that the fee is based on, as a fixed point number with the same amount of decimals as this terminal.

    @return The amount of the fee, as a fixed point number with the same amount of decimals as this terminal.
  */
  function _feeAmount(uint256 _amount) private view returns (uint256) {
    // The amount of tokens from the `_amount` to pay as a fee.
    return _amount - PRBMath.mulDiv(_amount, JBConstants.MAX_FEE, fee + JBConstants.MAX_FEE);
  }

  /**
    @notice
    Process a fee of the specified amount.

    @param _amount The fee amount, as a floating point number with 18 decimals.
    @param _token The token the fee is being paid in.
    @param _beneficiary The address to mint the platform's tokens for.
  */

  function _processFee(
    uint256 _amount,
    address _token,
    address _beneficiary
  ) private {
    // Get the terminal for the protocol project.
    IJBPaymentTerminal _terminal = directory.primaryTerminalOf(projectId, JBTokens.ETH);

    // Send the payment.
    _terminal.pay{value: _amount}(
      projectId,
      _amount,
      _token,
      _beneficiary,
      0,
      false,
      '',
      bytes('')
    ); // Use the external pay call of the correct terminal.
  }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@jbx-protocol/contracts-v2/contracts/interfaces/IJBSplitsStore.sol';
import '../interfaces/IJBMarketPriceResolver.sol';
import '../structs/JBCollectionItem.sol';

interface IJBMarket {
  event List(
    IERC721 indexed collection,
    JBMarketCollectionItem[] items,
    JBSplit[] splits,
    string memo,
    address caller
  );
  event Buy(
    IERC721 indexed collection,
    uint256 indexed itemId,
    address beneficiary,
    uint256 amount,
    string memo,
    address caller
  );
  event Delist(IERC721 indexed collection, uint256 indexed itemId, address caller);

  event Settle(
    IERC721 indexed collection,
    uint256 indexed itemId,
    address beneficiary,
    uint256 amount,
    uint256 beneficiaryDistributionAmount,
    address caller
  );

  event SettleToSplit(
    IERC721 indexed collection,
    uint256 indexed itemId,
    JBSplit split,
    uint256 amount,
    address caller
  );

  event SetFee(uint256 fee, address caller);

  function minPrice(IERC721 _collection, uint256 _itemId) external returns (uint256);

  function priceResolver(IERC721 _collection) external returns (IJBMarketPriceResolver);

  function pendingSettleAmount(IERC721 _collection, uint256 _itemId) external returns (uint256);

  function ownerOfPendingSettlement(IERC721 _collection, uint256 _itemId)
    external
    returns (address);

  function fee() external view returns (uint256);

  function setFee(uint256 _fee) external;

  function list(
    IERC721 _collection,
    JBMarketCollectionItem[] calldata _items,
    IJBMarketPriceResolver _priceResolver,
    JBSplit[] calldata _splitGroup,
    string memory _memo
  ) external;

  function buy(
    IERC721 _collection,
    uint256 _itemId,
    uint256 _amount,
    address _beneficiary,
    bool _shouldSettle,
    string calldata _memo
  ) external payable;

  function settle(IERC721 _collection, uint256 _itemId) external;

  function delist(IERC721 _collection, uint256 _itemId) external;
}

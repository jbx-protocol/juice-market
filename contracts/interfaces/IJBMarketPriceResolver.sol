// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import '@jbx-protocol/contracts-v2/contracts/interfaces/IJBSplitsStore.sol';
import '../structs/JBCollectionItem.sol';

interface IJBMarketPriceResolver {
  function priceFor(
    IERC721 _collection,
    uint256 _itemId,
    address _buyer,
    address _beneficiary
  )
    external
    view
    returns (
      uint256 minPrice,
      address minPriceToken,
      uint256 minPriceDecimals
    );
}

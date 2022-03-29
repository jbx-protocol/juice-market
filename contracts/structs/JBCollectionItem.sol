// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@jbx-protocol/contracts-v2/contracts/structs/JBSplit.sol';

struct JBMarketCollectionItem {
  uint256 id;
  uint256 minPrice;
  JBSplit[] splits;
}

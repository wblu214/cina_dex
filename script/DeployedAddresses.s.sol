// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DeployedAddresses
/// @notice Central place to record deployed addresses for different networks.
/// @dev 初始先用 address(0) 占位，你在部署完脚本后再把真实地址填进来即可。
library DeployedAddresses {
    // BSC Mainnet (chainId 56)
    address internal constant BSC_MAINNET_USDT = address(0); // TODO: 填入 BSC 主网 USDT 地址
    address internal constant BSC_MAINNET_PRICE_FEED =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE; // BNB/USD Chainlink feed

    // BSC Testnet (chainId 97)
    address internal constant BSC_TESTNET_USDT =
        0xBd8627a3b43d45488e6f15c92Ec3A8A277B1f79d; // MockUSDT on BSC Testnet
    address internal constant BSC_TESTNET_PRICE_FEED = address(0); // TODO: 填入你选择的 Binance Oracle / MockV3Aggregator 地址
}

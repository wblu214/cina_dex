// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DeployedAddresses
/// @notice Central place to record deployed addresses for different networks.
/// @dev 初始先用 address(0) 占位，你在部署完脚本后再把真实地址填进来即可。
library DeployedAddresses {
    // BSC Mainnet (chainId 56)
    // 官方 USDT BEP20 合约
    address internal constant BSC_MAINNET_USDT =
        0x55d398326f99059fF775485246999027B3197955;
    // Chainlink BNB/USD 价格预言机
    address internal constant BSC_MAINNET_PRICE_FEED =
        0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    // BSC Testnet (chainId 97)
    // 你部署的 MockUSDT 地址
    address internal constant BSC_TESTNET_USDT =
        0xBd8627a3b43d45488e6f15c92Ec3A8A277B1f79d;
    // Binance Oracle BNB/USD 测试网 Feed Adapter
    address internal constant BSC_TESTNET_PRICE_FEED =
        0x1A26d803C2e796601794f8C5609549643832702C;
}

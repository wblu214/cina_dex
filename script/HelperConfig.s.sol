// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {DeployedAddresses} from "./DeployedAddresses.s.sol";

/// @title HelperConfig
/// @notice Network-specific configuration (USDT + price feed) for different chains.
contract HelperConfig is Script {
    struct NetworkConfig {
        address usdt;      // USDT 或 MockUSDT 地址
        address priceFeed; // ETH/BNB 对 USD 的预言机地址
    }

    // chainId => 配置
    mapping(uint256 chainId => NetworkConfig) internal networkConfigs;

    constructor() {
        // BSC Mainnet
        networkConfigs[56] = NetworkConfig({
            usdt: DeployedAddresses.BSC_MAINNET_USDT,
            priceFeed: DeployedAddresses.BSC_MAINNET_PRICE_FEED
        });

        // BSC Testnet
        networkConfigs[97] = NetworkConfig({
            usdt: DeployedAddresses.BSC_TESTNET_USDT,
            priceFeed: DeployedAddresses.BSC_TESTNET_PRICE_FEED
        });
    }

    function getActiveNetworkConfigByChainId(
        uint256 chainId
    ) public view returns (NetworkConfig memory) {
        NetworkConfig memory config = networkConfigs[chainId];
        require(config.priceFeed != address(0), "Network config not set");
        return config;
    }
}

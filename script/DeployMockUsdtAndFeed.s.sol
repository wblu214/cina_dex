// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";

/// @title DeployMockUsdt
/// @notice 在当前网络部署一份 MockUSDT，用作 USDT 测试代币。
/// @dev 预言机仍然使用各网络原本提供的 Chainlink / Binance Oracle 地址，这个脚本只负责 USDT。
contract DeployMockUsdtAndFeed is Script {
    function run() external {
        vm.startBroadcast();

        MockUSDT usdt = new MockUSDT();

        vm.stopBroadcast();

        console2.log("Chain ID:", block.chainid);
        console2.log("MockUSDT deployed at:", address(usdt));
    }
}

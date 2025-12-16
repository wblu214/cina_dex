// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {LendingPool} from "../src/core/LendingPool.sol";
import {ChainlinkOracle} from "../src/core/ChainlinkOracle.sol";
import {FToken} from "../src/tokens/FToken.sol";

/// @title DeployLendingPool
/// @notice 一键部署预言机 + FToken + LendingPool（核心两份是 Oracle 和 Pool）
/// @dev USDT 和 PriceFeed 地址从 HelperConfig/DeployedAddresses 里按 chainId 读取。
contract DeployLendingPool is Script {
    function run() external {
        // 1. 读取当前网络配置（USDT + priceFeed）
        HelperConfig helper = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = helper
            .getActiveNetworkConfigByChainId(block.chainid);

        vm.startBroadcast();

        // 2. 部署 ChainlinkOracle，并写入 ETH/BNB 的价格预言机地址
        ChainlinkOracle oracle = new ChainlinkOracle();
        oracle.setPriceFeed(address(0), cfg.priceFeed);

        // 3. 部署 LP 份额代币 FToken
        FToken fToken = new FToken("CINA LP Token", "cUSDT");

        // 4. 部署 LendingPool，注入 USDT、FToken、Oracle
        LendingPool pool = new LendingPool(
            cfg.usdt,
            address(fToken),
            address(oracle)
        );

        // 5. 将 FToken 的铸造权限转交给池子
        fToken.transferOwnership(address(pool));

        vm.stopBroadcast();

        console2.log("=== Deployment completed on chainId:", block.chainid);
        console2.log("USDT (underlying):", cfg.usdt);
        console2.log("PriceFeed:", cfg.priceFeed);
        console2.log("ChainlinkOracle:", address(oracle));
        console2.log("FToken:", address(fToken));
        console2.log("LendingPool:", address(pool));
    }
}

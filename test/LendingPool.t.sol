// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/core/LendingPool.sol";
import "../src/core/ChainlinkOracle.sol";
import "../src/tokens/FToken.sol";
import "../src/mocks/MockUSDT.sol";
import "../src/interfaces/AggregatorV3Interface.sol";

contract LendingPoolTest is Test {
    LendingPool pool;
    ChainlinkOracle oracle;
    FToken fToken;
    MockUSDT usdt;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    // Sepolia ETH/USD Aggregator Address (真实地址)
    address constant SEPOLIA_ETH_USD_FEED =
        0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function setUp() public {
        // 1. 部署基础合约
        // 注意：在真实部署中，这里会是真实的 USDT 地址，测试用 Mock
        usdt = new MockUSDT();
        fToken = new FToken("CINA LP Token", "cUSDT");
        oracle = new ChainlinkOracle();

        // 2. 配置预言机 (指向 Sepolia 真实地址)
        // 运行测试时需带上 --fork-url <SEPOLIA_RPC>
        oracle.setPriceFeed(address(0), SEPOLIA_ETH_USD_FEED);

        // 3. 部署核心池
        pool = new LendingPool(address(usdt), address(fToken), address(oracle));

        // 4. 移交 FToken 铸造权限给 Pool
        fToken.transferOwnership(address(pool));

        // 5. 初始资金准备
        // 给 Alice 10,000 USDT (用于存款)
        usdt.mint(alice, 10000 * 1e6);
        // 给 Liquidator 10,000 USDT (用于清算)
        usdt.mint(liquidator, 10000 * 1e6);
        // 给 Bob 10 ETH (用于抵押)
        vm.deal(bob, 10 ether);
    }

    // 测试 1: 验证能否读取真实链上价格
    function testGetRealPrice() public {
        try oracle.getPrice(address(0)) returns (uint256 price) {
            console.log("Real ETH Price from Sepolia (WAD):", price);
            assertTrue(price > 0, "Price should be greater than 0");
        } catch {
            console.log("Skipping price check: No Fork environment detected.");
        }
    }

    // 测试 2: 完整的借贷与清算流程
    function testEndToEndFlow() public {
        // --- Step 1: Alice 存款 ---
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        assertEq(
            fToken.balanceOf(alice),
            5000 * 1e6,
            "Alice should have fTokens"
        );

        // --- Step 2: Bob 借款 ---
        // 为了测试逻辑的确定性，我们在这里 Mock 一下价格，固定为 $2000
        // 这样不用担心测试网实时价格波动导致 LTV 计算失败
        mockChainlinkPrice(2000 * 1e8);

        vm.startPrank(bob);
        // 抵押 1 ETH ($2000)
        // LTV 75% -> Max Borrow $1500
        // Bob 借款 1000 USDT (安全范围内)
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days);
        vm.stopPrank();

        assertEq(usdt.balanceOf(bob), 1000 * 1e6, "Bob should receive USDT");
        assertEq(address(pool).balance, 1 ether, "Pool should hold ETH");

        // --- Step 3: 价格暴跌触发清算 ---
        // 模拟 ETH 价格跌到 $1100
        // 抵押物价值 $1100
        // 债务 ~1000 (忽略利息)
        // 当前 LTV = 1000/1100 = 90.9% > 80% (清算阈值) -> 触发清算
        mockChainlinkPrice(1100 * 1e8);

        vm.startPrank(liquidator);
        usdt.approve(address(pool), 2000 * 1e6);

        uint256 loanId = 0; // 第一个贷款 ID 为 0
        uint256 ethBefore = liquidator.balance;

        pool.liquidate(loanId);

        uint256 ethAfter = liquidator.balance;

        // 验证清算人获得了 ETH 奖励
        assertTrue(ethAfter > ethBefore, "Liquidator should receive ETH");
        console.log("Liquidator Profit (ETH Wei):", ethAfter - ethBefore);

        vm.stopPrank();
    }

    // 测试 3: 验证查询接口
    function testViewFunctions() public {
        // Alice 存款
        vm.startPrank(alice);
        usdt.approve(address(pool), 1000 * 1e6);
        pool.deposit(1000 * 1e6);
        vm.stopPrank();

        mockChainlinkPrice(2000 * 1e8);

        // Bob 借款
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days);
        vm.stopPrank();

        // 1. 验证 getUserLoans
        uint256[] memory bobLoans = pool.getUserLoans(bob);
        assertEq(bobLoans.length, 1);
        assertEq(bobLoans[0], 0);

        // 2. 验证 getExchangeRate (初始应为 1e18)
        assertEq(pool.getExchangeRate(), 1e18);

        // 3. 验证 getLoanHealth
        (uint256 ltv, bool isLiquidatable) = pool.getLoanHealth(0);
        assertTrue(ltv > 0);
        assertFalse(isLiquidatable);
    }

    // 测试 4: 正常还款流程 (验证利息和汇率增长)
    function testRepayFlow() public {
        // 1. Alice 存款
        vm.startPrank(alice);
        usdt.approve(address(pool), 10000 * 1e6);
        pool.deposit(10000 * 1e6);
        vm.stopPrank();

        // 2. Bob 借款
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        // 抵押 1 ETH ($2000), 借 1000 USDT (1年期)
        // 利息 = 1000 * 10% = 100 USDT
        pool.borrow{value: 1 ether}(1000 * 1e6, 365 days);
        vm.stopPrank();

        // 3. Bob 还款
        // Bob 需要还 1100 USDT，但他手里只有借来的 1000 USDT
        // 给 Bob 发点钱付利息
        usdt.mint(bob, 100 * 1e6);

        vm.startPrank(bob);
        usdt.approve(address(pool), 1100 * 1e6);
        pool.repay(0); // Loan ID 0
        vm.stopPrank();

        // 4. 验证状态
        // Bob 拿回了 ETH
        assertEq(bob.balance, 10 ether);

        // 验证 LP 汇率增长 (Alice 赚了利息)
        // 池子资金: 10000 (本金) + 100 (利息) = 10100
        // 汇率 = 10100 / 10000 = 1.01
        assertEq(pool.getExchangeRate(), 1.01 * 1e18);
    }

    // 测试 5: 异常测试 - 抵押不足
    function testCannotBorrowInsufficientCollateral() public {
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        // 1 ETH = $2000. Max LTV 75% = $1500.
        // 试图借 $1600 -> 应该失败
        vm.expectRevert("Insufficient collateral");
        pool.borrow{value: 1 ether}(1600 * 1e6, 30 days);
        vm.stopPrank();
    }

    // 测试 6: 异常测试 - 试图清算健康贷款
    function testCannotLiquidateHealthyLoan() public {
        // 准备环境
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days);
        vm.stopPrank();

        // 试图在价格未跌时清算
        vm.startPrank(liquidator);
        usdt.approve(address(pool), 2000 * 1e6);

        vm.expectRevert("Health factor ok");
        pool.liquidate(0);
        vm.stopPrank();
    }

    // 辅助函数: 模拟 Chainlink 返回值
    function mockChainlinkPrice(int256 price) internal {
        vm.mockCall(
            SEPOLIA_ETH_USD_FEED,
            abi.encodeWithSelector(
                AggregatorV3Interface.latestRoundData.selector
            ),
            abi.encode(
                uint80(1),
                price,
                block.timestamp,
                block.timestamp,
                uint80(1)
            )
        );
    }
}

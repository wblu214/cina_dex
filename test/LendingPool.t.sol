// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    // 示例 ETH/USD Aggregator Address（仅用于测试中 mock 价格）
    address constant SEPOLIA_ETH_USD_FEED =
        0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function setUp() public {
        // 1. 部署基础合约
        // 注意：在真实部署中，这里会是真实的 USDT 地址，当前用 Mock
        usdt = new MockUSDT();
        fToken = new FToken("CINA LP Token", "cUSDT");
        oracle = new ChainlinkOracle();

        // 2. 配置预言机 (填入一个价格源地址，测试中通过 vm.mockCall 注入价格)
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
        // 给 Bob 10 单位原生币 (用于抵押，测试环境里仍用 ether 计价)
        vm.deal(bob, 10 ether);
    }

    // 测试 1: 验证能否读取真实链上价格（在有 fork 时）
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
        // 抵押 1 单位原生币 ($2000)
        // LTV 75% -> Max Borrow $1500
        // Bob 借款 1000 USDT (安全范围内)
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days);
        vm.stopPrank();

        assertEq(usdt.balanceOf(bob), 1000 * 1e6, "Bob should receive USDT");
        assertEq(address(pool).balance, 1 ether, "Pool should hold collateral");

        // --- Step 3: 价格暴跌触发清算 ---
        // 模拟原生币价格跌到 $1100
        // 抵押物价值 $1100
        // 债务 ~1000 (忽略利息)
        // 当前 LTV = 1000/1100 = 90.9% > 80% (清算阈值) -> 触发清算
        mockChainlinkPrice(1100 * 1e8);

        vm.startPrank(liquidator);
        usdt.approve(address(pool), 2000 * 1e6);

        uint256 loanId = 0; // 第一个贷款 ID 为 0
        uint256 balBefore = liquidator.balance;

        pool.liquidate(loanId);

        uint256 balAfter = liquidator.balance;

        // 验证清算人获得了原生币奖励
        assertTrue(balAfter > balBefore, "Liquidator should receive native token");
        console.log("Liquidator Profit (wei):", balAfter - balBefore);

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

        // 4. 验证 getLenderPosition
        (
            uint256 fTokenBalance,
            uint256 exchangeRate,
            uint256 underlyingBalance
        ) = pool.getLenderPosition(alice);
        assertEq(fTokenBalance, 1000 * 1e6);
        assertEq(exchangeRate, 1e18);
        assertEq(underlyingBalance, 1000 * 1e6);
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
        // 抵押 1 单位原生币 ($2000), 借 1000 USDT (1年期)
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
        // Bob 拿回了抵押的原生币
        assertEq(bob.balance, 10 ether);

        // 验证 LP 汇率增长 (Alice 赚了利息)
        // 池子资金: 10000 (本金) + 100 (利息) = 10100
        // 汇率 = 10100 / 10000 = 1.01
        assertEq(pool.getExchangeRate(), 1.01 * 1e18);

        // 验证 getLenderPosition 返回的 underlyingBalance
        (
            uint256 fTokenBalanceAfter,
            uint256 exchangeRateAfter,
            uint256 underlyingBalanceAfter
        ) = pool.getLenderPosition(alice);
        assertEq(fTokenBalanceAfter, 10000 * 1e6);
        assertEq(exchangeRateAfter, pool.getExchangeRate());
        assertEq(underlyingBalanceAfter, 10100 * 1e6);
    }

    // 测试 5: 存款后部分取款
    function testWithdrawPartial() public {
        // Alice 存入 5000 USDT
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        // 取回 2000 USDT（此时汇率仍为 1，因此销毁 2000 份额）
        vm.startPrank(alice);
        pool.withdraw(2000 * 1e6);
        vm.stopPrank();

        // Alice: 初始 10000，存 5000 后剩 5000，取回 2000 -> 7000
        assertEq(usdt.balanceOf(alice), 7000 * 1e6);
        // LP 份额从 5000 降到 3000
        assertEq(fToken.balanceOf(alice), 3000 * 1e6);
        // 池子剩余 3000 流动性
        assertEq(usdt.balanceOf(address(pool)), 3000 * 1e6);
        // 汇率仍为 1
        assertEq(pool.getExchangeRate(), 1e18);
    }

    // 测试 6: 存款 + 借款 + 还款后全部取款，Alice 收到本息
    function testWithdrawAllAfterInterest() public {
        // 1. Alice 存款
        vm.startPrank(alice);
        usdt.approve(address(pool), 10000 * 1e6);
        pool.deposit(10000 * 1e6);
        vm.stopPrank();

        // 2. Bob 借款
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(1000 * 1e6, 365 days);
        vm.stopPrank();

        // 3. Bob 还款
        usdt.mint(bob, 100 * 1e6);
        vm.startPrank(bob);
        usdt.approve(address(pool), 1100 * 1e6);
        pool.repay(0);
        vm.stopPrank();

        // 汇率应为 1.01
        assertEq(pool.getExchangeRate(), 1.01 * 1e18);

        // 4. Alice 赎回全部资产：按当前汇率计算应得的 USDT 金额
        (, , uint256 underlyingBalanceBefore) = pool.getLenderPosition(alice);
        vm.startPrank(alice);
        pool.withdraw(underlyingBalanceBefore);
        vm.stopPrank();

        // Alice 拿回 10100 USDT (本金 + 利息)
        assertEq(usdt.balanceOf(alice), underlyingBalanceBefore);
        // LP 份额清零
        assertEq(fToken.balanceOf(alice), 0);
        // 池子 USDT 也应归零
        assertEq(usdt.balanceOf(address(pool)), 0);
    }

    // 测试 7: 借出大部分资金后，流动性不足导致取款失败
    function testCannotWithdrawWhenInsufficientLiquidity() public {
        // Alice 存入 5000 USDT
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        // Bob 抵押 10 ETH 借 4000 USDT，池子只剩 1000 可用流动性
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        pool.borrow{value: 10 ether}(4000 * 1e6, 30 days);
        vm.stopPrank();

        // Alice 尝试赎回 5000 USDT，应因流动性不足失败
        vm.startPrank(alice);
        vm.expectRevert("Insufficient liquidity");
        pool.withdraw(5000 * 1e6);
        vm.stopPrank();
    }

    // 测试 8: 到期后，即使贷款仍然健康，也可以通过 liquidateExpired 清算
    function testLiquidateExpiredLoan() public {
        // Alice 提供流动性
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        // 固定价格，保证贷款在价格维度是健康的
        mockChainlinkPrice(2000 * 1e8);

        // Bob 借款 30 天
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days);
        vm.stopPrank();

        // 此时应是健康贷款，不能通过 liquidate 清算
        (uint256 ltv, bool isLiquidatable) = pool.getLoanHealth(0);
        assertTrue(ltv > 0);
        assertFalse(isLiquidatable);

        vm.startPrank(liquidator);
        usdt.approve(address(pool), 2000 * 1e6);
        vm.expectRevert("Health factor ok");
        pool.liquidate(0);
        vm.stopPrank();

        // 时间快进超过 30 天，贷款到期
        skip(31 days);

        // 现在可以通过 liquidateExpired 清算
        vm.startPrank(liquidator);
        uint256 balBefore = liquidator.balance;
        usdt.approve(address(pool), 2000 * 1e6);
        pool.liquidateExpired(0);
        uint256 balAfter = liquidator.balance;
        assertTrue(balAfter > balBefore, "Liquidator should receive native token");
        vm.stopPrank();
    }

    // 测试 9: 异常测试 - 抵押不足
    function testCannotBorrowInsufficientCollateral() public {
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        // 1 单位原生币 = $2000. Max LTV 75% = $1500.
        // 试图借 $1600 -> 应该失败
        vm.expectRevert("Insufficient collateral");
        pool.borrow{value: 1 ether}(1600 * 1e6, 30 days);
        vm.stopPrank();
    }

    // 测试 10: 异常测试 - 试图清算健康贷款
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

    // 测试 11: getPoolState 聚合信息是否正确
    function testGetPoolState() public {
        // Alice 存款 5000 USDT
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        // Bob 按固定价格借 1000 USDT
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days);
        vm.stopPrank();

        (
            uint256 totalAssets,
            uint256 totalBorrowed_,
            uint256 availableLiquidity,
            uint256 exchangeRate,
            uint256 totalFTokenSupply
        ) = pool.getPoolState();

        // 池子应有: 5000 存款资产
        assertEq(totalAssets, 5000 * 1e6);
        // 借出本金: 1000
        assertEq(totalBorrowed_, 1000 * 1e6);
        // 可用流动性: 5000 - 1000 = 4000
        assertEq(availableLiquidity, 4000 * 1e6);
        // 初始 LP 份额: 5000
        assertEq(totalFTokenSupply, 5000 * 1e6);
        // 汇率仍为 1e18
        assertEq(exchangeRate, 1e18);
    }

    // 测试 12: getUserPosition 聚合多笔贷款
    function testGetUserPositionAggregatesLoans() public {
        // Alice 先存入足够流动性
        vm.startPrank(alice);
        usdt.approve(address(pool), 5000 * 1e6);
        pool.deposit(5000 * 1e6);
        vm.stopPrank();

        // 固定价格
        mockChainlinkPrice(2000 * 1e8);

        // Bob 开两笔贷款
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(1000 * 1e6, 30 days); // loanId = 0
        pool.borrow{value: 1 ether}(500 * 1e6, 60 days); // loanId = 1
        vm.stopPrank();

        (
            uint256[] memory loanIds,
            uint256 totalPrincipal,
            uint256 totalRepayment,
            uint256 totalCollateral
        ) = pool.getUserPosition(bob);

        assertEq(loanIds.length, 2);
        assertEq(loanIds[0], 0);
        assertEq(loanIds[1], 1);

        // 本金 = 1000 + 500
        assertEq(totalPrincipal, 1500 * 1e6);
        // 抵押 = 1 + 1 ETH
        assertEq(totalCollateral, 2 ether);

        // totalRepayment 应为两笔贷款 repaymentAmount 之和
        (, , , uint256 repay0, , , ) = pool.loans(0);
        (, , , uint256 repay1, , , ) = pool.loans(1);
        assertEq(totalRepayment, repay0 + repay1);
    }

    // 测试 13: deposit 金额为 0 时应 revert
    function testCannotDepositZero() public {
        vm.startPrank(alice);
        usdt.approve(address(pool), 1);
        vm.expectRevert("Amount must be > 0");
        pool.deposit(0);
        vm.stopPrank();
    }

    // 测试 14: 已还清的贷款再次还款应失败
    function testCannotRepayInactiveLoan() public {
        // Alice 存款
        vm.startPrank(alice);
        usdt.approve(address(pool), 2000 * 1e6);
        pool.deposit(2000 * 1e6);
        vm.stopPrank();

        // Bob 借款
        mockChainlinkPrice(2000 * 1e8);
        vm.startPrank(bob);
        pool.borrow{value: 1 ether}(500 * 1e6, 30 days);
        vm.stopPrank();

        // 给 Bob 足够 USDT 还款
        usdt.mint(bob, 1000 * 1e6);

        vm.startPrank(bob);
        usdt.approve(address(pool), type(uint256).max);
        pool.repay(0); // 第一次成功

        vm.expectRevert("Loan inactive");
        pool.repay(0); // 第二次应失败
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

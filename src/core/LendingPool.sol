// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/CINAConfig.sol";
import "../libraries/InterestMath.sol";
import "../interfaces/IOracle.sol";
import "../tokens/FToken.sol";

contract LendingPool is CINAConfig, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt;
    FToken public immutable fToken;
    IOracle public immutable oracle;

    struct Loan {
        address borrower;
        uint256 collateralAmount; // ETH 数量 (Wei)
        uint256 principal; // 借款本金 (USDT)
        uint256 repaymentAmount; // 应还总额 (本金 + 利息)
        uint256 startTime;
        uint256 duration;
        bool isActive;
    }

    uint256 public nextLoanId;
    uint256 public totalBorrowed; // 池子当前借出的本金总额
    mapping(uint256 => Loan) public loans;

    event Deposit(address indexed user, uint256 amount, uint256 fTokensMinted);
    event Borrow(
        address indexed user,
        uint256 loanId,
        uint256 amount,
        uint256 collateralAmount
    );
    event Repay(address indexed user, uint256 loanId, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        uint256 loanId,
        uint256 amountPaid,
        uint256 collateralSeized
    );

    constructor(
        address _usdt,
        address _fToken,
        address _oracle
    ) Ownable(msg.sender) {
        usdt = IERC20(_usdt);
        fToken = FToken(_fToken);
        oracle = IOracle(_oracle);
    }

    // --- 1. 存款逻辑 (Lender) ---
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");

        // 计算 FToken 汇率:
        // 资产总值 = 当前池子里的 USDT + 借出去的本金 (简化计算，暂不含未结算利息)
        uint256 totalAssets = usdt.balanceOf(address(this)) + totalBorrowed;
        uint256 totalSupply = fToken.totalSupply();

        uint256 shares;
        if (totalSupply == 0) {
            shares = amount; // 初始 1:1
        } else {
            // shares = amount * (totalSupply / totalAssets)
            shares = (amount * totalSupply) / totalAssets;
        }

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        fToken.mint(msg.sender, shares);

        emit Deposit(msg.sender, amount, shares);
    }

    // --- 2. 借款逻辑 (Borrower) ---
    function borrow(
        uint256 amount,
        uint256 duration
    ) external payable nonReentrant {
        require(amount > 0, "Amount > 0");
        require(msg.value > 0, "Collateral required");
        require(duration > 0, "Duration required");

        // A. 获取 ETH 价格 (假设 Oracle 返回 18位精度)
        uint256 ethPrice = oracle.getPrice(address(0));
        require(ethPrice > 0, "Invalid price");

        // B. 计算抵押物价值 (USD, 18 decimals)
        uint256 collateralValue = (msg.value * ethPrice) / 1e18;

        // C. 计算最大可借额度 (LTV 75%)
        uint256 maxBorrowValue = (collateralValue * MAX_LTV) / 100;

        // D. 检查额度 (注意: USDT 是 6位精度，需要转成 18位比较)
        require(amount * 1e12 <= maxBorrowValue, "Insufficient collateral");

        // E. 计算利息 (固定利率)
        uint256 interest = InterestMath.calculateInterest(
            amount,
            BORROW_APR_BPS,
            duration
        );
        uint256 repaymentAmount = amount + interest;

        // F. 记录状态
        loans[nextLoanId] = Loan({
            borrower: msg.sender,
            collateralAmount: msg.value,
            principal: amount,
            repaymentAmount: repaymentAmount,
            startTime: block.timestamp,
            duration: duration,
            isActive: true
        });

        totalBorrowed += amount;
        emit Borrow(msg.sender, nextLoanId, amount, msg.value);
        nextLoanId++;

        // G. 放款
        usdt.safeTransfer(msg.sender, amount);
    }

    // --- 3. 还款逻辑 ---
    function repay(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan inactive");

        uint256 amount = loan.repaymentAmount;
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        // 归还抵押物
        uint256 collateral = loan.collateralAmount;
        loan.isActive = false;
        loan.collateralAmount = 0;
        totalBorrowed -= loan.principal; // 债务消除

        (bool success, ) = payable(loan.borrower).call{value: collateral}("");
        require(success, "ETH transfer failed");

        emit Repay(loan.borrower, loanId, amount);
    }

    // --- 4. 清算逻辑 ---
    function liquidate(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        require(loan.isActive, "Loan inactive");

        // A. 检查健康度
        uint256 ethPrice = oracle.getPrice(address(0));
        uint256 collateralValue = (loan.collateralAmount * ethPrice) / 1e18;
        uint256 debtValue = loan.repaymentAmount * 1e12; // 转 18位

        // 触发条件: 债务价值 / 抵押价值 >= 80%
        require(
            debtValue * 100 >= collateralValue * LIQUIDATION_THRESHOLD,
            "Health factor ok"
        );

        // B. 清算人代还全款
        uint256 amountToRepay = loan.repaymentAmount;
        usdt.safeTransferFrom(msg.sender, address(this), amountToRepay);

        // C. 计算清算奖励 (清算人拿走: 债务价值 * 104% 的 ETH)
        // 4% 给清算人 (5% 总罚金 * 80% 分成)
        uint256 liquidatorValue = (amountToRepay * 104) / 100;
        uint256 collateralToSeize = (liquidatorValue * 1e30) / ethPrice; // USDT(6) -> 18 -> /Price

        // 防止坏账 (Bad Debt): 如果抵押物不够赔，清算人拿走所有
        if (collateralToSeize > loan.collateralAmount) {
            collateralToSeize = loan.collateralAmount;
        }

        loan.isActive = false;
        totalBorrowed -= loan.principal;

        (bool success, ) = payable(msg.sender).call{value: collateralToSeize}(
            ""
        );
        require(success, "Liq transfer failed");

        // 剩余抵押物退还借款人 (如果有)
        uint256 remaining = loan.collateralAmount - collateralToSeize;
        if (remaining > 0) {
            (bool successRefund, ) = payable(loan.borrower).call{
                value: remaining
            }("");
            require(successRefund, "Refund failed");
        }

        emit Liquidate(msg.sender, loanId, amountToRepay, collateralToSeize);
    }

    // --- 5. View helpers ---

    /// @notice Returns the current LP token exchange rate (18‑decimals WAD).
    /// @dev When no deposits exist yet, we define the rate as 1e18.
    function getExchangeRate() public view returns (uint256) {
        uint256 totalSupply = fToken.totalSupply();
        if (totalSupply == 0) {
            return 1e18;
        }

        uint256 totalAssets = usdt.balanceOf(address(this)) + totalBorrowed;
        return (totalAssets * 1e18) / totalSupply;
    }

    /// @notice Returns an aggregate view of the pool state for off‑chain indexers.
    /// @return totalAssets          Current total assets (USDT in pool + outstanding principal).
    /// @return totalBorrowed_       Total outstanding borrowed principal.
    /// @return availableLiquidity   USDT balance currently held by the pool.
    /// @return exchangeRate         Current fToken exchange rate (18‑decimals WAD).
    /// @return totalFTokenSupply    Total fToken supply.
    function getPoolState()
        external
        view
        returns (
            uint256 totalAssets,
            uint256 totalBorrowed_,
            uint256 availableLiquidity,
            uint256 exchangeRate,
            uint256 totalFTokenSupply
        )
    {
        totalBorrowed_ = totalBorrowed;

        uint256 usdtBalance = usdt.balanceOf(address(this));
        availableLiquidity = usdtBalance;
        totalAssets = usdtBalance + totalBorrowed_;

        totalFTokenSupply = fToken.totalSupply();
        exchangeRate = getExchangeRate();
    }

    /// @notice Returns all active loan IDs for a user.
    function getUserLoans(address user) external view returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = 0; i < nextLoanId; i++) {
            if (loans[i].borrower == user && loans[i].isActive) {
                count++;
            }
        }

        uint256[] memory result = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < nextLoanId; i++) {
            if (loans[i].borrower == user && loans[i].isActive) {
                result[idx++] = i;
            }
        }

        return result;
    }

    /// @notice Returns an aggregate view of a user's active borrowing position.
    /// @dev Sums over all active loans of the user; intended for off‑chain use.
    /// @return loanIds        Active loan IDs.
    /// @return totalPrincipal Sum of principals for all active loans.
    /// @return totalRepayment Sum of repayment amounts (principal + interest).
    /// @return totalCollateral Sum of collateral (ETH, in wei) across all active loans.
    function getUserPosition(
        address user
    )
        external
        view
        returns (
            uint256[] memory loanIds,
            uint256 totalPrincipal,
            uint256 totalRepayment,
            uint256 totalCollateral
        )
    {
        uint256 count;
        for (uint256 i = 0; i < nextLoanId; i++) {
            if (loans[i].borrower == user && loans[i].isActive) {
                count++;
            }
        }

        loanIds = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < nextLoanId; i++) {
            Loan storage loan = loans[i];
            if (loan.borrower == user && loan.isActive) {
                loanIds[idx++] = i;
                totalPrincipal += loan.principal;
                totalRepayment += loan.repaymentAmount;
                totalCollateral += loan.collateralAmount;
            }
        }
    }

    /// @notice Returns the current LTV and whether the loan is liquidatable.
    /// @dev LTV is returned as a WAD (1e18 = 100%).
    function getLoanHealth(
        uint256 loanId
    ) external view returns (uint256 ltv, bool isLiquidatable) {
        Loan storage loan = loans[loanId];
        if (!loan.isActive) {
            return (0, false);
        }

        uint256 ethPrice = oracle.getPrice(address(0));
        uint256 collateralValue = (loan.collateralAmount * ethPrice) / 1e18;
        if (collateralValue == 0) {
            // No collateral means the position is obviously bad.
            return (0, true);
        }

        uint256 debtValue = loan.repaymentAmount * 1e12; // USDT(6) -> 18 decimals
        ltv = (debtValue * 1e18) / collateralValue;

        isLiquidatable =
            debtValue * 100 >= collateralValue * LIQUIDATION_THRESHOLD;
    }

    // 接收 ETH
    receive() external payable {}
}

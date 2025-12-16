// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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

    // 接收 ETH
    receive() external payable {}
}

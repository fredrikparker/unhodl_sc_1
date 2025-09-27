// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title rBTC-backed Debit Card with USDRIF Settlement
/// @notice Users can spend, borrow against rBTC, and settle in USDRIF.
///         Interest of 3% per month is charged if repayment not done before 25th.
contract RBTCDebitCard is Ownable {
    IERC20 public rBTC;     // collateral token
    IERC20 public usdrif;   // settlement token

    uint256 public monthlyInterest = 300; // 3% in basis points (3% = 300 bp)
    uint256 public constant BP_DENOM = 10000;

    struct Loan {
        uint256 collateral; // rBTC locked
        uint256 debt;       // USDRIF owed
        uint256 lastDueDate;
        bool active;
    }

    mapping(address => Loan) public loans;

    event Borrowed(address indexed user, uint256 collateral, uint256 amount, uint256 dueDate);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, uint256 collateral);

    constructor(address _rBTC, address _usdrif) Ownable(msg.sender) {
        rBTC = IERC20(_rBTC);
        usdrif = IERC20(_usdrif);
    }

    /// @notice Borrow USDRIF against rBTC collateral
    function borrow(uint256 collateralAmount, uint256 borrowAmount) external {
        require(collateralAmount > 0 && borrowAmount > 0, "Invalid amounts");
        require(!loans[msg.sender].active, "Loan exists");

        // Transfer collateral
        rBTC.transferFrom(msg.sender, address(this), collateralAmount);

        // Mint/Transfer USDRIF (assume contract pre-funded with USDRIF)
        require(usdrif.balanceOf(address(this)) >= borrowAmount, "Insufficient USDRIF liquidity");
        usdrif.transfer(msg.sender, borrowAmount);

        // Calculate due date = 25th of this month
        uint256 dueDate = _getNextDueDate();

        loans[msg.sender] = Loan({
            collateral: collateralAmount,
            debt: borrowAmount,
            lastDueDate: dueDate,
            active: true
        });

        emit Borrowed(msg.sender, collateralAmount, borrowAmount, dueDate);
    }

    /// @notice Repay debt in USDRIF
    function repay(uint256 amount) external {
        Loan storage loan = loans[msg.sender];
        require(loan.active, "No active loan");

        // Update interest if overdue
        _applyInterest(msg.sender);

        require(amount > 0 && amount <= loan.debt, "Invalid repayment amount");
        usdrif.transferFrom(msg.sender, address(this), amount);

        loan.debt -= amount;

        // Loan closed
        if (loan.debt == 0) {
            uint256 collateral = loan.collateral;
            loan.active = false;
            loan.collateral = 0;
            rBTC.transfer(msg.sender, collateral);
        }

        emit Repaid(msg.sender, amount);
    }

    /// @notice Liquidate overdue loan
    function liquidate(address user) external onlyOwner {
        Loan storage loan = loans[user];
        require(loan.active, "No active loan");

        _applyInterest(user);

        // If still unpaid after interest, collateral is seized
        if (block.timestamp > loan.lastDueDate && loan.debt > 0) {
            uint256 collateral = loan.collateral;
            loan.active = false;
            loan.collateral = 0;
            // Collateral goes to contract owner (treasury)
            rBTC.transfer(owner(), collateral);

            emit Liquidated(user, collateral);
        }
    }

    /// @dev Adds interest if overdue
    function _applyInterest(address user) internal {
        Loan storage loan = loans[user];
        if (loan.active && block.timestamp > loan.lastDueDate) {
            uint256 monthsOverdue = (block.timestamp - loan.lastDueDate) / 30 days + 1;
            uint256 interest = (loan.debt * monthlyInterest * monthsOverdue) / BP_DENOM;
            loan.debt += interest;
            loan.lastDueDate = _getNextDueDate();
        }
    }

    /// @dev Get next 25th as due date
    function _getNextDueDate() internal view returns (uint256) {
        // crude approx: add days until 25th of current or next month
        (uint256 year, uint256 month, uint256 day) = _timestampToDate(block.timestamp);
        if (day >= 25) {
            month += 1;
            if (month > 12) {
                month = 1;
                year += 1;
            }
        }
        return _toTimestamp(year, month, 25);
    }

    /// --- Date helpers (simplified, not 100% accurate for leap years, etc.) ---
    function _timestampToDate(uint256 ts) internal pure returns (uint256 year, uint256 month, uint256 day) {
        year = 1970 + ts / 31556952; // approx year
        month = ((ts / 2629746) % 12) + 1;
        day = ((ts / 86400) % 30) + 1;
    }

    function _toTimestamp(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        return (year - 1970) * 31556952 + (month - 1) * 2629746 + (day - 1) * 86400;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title InterestMath
/// @notice Simple interest calculator used by the lending pool.
library InterestMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000; // 100% in basis points

    /// @notice Computes simple interest for a fixed-rate loan.
    /// @param principal  Loan principal (USDT, 6 decimals in this project).
    /// @param aprBps     Annual percentage rate in basis points (1e4 = 100%).
    /// @param duration   Loan duration in seconds.
    /// @return interest  Accrued interest for the period, in the same units as `principal`.
    function calculateInterest(
        uint256 principal,
        uint256 aprBps,
        uint256 duration
    ) internal pure returns (uint256 interest) {
        // Simple interest:
        // interest = principal * apr * duration / (1 year * BPS_DENOMINATOR)
        //
        // Using 365 days for the "year" keeps the math deterministic and
        // matches the expectations in the tests (e.g. 10% APR over 365 days).
        uint256 yearInSeconds = 365 days;

        interest = (principal * aprBps * duration) /
            (BPS_DENOMINATOR * yearInSeconds);
    }
}

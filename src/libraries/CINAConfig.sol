// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title CINAConfig
/// @notice Protocol-wide risk and interest parameters.
/// @dev LendingPool inherits from this contract to access the constants.
contract CINAConfig {
    // 1. Maximum loan-to-value ratio (in %, denominator = 100).
    //    MAX_LTV = 75 => users can borrow up to 75% of their collateral value.
    uint256 public constant MAX_LTV = 75;

    // 2. Liquidation threshold (in %). When debt / collateral >= 80%,
    //    the position becomes eligible for liquidation.
    uint256 public constant LIQUIDATION_THRESHOLD = 80;

    // 3. Global liquidation bonus in % (5% penalty on the borrower).
    uint256 public constant LIQUIDATION_BONUS = 5;

    // 4. Share of the liquidation bonus that goes to the protocol (in %).
    //    20% of the 5% penalty -> protocol earns 1% of the total position value.
    uint256 public constant PROTOCOL_LIQUIDATION_SHARE = 20;

    // 5. Borrow APR expressed in basis points (1e4 = 100%).
    //    1000 bp = 10% APR.
    uint256 public constant BORROW_APR_BPS = 1000;

    // 6. Reserve factor: share of interest that is kept as protocol reserves (in %).
    //    With a 10% APR, 1.5% goes to the protocol and 8.5% to LPs -> 15% reserve factor.
    uint256 public constant RESERVE_FACTOR = 15;
}

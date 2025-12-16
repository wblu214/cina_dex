// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOracle
/// @notice Minimal price oracle interface used by the lending pool.
interface IOracle {
    /// @notice Returns the asset price in 18‑decimals WAD.
    /// @param asset Address of the asset (e.g. address(0) for ETH).
    function getPrice(address asset) external view returns (uint256);
}

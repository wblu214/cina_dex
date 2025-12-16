// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IOracle.sol";

/// @title MockOracle
/// @notice Simple in-memory oracle for local/unit testing.
contract MockOracle is IOracle {
    mapping(address => uint256) public prices; // asset => price (1e18)

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getPrice(address asset) external view override returns (uint256) {
        uint256 price = prices[asset];
        require(price > 0, "Price not set");
        return price;
    }
}

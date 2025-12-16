// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title FToken
/// @notice Simple interest-bearing LP token for the lending pool.
/// @dev Minting and burning are restricted to the contract owner (the pool).
contract FToken is ERC20, Ownable {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// @notice Mints `amount` tokens to `to`. Only callable by the owner (LendingPool).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns `amount` tokens from `from`. Only callable by the owner (LendingPool).
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /// @dev Optional: if you prefer 6 decimals to match USDT, override `decimals`.
    ///      Tests don't rely on the decimals value, so we keep the ERC20 default (18).
}

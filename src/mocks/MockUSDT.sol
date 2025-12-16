// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDT
/// @notice Simple ERC20 with 6 decimals used for local testing.
contract MockUSDT is ERC20, Ownable {
    constructor() ERC20("Mock USDT", "mUSDT") Ownable(msg.sender) {}

    /// @notice Mints `amount` tokens to `to`. Callable by the owner (test contract).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

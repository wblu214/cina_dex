// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IOracle.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ChainlinkOracle is IOracle, Ownable {
    // 资产地址 => Chainlink Feed 地址
    mapping(address => address) public priceFeeds;

    constructor() Ownable(msg.sender) {}

    // 管理员设置资产对应的 Chainlink Feed
    // 例如 Sepolia ETH/USD Feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306
    function setPriceFeed(address asset, address feed) external onlyOwner {
        priceFeeds[asset] = feed;
    }

    function getPrice(address asset) external view override returns (uint256) {
        address feed = priceFeeds[asset];
        require(feed != address(0), "Asset not supported");

        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        (, int256 price, , , ) = aggregator.latestRoundData();
        require(price > 0, "Invalid price");

        // Sepolia ETH/USD and most Chainlink USD feeds use 8 decimals.
        // To keep things simple (and friendly to vm.mockCall), we assume 8 here
        // and scale to 18‑decimals WAD.
        uint8 decimals = 8;

        // 统一标准化为 18 位精度 (WAD)
        if (decimals < 18) {
            return uint256(price) * (10 ** (18 - decimals));
        } else {
            return uint256(price) / (10 ** (decimals - 18));
        }
    }
}

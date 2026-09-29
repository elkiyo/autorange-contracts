// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Minimal local copy of Chainlink's AggregatorV3Interface — only
/// the two functions RangeVaultArbCompoundV5 needs, same "write it locally
/// instead of pulling in a whole external package" discipline as
/// INonfungiblePositionManager.sol/ISwapRouter02.sol in this same directory.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

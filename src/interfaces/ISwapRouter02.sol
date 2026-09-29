// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal local interface for Uniswap's SwapRouter02 (the router actually
/// deployed on Celo at 0x5615CDAb..., per Celopedia's verified contract list).
/// SwapRouter02 dropped the `deadline` field that the original v1 SwapRouter had —
/// this struct matches the real SwapRouter02 ABI, not the older v3-periphery one.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

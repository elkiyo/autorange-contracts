// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @notice Minimal local copy of Uniswap V3's NonfungiblePositionManager interface —
/// only the functions this project needs. Written locally instead of importing the
/// Uniswap v3-periphery package, because that package's version of this interface
/// imports OpenZeppelin v3.x-era ERC721 interfaces (IERC721Metadata/IERC721Enumerable
/// at a path that no longer exists in OZ v5), which conflicts with the OZ version
/// this project uses elsewhere. The ABI below matches the real deployed contract.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function burn(uint256 tokenId) external payable;

    /// @notice Added for RangeVaultArbCompoundV5's rescuePosition() — the
    /// real deployed contract has this via ERC721 inheritance, but this
    /// local minimal copy never declared it before nothing here needed to
    /// move the NFT itself, only mint/decrease/increase/collect against it.
    /// rescuePosition() deliberately uses the RAW transferFrom below, not
    /// this one — see that function's own docstring (found during the
    /// pre-deploy audit: safeTransferFrom can revert if `owner` is a
    /// contract without onERC721Received, e.g. an EIP-7702-delegated
    /// address, confirmed live against a real such address on an Arbitrum
    /// fork — the last-resort rescue must never be blockable that way).
    /// Kept declared regardless in case a future caller genuinely wants the
    /// receiver-checked variant.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Raw ERC721 transfer, no onERC721Received check on `to`. See
    /// safeTransferFrom's own docstring for why rescuePosition() uses this
    /// one specifically.
    function transferFrom(address from, address to, uint256 tokenId) external;
}

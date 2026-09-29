// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Minimal local copy of Uniswap V3's factory interface — only the
/// one function this project needs (verifying a caller-supplied pool address
/// against the real factory, see VaultFactoryArbCompoundV5.sol's
/// createVault()), same "write it locally instead of pulling in a whole
/// external package" discipline as every other interface in this directory.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {AutoRangeVaultV1} from "./AutoRangeVaultV1.sol";
import {IUniswapV3Factory} from "../interfaces/IUniswapV3Factory.sol";

/// @title AutoRangeVaultFactoryV1
/// @notice Permissionless factory for AutoRange compound vaults. Clones the
/// AutoRangeVaultV1 implementation (EIP-1167) for each new vault, verifying the
/// vault can never be created against a spoofed pool. Tracks every vault it
/// creates (isVault, allVaults, per-owner listing) for O(1) authenticity
/// checks from the frontend.
contract AutoRangeVaultFactoryV1 {
    error TokenMismatch();
    error UnverifiedPool();

    address public immutable implementation;
    address public immutable platformConfig;
    address public immutable positionManager;
    address public immutable swapRouter;
    address public immutable gasPriceOracle;
    address public immutable uniswapV3Factory;

    mapping(address => address[]) private _vaultsByOwner;
    address[] public allVaults;
    mapping(address => bool) public isVault;

    event VaultCreated(
        address indexed owner, address indexed vault, address pool, address token0, address token1, uint24 fee
    );

    constructor(
        address _platformConfig,
        address _positionManager,
        address _swapRouter,
        address _gasPriceOracle,
        address _uniswapV3Factory
    ) {
        implementation = address(new AutoRangeVaultV1());
        platformConfig = _platformConfig;
        positionManager = _positionManager;
        swapRouter = _swapRouter;
        gasPriceOracle = _gasPriceOracle;
        uniswapV3Factory = _uniswapV3Factory;
    }

    function createVault(address pool, address stableToken, address volatileToken, uint24 fee)
        external
        returns (address vault)
    {
        address poolToken0 = IUniswapV3Pool(pool).token0();
        address poolToken1 = IUniswapV3Pool(pool).token1();
        bool stableIsToken0;
        if (stableToken == poolToken0 && volatileToken == poolToken1) {
            stableIsToken0 = true;
        } else if (stableToken == poolToken1 && volatileToken == poolToken0) {
            stableIsToken0 = false;
        } else {
            revert TokenMismatch();
        }
        if (IUniswapV3Factory(uniswapV3Factory).getPool(poolToken0, poolToken1, fee) != pool) {
            revert UnverifiedPool();
        }

        vault = Clones.clone(implementation);
        AutoRangeVaultV1(vault).initialize(
            msg.sender,
            platformConfig,
            pool,
            poolToken0,
            poolToken1,
            stableIsToken0,
            fee,
            positionManager,
            swapRouter,
            gasPriceOracle
        );

        _vaultsByOwner[msg.sender].push(vault);
        allVaults.push(vault);
        isVault[vault] = true;

        emit VaultCreated(msg.sender, vault, pool, poolToken0, poolToken1, fee);
    }

    function getVaultsByOwner(address ownerAddr) external view returns (address[] memory) {
        return _vaultsByOwner[ownerAddr];
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}

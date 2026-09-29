// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3Factory.sol";
import {IPlatformConfig} from "../src/interfaces/IPlatformConfig.sol";
import {AutoRangePlatformConfigV1} from "../src/official/AutoRangePlatformConfigV1.sol";

/// @title Prueba 10 (item 2) — fidelidad de las 5 interfaces locales mínimas
/// vs. los contratos reales deployados en Arbitrum. Un selector o un orden de
/// campos de struct mal ⇒ fallo silencioso. Cada test ejercita la interfaz
/// contra el contrato real y comprueba que el DECODE de la respuesta cae en
/// los campos correctos (si el layout estuviera corrido, estos asserts
/// fallarían o la llamada revertiría).
contract AutoRangeInterfaceFidelityTest is Test {
    address constant POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // USDC/WETH 0.05%
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // token1
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // token0
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant GAS_ORACLE = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH/USD
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));
    }

    // ---------------------------------------------------------------------
    // IUniswapV3Factory.getPool
    // ---------------------------------------------------------------------

    function test_iface_uniswapV3Factory_getPool() public view {
        IUniswapV3Factory f = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        assertEq(f.getPool(USDC, WETH, 500), POOL, "getPool resolves the canonical pool");
        assertEq(f.getPool(WETH, USDC, 500), POOL, "token order does not matter");
        assertEq(f.getPool(USDC, WETH, 12345), address(0), "an invalid fee tier resolves to address(0)");
    }

    // ---------------------------------------------------------------------
    // IAggregatorV3.latestRoundData / decimals
    // ---------------------------------------------------------------------

    function test_iface_aggregatorV3_latestRoundData_fieldsLandRight() public view {
        IAggregatorV3 o = IAggregatorV3(GAS_ORACLE);
        assertEq(o.decimals(), 8, "the /1e20 divisor in _ethUsdFromOracle assumes 8-decimal answer");

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = o.latestRoundData();
        // answer decodes into field 2 and is a plausible ETH/USD price (8 dec).
        assertGt(answer, 200e8, "ETH price > $200");
        assertLt(answer, 100_000e8, "ETH price < $100k");
        // updatedAt decodes into field 4 and is a recent, non-future timestamp.
        assertLe(updatedAt, block.timestamp, "updatedAt is not in the future");
        assertGe(updatedAt, block.timestamp - 90_000, "updatedAt within the 25h staleness bound _ethUsdFromOracle uses");
        assertGt(startedAt, 0);
        assertGt(roundId, 0);
        assertGt(answeredInRound, 0);
    }

    // ---------------------------------------------------------------------
    // ISwapRouter02.exactInputSingle — struct field order
    // ---------------------------------------------------------------------

    function test_iface_swapRouter02_exactInputSingle_structOrder() public {
        // If ExactInputSingleParams' fields were mis-ordered (e.g. fee where
        // recipient belongs), the real router would revert or return a wildly
        // wrong amountOut. Swap 1,000 USDC -> WETH and check the rate is sane.
        address trader = makeAddr("trader");
        deal(USDC, trader, 1_000_000_000);
        vm.startPrank(trader);
        IERC20(USDC).approve(SWAP_ROUTER02, type(uint256).max);
        uint256 out = ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: trader,
                amountIn: 1_000_000_000,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        // 1,000 USDC at ~$2000-5000/ETH -> ~0.2-0.5 WETH, and the router
        // actually credited `trader` (recipient field landed right).
        assertGt(out, 0.1 ether, "amountOut sane (>0.1 WETH for $1000)");
        assertLt(out, 1 ether, "amountOut sane (<1 WETH for $1000)");
        assertEq(IERC20(WETH).balanceOf(trader), out, "recipient field routed the output to `trader`");
    }

    // ---------------------------------------------------------------------
    // INonfungiblePositionManager.mint / positions — 12-field tuple layout
    // ---------------------------------------------------------------------

    function test_iface_positionManager_mintThenPositions_tupleLayout() public {
        address lp = makeAddr("lp");
        deal(USDC, lp, 2_000_000_000);
        deal(WETH, lp, 1 ether);

        (, int24 tick,,,,,) = IUniswapV3PoolMin(POOL).slot0();
        int24 spacing = IUniswapV3PoolMin(POOL).tickSpacing();
        int24 lo = ((tick - 1000) / spacing) * spacing;
        int24 hi = ((tick + 1000) / spacing) * spacing;

        vm.startPrank(lp);
        IERC20(USDC).approve(POSITION_MANAGER, type(uint256).max);
        IERC20(WETH).approve(POSITION_MANAGER, type(uint256).max);
        (uint256 tokenId,, uint256 used0, uint256 used1) = INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: 500,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: 0.3 ether,
                amount1Desired: 1_000_000_000,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertGt(tokenId, 0);
        assertTrue(used0 > 0 || used1 > 0);

        // The local INonfungiblePositionManager destructures positions() as:
        //   (nonce, operator, token0, token1, fee, tickLower, tickUpper, liquidity, ...)
        // Read it back and confirm those slots carry what mint() was given.
        (
            ,
            ,
            address pt0,
            address pt1,
            uint24 pfee,
            int24 ptl,
            int24 ptu,
            uint128 pliq,
            ,
            ,
            ,
        ) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        assertEq(pt0, WETH, "positions() field 3 == token0");
        assertEq(pt1, USDC, "positions() field 4 == token1");
        assertEq(pfee, 500, "positions() field 5 == fee");
        assertEq(ptl, lo, "positions() field 6 == tickLower");
        assertEq(ptu, hi, "positions() field 7 == tickUpper");
        assertGt(pliq, 0, "positions() field 8 == liquidity");
    }

    function test_iface_positionManager_decreaseIncreaseCollect_roundTrip() public {
        address lp = makeAddr("lp2");
        deal(USDC, lp, 2_000_000_000);
        deal(WETH, lp, 1 ether);
        (, int24 tick,,,,,) = IUniswapV3PoolMin(POOL).slot0();
        int24 spacing = IUniswapV3PoolMin(POOL).tickSpacing();
        int24 lo = ((tick - 1000) / spacing) * spacing;
        int24 hi = ((tick + 1000) / spacing) * spacing;

        vm.startPrank(lp);
        IERC20(USDC).approve(POSITION_MANAGER, type(uint256).max);
        IERC20(WETH).approve(POSITION_MANAGER, type(uint256).max);
        (uint256 tokenId,,,) = INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: WETH,
                token1: USDC,
                fee: 500,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: 0.3 ether,
                amount1Desired: 1_000_000_000,
                amount0Min: 0,
                amount1Min: 0,
                recipient: lp,
                deadline: block.timestamp
            })
        );

        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);

        (uint128 incLiq, uint256 inc0, uint256 inc1) = INonfungiblePositionManager(POSITION_MANAGER).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 0.1 ether,
                amount1Desired: 300_000_000,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        assertGt(incLiq, 0, "increaseLiquidity field 1 == liquidity added");
        assertTrue(inc0 > 0 || inc1 > 0, "increaseLiquidity returned (used0, used1) in fields 2-3");

        (uint256 dec0, uint256 dec1) = INonfungiblePositionManager(POSITION_MANAGER).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liq,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        assertTrue(dec0 > 0 || dec1 > 0, "decreaseLiquidity returned (amount0, amount1)");

        (uint256 col0, uint256 col1) = INonfungiblePositionManager(POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: lp,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        assertTrue(col0 > 0 || col1 > 0, "collect swept the freed principal + fees");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // IPlatformConfig — matches the concrete AutoRangePlatformConfigV1
    // ---------------------------------------------------------------------

    function test_iface_platformConfig_matchesConcreteContract() public {
        address feeTok = makeAddr("feeToken");
        address op = makeAddr("op");
        address tre = makeAddr("tre");
        AutoRangePlatformConfigV1 c = new AutoRangePlatformConfigV1(address(this), feeTok, op, 777, 250, 3, tre);
        c.setCreationFeeBps(11);
        c.setForceRebalanceCooldownSeconds(21_600);
        c.setCreationFeeTierThresholdUsd(1_000_000_000);
        c.setCreationFeeFlatUsd(1_000_000);
        address[] memory pool = new address[](1);
        pool[0] = makeAddr("poolWallet");
        c.setOperatorPool(pool);

        IPlatformConfig i = IPlatformConfig(address(c));
        assertEq(i.feeToken(), feeTok);
        assertEq(i.defaultOperator(), op);
        assertEq(i.maxDepositUsd(), 777);
        assertEq(i.performanceFeeBps(), 250);
        assertEq(i.creationFeeUsdt(), 3);
        assertEq(i.creationFeeBps(), 11);
        assertEq(i.treasury(), tre);
        assertEq(i.forceRebalanceCooldownSeconds(), 21_600);
        (uint256 th, uint256 fl, uint256 bps) = i.creationFeeParams();
        assertEq(th, 1_000_000_000);
        assertEq(fl, 1_000_000);
        assertEq(bps, 11);
        assertEq(i.operatorPool().length, 1);
        assertEq(i.operatorPool()[0], pool[0]);
    }
}

interface IUniswapV3PoolMin {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);
}

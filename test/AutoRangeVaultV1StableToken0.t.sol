// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {AutoRangePlatformConfigV1} from "../src/official/AutoRangePlatformConfigV1.sol";
import {AutoRangeVaultFactoryV1} from "../src/official/AutoRangeVaultFactoryV1.sol";
import {AutoRangeVaultV1} from "../src/official/AutoRangeVaultV1.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";

/// @title Prueba 6 — the `stableIsToken0 == true` orientation.
///
/// Every other test in this suite forks Arbitrum, where the USDC/WETH pool
/// has WETH as token0 -> `stableIsToken0 == false`. This file forks
/// Ethereum mainnet, whose USDC/WETH 0.05% pool has USDC (the lower address)
/// as token0 -> `stableIsToken0 == true`, the mirror image. (Celo would be
/// the natural home for this — USDT < WETH there too — but Celo's move to
/// the OP Stack breaks `forge`'s fork EVM at recent blocks, so mainnet's
/// USDC-as-token0 pool is used instead: same flag, a real deep pool, a real
/// Chainlink feed.)
///
/// Exercises the branches that flip on that flag and are never hit by the
/// Arbitrum suite:
///   - _stableAddr / _volatileAddr / _toToken01 / _stableOf / _sellsVolatileForStable
///   - _nativeWeiToStableRaw  (the `stableIsToken0` branch: shift-then-divide
///                             twice, vs. the else branch's mul-then-shift)
///   - _hardStopTriggered     (ceiling: currentTick <= tick ; floor: currentTick >= tick
///                             — the OPPOSITE comparisons from Arbitrum)
///   - _hardStopOrderValid    (ceiling valid iff ceilingTick < floorTick)
///
/// Direction cheat-sheet (token0 = USDC, token1 = WETH):
///   USDC -> WETH  is token0ToToken1 = true   (tick DOWN, WETH pricier in USDC)
///   WETH -> USDC  is token0ToToken1 = false  (tick UP,   WETH cheaper in USDC)
///   a HIGHER tick == a LOWER WETH price (because stableIsToken0).
contract AutoRangeVaultV1StableToken0Test is Test {
    address constant POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05%, Ethereum mainnet
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // real token0 (6 decimals)
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // real token1
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant GAS_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH/USD, mainnet
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 constant FEE = 500;

    address platformOwner = makeAddr("platformOwner");
    address defaultOperator = makeAddr("defaultOperator");
    address treasury = makeAddr("treasury");
    address lp = makeAddr("lp");

    AutoRangePlatformConfigV1 config;
    AutoRangeVaultFactoryV1 factory;
    AutoRangeVaultV1 vault;
    IUniswapV3Pool pool = IUniswapV3Pool(POOL);
    int24 tickSpacing;

    uint256 constant MAX_DEPOSIT_USD = 20_000_000_000;
    uint256 constant PERF_BPS = 1_000;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.txGasPrice(1 gwei);
        tickSpacing = pool.tickSpacing();

        config = new AutoRangePlatformConfigV1(platformOwner, USDC, defaultOperator, MAX_DEPOSIT_USD, PERF_BPS, 0, treasury);
        factory =
            new AutoRangeVaultFactoryV1(address(config), POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE, UNISWAP_V3_FACTORY);

        vm.prank(lp);
        vault = AutoRangeVaultV1(factory.createVault(POOL, USDC, WETH, FEE));

        deal(USDC, lp, 10_000_000_000); // 10,000 USDC
        vm.prank(lp);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Helpers — orientation flipped vs. the Arbitrum file
    // ---------------------------------------------------------------------

    function _currentTick() internal view returns (int24 t) {
        (, t,,,,,) = pool.slot0();
    }

    function _alignedRangeAroundMarket(uint256 widthTicks) internal view returns (int24 lower, int24 upper) {
        int24 tick = _currentTick();
        int24 half = int24(uint24(widthTicks / 2));
        lower = ((tick - half) / tickSpacing) * tickSpacing;
        upper = ((tick + half) / tickSpacing) * tickSpacing;
        if (lower == upper) upper += tickSpacing;
    }

    function _noSwap() internal pure returns (AutoRangeVaultV1.SwapInstruction memory) {
        return AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0, amountOutMinimum: 0, fee: FEE});
    }

    /// USDC(token0) -> WETH(token1): token0ToToken1 = true.
    function _buyWeth(uint256 usdcIn) internal pure returns (AutoRangeVaultV1.SwapInstruction memory) {
        return AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: usdcIn, amountOutMinimum: 0, fee: FEE});
    }

    function _openPosition() internal returns (int24 lower, int24 upper) {
        (lower, upper) = _alignedRangeAroundMarket(2000);
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 50_000_000, investableAmount: 900_000_000, gasReserveAmount: 5_000_000});
        vault.configureTarget({
            investmentAmountUsd: 900_000_000,
            _targetTickLower: lower,
            _targetTickUpper: upper,
            _maxRebalances: 5,
            _reinjectionAmount: 10_000_000,
            _periodicRebalanceInterval: 1 days,
            _recenterMarginBps: 500,
            _exitTopCeilingMarginBps: 300,
            _feeClaimThresholdBps: 200,
            _feeClaimIntervalSeconds: 1 days,
            _exitTopRecenterMarginBps: 500
        });
        vault.setRiskParams(500, 0, 500);
        vm.stopPrank();
        vm.prank(defaultOperator);
        vault.initPosition(_buyWeth(450_000_000), 0, 0); // ~half of investable into WETH
    }

    function _push(bool usdcToWeth, uint256 amountIn) internal {
        address pusher = makeAddr("pusher");
        address tokenIn = usdcToWeth ? USDC : WETH;
        deal(tokenIn, pusher, amountIn);
        vm.startPrank(pusher);
        IERC20(tokenIn).approve(SWAP_ROUTER02, amountIn);
        ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: usdcToWeth ? WETH : USDC,
                fee: FEE,
                recipient: pusher,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _hasTopic0(Vm.Log[] memory logs, address emitter, string memory sig) internal pure returns (bool) {
        bytes32 t0 = keccak256(bytes(sig));
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == t0) return true;
        }
        return false;
    }

    function _invariantHolds() internal view {
        assertLe(vault.uncountedInvestable(), vault.investableUsdt(), "uncountedInvestable > investableUsdt");
    }

    /// USDC value of a WETH amount at spot, via the `stableIsToken0` price math.
    function _wethToUsdc(uint256 wethRaw) internal view returns (uint256) {
        (uint160 sp,,,,,,) = pool.slot0();
        uint256 step1 = (wethRaw << 96) / sp;
        return (step1 << 96) / sp;
    }

    // =====================================================================
    // Orientation basics + full lifecycle
    // =====================================================================

    function test_st0_stableIsToken0True_wiredCorrectly() public view {
        assertTrue(vault.stableIsToken0(), "USDC is the LOWER address here -> stable is token0");
        assertEq(vault.token0(), USDC);
        assertEq(vault.token1(), WETH);
        assertEq(vault.feeTier(), FEE);
    }

    function test_st0_fullLifecycle_openRebalanceWithdraw() public {
        _openPosition();
        assertGt(vault.positionTokenId(), 0, "the _toToken01 wiring minted a real position");
        _invariantHolds();

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 5_000_000, 0, 0);
        _invariantHolds();

        uint256 usdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 wethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        uint256 recovered = (IERC20(USDC).balanceOf(lp) - usdcBefore) + _wethToUsdc(IERC20(WETH).balanceOf(lp) - wethBefore);
        assertGe(recovered, 945_000_000, "owner recovers ~all of the ~$955 deposited (stableIsToken0 exit wiring)");
    }

    // =====================================================================
    // _hardStopOrderValid — ceiling valid iff ceilingTick < floorTick
    // =====================================================================

    function test_st0_hardStopOrder_directionAware() public {
        int24 mkt = _currentTick();
        vm.startPrank(lp);

        // Floor at a tick ABOVE market == a LOWER WETH price == a real floor.
        vault.setHardStop(false, true, mkt + 5 * tickSpacing, false);

        // Ceiling at a tick BELOW the floor's tick == a HIGHER WETH price == valid.
        vault.setHardStop(true, true, mkt - 5 * tickSpacing, false);
        assertTrue(vault.hardCeilingEnabled());

        // Ceiling ABOVE the floor's tick == a price at/below the floor == invalid.
        vm.expectRevert(AutoRangeVaultV1.InvalidHardStopOrder.selector);
        vault.setHardStop(true, true, mkt + 10 * tickSpacing, false);
        vm.stopPrank();
    }

    // =====================================================================
    // _hardStopTriggered — the OPPOSITE comparisons from Arbitrum
    // =====================================================================

    function test_st0_hardCeiling_triggersAsWethGetsExpensive_tickDrops() public {
        _openPosition();
        // aboveCeiling when stableIsToken0: currentTick <= hardCeilingTick.
        // WETH gets pricier as the tick DROPS -> ceiling just below market,
        // push USDC -> WETH.
        int24 ceilingTick = _currentTick() - tickSpacing;
        vm.prank(lp);
        vault.setHardStop(true, true, ceilingTick, false);

        _push(true, 60_000_000_000_000); // 60M USDC -> WETH
        assertLe(_currentTick(), ceilingTick, "sanity: tick dropped past the ceiling");

        vm.recordLogs();
        vm.prank(lp);
        uint256 newId = vault.ownerRebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        assertEq(newId, 0, "ceiling exit mints nothing");
        assertEq(vault.positionTokenId(), 0);
        assertTrue(vault.paused());
        assertTrue(_hasTopic0(vm.getRecordedLogs(), address(vault), "HardCeilingTriggered(uint256)"));
        _invariantHolds();
    }

    function test_st0_hardFloor_triggersAsWethGetsCheap_tickRises() public {
        _openPosition();
        // belowFloor when stableIsToken0: currentTick >= hardFloorTick.
        // WETH gets cheaper as the tick RISES -> floor just above market,
        // push WETH -> USDC.
        int24 floorTick = _currentTick() + tickSpacing;
        vm.prank(lp);
        vault.setHardStop(false, true, floorTick, false);

        _push(false, 20_000 ether); // WETH -> USDC
        assertGe(_currentTick(), floorTick, "sanity: tick rose past the floor");

        vm.recordLogs();
        vm.prank(lp);
        vault.ownerRebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        assertEq(vault.positionTokenId(), 0);
        assertTrue(vault.paused());
        assertTrue(_hasTopic0(vm.getRecordedLogs(), address(vault), "HardFloorTriggered(uint256)"));
        _invariantHolds();
    }

    // =====================================================================
    // withdraw() 4-bucket + dust + ledger invariant, stableIsToken0 branch
    // =====================================================================

    function test_st0_withdrawFourBuckets_and_dust() public {
        _openPosition();
        vm.prank(lp);
        vault.deposit({reserveAmount: 100_000_000, investableAmount: 0, gasReserveAmount: 20_000_000});
        uint256 reserveBefore = vault.reserveBalance();
        uint256 gasBefore = vault.gasReserveBalance();

        deal(USDC, address(this), 2_000_000);
        IERC20(USDC).transfer(address(vault), 2_000_000); // unaccounted raw dust

        uint256 lpBefore = IERC20(USDC).balanceOf(lp);
        vm.prank(lp);
        vault.withdraw(0, 0, 3_000, 5_000, 2_000_000, 0, _noSwap(), _noSwap(), 0, 0);

        assertEq(vault.reserveBalance(), reserveBefore - reserveBefore * 3_000 / 10_000, "reserve -30% exact");
        assertEq(vault.gasReserveBalance(), gasBefore - gasBefore * 5_000 / 10_000, "gas -50% exact, independent");
        uint256 expected = reserveBefore * 3_000 / 10_000 + gasBefore * 5_000 / 10_000 + 2_000_000;
        assertEq(IERC20(USDC).balanceOf(lp) - lpBefore, expected, "two bucket shares + swept dust");
        _invariantHolds();

        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.InvalidDustAmount.selector);
        vault.withdraw(0, 0, 0, 0, 1, 0, _noSwap(), _noSwap(), 0, 0);
    }

    function test_st0_gasOracleDown_operatorActionStillSucceeds() public {
        _openPosition();
        uint256 gasReserve0 = vault.gasReserveBalance();
        vm.mockCallRevert(GAS_ORACLE, abi.encodeWithSignature("latestRoundData()"), "oracle down");
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0);
        assertEq(vault.gasReserveBalance(), gasReserve0, "no reimbursement, op still succeeded (stableIsToken0 path)");
        _invariantHolds();
    }
}

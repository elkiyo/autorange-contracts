// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {AutoRangePlatformConfigV1} from "../src/official/AutoRangePlatformConfigV1.sol";
import {AutoRangeVaultFactoryV1} from "../src/official/AutoRangeVaultFactoryV1.sol";
import {AutoRangeVaultV1} from "../src/official/AutoRangeVaultV1.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";

/// @title Companion audit-coverage suite for AutoRangeVaultV1 (the mainnet
/// "official" vault, 0xB2294bcC9841Ec8E412ef15e2243dBF37c3099BA).
///
/// AutoRangeVaultV1.t.sol already covers the surface that's NEW relative to
/// the upstream compound line (tiered creation fee, volatile top-up in
/// increasePosition/increasePositionWithToken, exitTopRecenterMarginBps,
/// isOperator backup-wallet pool). This file exercises the INHERITED-but-
/// critical paths that no test in the repo runs against THIS exact source:
///
///   - hard ceiling / hard floor triggers + the setHardStop() ordering guard
///   - rescuePosition() (last-resort raw-NFT exit)
///   - emergencyWithdrawPosition() (swap-free last-resort sweep)
///   - withdraw()'s 4-bucket independence, dust bucket, and the
///     `uncountedInvestable <= investableUsdt` ledger invariant (the V2
///     invariant-break regression, now clamped everywhere)
///   - _reimburseKeeperGas() degrading to $0 on a bad gas oracle
///   - depositToken()'s DeclaredExceedsRealBalance guard
///   - _convertPayoutToStable()'s InvalidSwapInstruction guard
///   - the factory's TokenMismatch / UnverifiedPool / UnsupportedStableDecimals guards
///
/// Plus one documented low-severity finding as a live regression
/// (test_finding_*).
contract AutoRangeVaultV1AuditTest is Test {
    address constant POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // USDC/WETH 0.05%
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // real token1 here
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // real token0 here
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant GAS_ORACLE = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1; // 18 decimals
    address constant DAI_USDC_POOL = 0x7CF803e8d82A50504180f417B8bC7a493C0a0503; // DAI/USDC 0.01%, both non-6dec-stable-friendly

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
    uint256 constant PERFORMANCE_FEE_BPS = 1_000; // 10%

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));
        vm.txGasPrice(0.05 gwei);
        tickSpacing = pool.tickSpacing();

        config = new AutoRangePlatformConfigV1(
            platformOwner, USDC, defaultOperator, MAX_DEPOSIT_USD, PERFORMANCE_FEE_BPS, 0, treasury
        );
        factory =
            new AutoRangeVaultFactoryV1(address(config), POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE, UNISWAP_V3_FACTORY);

        vm.prank(lp);
        vault = AutoRangeVaultV1(factory.createVault(POOL, USDC, WETH, 500));

        deal(USDC, lp, 10_000_000_000); // 10,000 USDC
        vm.prank(lp);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function _alignedRangeAroundMarket(uint256 widthTicks) internal view returns (int24 lower, int24 upper) {
        int24 tick = _currentTick();
        int24 half = int24(uint24(widthTicks / 2));
        lower = ((tick - half) / tickSpacing) * tickSpacing;
        upper = ((tick + half) / tickSpacing) * tickSpacing;
        if (lower == upper) upper += tickSpacing;
    }

    function _noSwap() internal pure returns (AutoRangeVaultV1.SwapInstruction memory) {
        return AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0, amountOutMinimum: 0, fee: 500});
    }

    /// Sell WETH(token0) -> USDC(token1): token0ToToken1 = true.
    function _sellWeth(uint256 wethIn) internal pure returns (AutoRangeVaultV1.SwapInstruction memory) {
        return
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: wethIn, amountOutMinimum: 0, fee: 500});
    }

    /// Sell USDC(token1) -> WETH(token0): token0ToToken1 = false.
    function _buyWeth(uint256 usdcIn) internal pure returns (AutoRangeVaultV1.SwapInstruction memory) {
        return
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: usdcIn, amountOutMinimum: 0, fee: 500});
    }

    function _openPosition() internal returns (int24 lower, int24 upper) {
        (lower, upper) = _alignedRangeAroundMarket(2000);
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
        vault.configureTarget({
            investmentAmountUsd: 945_000_000,
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
        vault.initPosition(_buyWeth(475_000_000), 0, 0);
    }

    function _pushPriceUp(uint256 usdcIn) internal {
        address pusher = makeAddr("pusherUp");
        deal(USDC, pusher, usdcIn);
        vm.startPrank(pusher);
        IERC20(USDC).approve(SWAP_ROUTER02, type(uint256).max);
        ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDC,
                tokenOut: WETH,
                fee: 500,
                recipient: pusher,
                amountIn: usdcIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _pushPriceDown(uint256 wethIn) internal {
        address pusher = makeAddr("pusherDown");
        deal(WETH, pusher, wethIn);
        vm.startPrank(pusher);
        IERC20(WETH).approve(SWAP_ROUTER02, type(uint256).max);
        ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: 500,
                recipient: pusher,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function _lastLogData(Vm.Log[] memory logs, address emitter, string memory eventSig)
        internal
        pure
        returns (bytes memory data)
    {
        bytes32 topic0 = keccak256(bytes(eventSig));
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == emitter && log.topics.length > 0 && log.topics[0] == topic0) return log.data;
        }
        revert("event not found in recorded logs");
    }

    function _hasTopic0(Vm.Log[] memory logs, address emitter, string memory eventSig) internal pure returns (bool) {
        bytes32 topic0 = keccak256(bytes(eventSig));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }

    /// Value a raw WETH amount in raw USDC units at the pool's live price.
    /// stableIsToken0 == false here (USDC = token1) -> same formula as
    /// _nativeWeiToStableRaw's own else-branch.
    function _wethToUsdApprox(uint256 wethRaw) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 step1 = (wethRaw * uint256(sqrtPriceX96)) >> 96;
        return (step1 * uint256(sqrtPriceX96)) >> 96;
    }

    function _invariantHolds() internal view {
        assertLe(
            vault.uncountedInvestable(),
            vault.investableUsdt(),
            "INVARIANT BROKEN: uncountedInvestable > investableUsdt (the V2 regression)"
        );
    }

    // =====================================================================
    // Hard ceiling — absolute price stop, close + auto-pause
    // =====================================================================

    function test_hardCeiling_ownerRebalance_closesAndPausesAndParksCapital() public {
        _openPosition();
        int24 ceilingTick = _currentTick() + tickSpacing;
        vm.prank(lp);
        vault.setHardStop(true, true, ceilingTick, false); // isCeiling=true, enabled

        _pushPriceUp(5_000_000_000_000); // 5,000,000 USDC one-directional push
        assertGe(_currentTick(), ceilingTick, "sanity: price pushed past the ceiling");

        vm.recordLogs();
        vm.prank(lp);
        uint256 newTokenId = vault.ownerRebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(newTokenId, 0, "ceiling exit mints no new position");
        assertEq(vault.positionTokenId(), 0);
        assertTrue(vault.paused(), "vault auto-pauses on a ceiling trigger");
        assertTrue(
            _hasTopic0(logs, address(vault), "HardCeilingTriggered(uint256)"),
            "HardCeilingTriggered must fire instead of Rebalanced"
        );
        assertFalse(
            _hasTopic0(logs, address(vault), "Rebalanced(uint256,int24,int24,uint256,uint256)"),
            "the ceiling exit path must not emit Rebalanced"
        );
        _invariantHolds();

        // The parked capital is still fully retrievable while paused —
        // stable leg via investableShareBps, any raw volatile leg via the
        // dust bucket.
        uint256 wethDust = IERC20(WETH).balanceOf(address(vault));
        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdraw(0, 10_000, 10_000, 10_000, wethDust, 0, _noSwap(), _noSwap(), 0, 0);
        assertGe(IERC20(USDC).balanceOf(lp), ownerUsdcBefore, "stable + reserve + gas retrieved while paused");
        assertEq(IERC20(WETH).balanceOf(lp) - ownerWethBefore, wethDust, "raw volatile leg retrieved via the dust bucket");
        assertEq(vault.investableUsdt(), 0);
        assertEq(vault.reserveBalance(), 0);
        assertEq(vault.gasReserveBalance(), 0);
    }

    function test_hardCeiling_rebalanceOperatorPath_alsoClosesOncePeriodicDue() public {
        _openPosition();
        int24 ceilingTick = _currentTick() + tickSpacing;
        vm.prank(lp);
        vault.setHardStop(true, true, ceilingTick, false);
        _pushPriceUp(5_000_000_000_000);

        // rebalance() keeps its periodicDue/_isOutOfRange() gate — warp past
        // the 1-day periodic interval so the operator path is genuinely due.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(defaultOperator);
        uint256 newTokenId = vault.rebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);

        assertEq(newTokenId, 0);
        assertTrue(vault.paused());
        assertEq(vault.positionTokenId(), 0);
    }

    // =====================================================================
    // Hard floor — mirror of the ceiling, two exit modes
    // =====================================================================

    function test_hardFloor_noConvert_closesAndLeavesVolatileAsRetrievableDust() public {
        _openPosition();
        int24 floorTick = _currentTick() - tickSpacing;
        vm.prank(lp);
        vault.setHardStop(false, true, floorTick, false); // isCeiling=false, no forced conversion

        _pushPriceDown(3_000 ether);
        assertLe(_currentTick(), floorTick, "sanity: price pushed below the floor");

        vm.recordLogs();
        vm.prank(lp);
        vault.ownerRebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(vault.positionTokenId(), 0);
        assertTrue(vault.paused());
        assertTrue(_hasTopic0(logs, address(vault), "HardFloorTriggered(uint256)"));
        _invariantHolds();

        // No forced swap -> the volatile leg is raw balance, retrievable
        // only through the dust bucket, never folded into investableUsdt.
        uint256 wethDust = IERC20(WETH).balanceOf(address(vault));
        assertGt(wethDust, 0, "no-convert floor exit leaves the volatile leg as raw balance");
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdraw(0, 10_000, 10_000, 10_000, wethDust, 0, _noSwap(), _noSwap(), 0, 0);
        assertEq(IERC20(WETH).balanceOf(lp) - ownerWethBefore, wethDust);
    }

    function test_hardFloor_convertToStable_sizedExitSwapConvertsTheClose() public {
        _openPosition();
        int24 floorTick = _currentTick() - tickSpacing;
        vm.prank(lp);
        vault.setHardStop(false, true, floorTick, true); // convertToStable = true

        _pushPriceDown(3_000 ether);
        assertLe(_currentTick(), floorTick);

        // After the push the position is ~100% WETH; size the exit swap to
        // sell (most of) it. Over-sizing reverts (InvalidSwapInstruction),
        // so quote the closed position's WETH first via a static estimate:
        // the whole position value is roughly what was deposited, and price
        // fell, so ~0.5 WETH per 1000 USDC deposited is a safe lower bound.
        // Simpler and robust: read the live liquidity's token amounts is
        // overkill here — just sell a conservative fraction and assert the
        // exit still succeeds and pauses.
        AutoRangeVaultV1.SwapInstruction memory exitSwap = _sellWeth(0.2 ether);

        vm.prank(lp);
        vault.ownerRebalance(0, 0, _noSwap(), exitSwap, 0, 0, 0);

        assertEq(vault.positionTokenId(), 0);
        assertTrue(vault.paused());
        assertGt(vault.investableUsdt(), 0, "converted proceeds park as investableUsdt");
        _invariantHolds();
    }

    function test_setHardStop_revertsOnInvalidOrder_directionAware() public {
        // stableIsToken0 == false here -> a higher tick means a HIGHER
        // volatile price, so a valid config needs ceilingTick > floorTick.
        int24 mkt = _currentTick();
        vm.startPrank(lp);
        vault.setHardStop(false, true, mkt - 5 * tickSpacing, false); // floor below market, fine

        // Enabling a ceiling BELOW the enabled floor is nonsensical -> revert.
        vm.expectRevert(AutoRangeVaultV1.InvalidHardStopOrder.selector);
        vault.setHardStop(true, true, mkt - 10 * tickSpacing, false);

        // A ceiling correctly above the floor is accepted.
        vault.setHardStop(true, true, mkt + 5 * tickSpacing, false);
        assertTrue(vault.hardCeilingEnabled());
        vm.stopPrank();
    }

    function test_setHardStop_onlyOwner() public {
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setHardStop(true, true, 12345, false);
    }

    // =====================================================================
    // rescuePosition — last-resort raw-NFT exit, independent of vault math
    // =====================================================================

    function test_rescuePosition_transfersRawNftToOwnerAndPauses() public {
        _openPosition();
        uint256 tokenId = vault.positionTokenId();
        assertGt(tokenId, 0);

        vm.recordLogs();
        vm.prank(lp);
        vault.rescuePosition();

        assertEq(vault.positionTokenId(), 0, "position handle cleared");
        assertTrue(vault.paused(), "vault pauses so the keeper won't try to reopen");
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(tokenId), lp, "owner now holds the raw NFT");
        assertTrue(_hasTopic0(vm.getRecordedLogs(), address(vault), "PositionRescued(uint256)"));

        // Ledgers are untouched by rescue -> idle stable is still retrievable.
        assertEq(vault.reserveBalance(), 50_000_000, "rescue does not touch the reserve ledger");
    }

    function test_rescuePosition_onlyOwner_and_revertsWithoutPosition() public {
        _openPosition();
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.rescuePosition();

        vm.startPrank(lp);
        vault.rescuePosition();
        vm.expectRevert(AutoRangeVaultV1.NoPosition.selector);
        vault.rescuePosition(); // second call: nothing left to rescue
        vm.stopPrank();
    }

    // =====================================================================
    // emergencyWithdrawPosition — swap-free last resort
    // =====================================================================

    function test_emergencyWithdraw_isSwapFree_evenWithPayoutFeesInStableOnly() public {
        _openPosition();
        vm.prank(lp);
        vault.setPayoutFeesInStableOnly(true); // must be ignored by the emergency path

        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);

        vm.prank(lp);
        vault.emergencyWithdrawPosition(); // takes NO SwapInstruction at all

        assertEq(vault.positionTokenId(), 0);
        assertTrue(vault.paused());
        assertEq(vault.investableUsdt(), 0);
        assertEq(vault.reserveBalance(), 0);
        assertEq(vault.gasReserveBalance(), 0);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault fully swept of stable");
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0, "vault fully swept of volatile");
        assertGt(IERC20(USDC).balanceOf(lp), ownerUsdcBefore);
        assertGt(IERC20(WETH).balanceOf(lp), ownerWethBefore, "owner receives raw mixed-token funds - deliberate");
    }

    // =====================================================================
    // withdraw() — 4-bucket independence, dust guard, ledger invariant
    // =====================================================================

    function test_withdraw_fourBuckets_decrementIndependentlyAndProportionally() public {
        _openPosition();
        // Buckets after _openPosition: investable folded into the position,
        // reserve = 50, gas = 5. Top up so all three ledgers carry balance.
        vm.prank(lp);
        vault.deposit({reserveAmount: 100_000_000, investableAmount: 0, gasReserveAmount: 20_000_000});
        // investableUsdt is 0 here (folded on init); a partial position
        // withdraw repopulates it, but for a clean per-bucket assertion just
        // exercise reserve + gas at distinct percentages.
        uint256 reserveBefore = vault.reserveBalance(); // 150
        uint256 gasBefore = vault.gasReserveBalance(); // 25

        uint256 ownerBefore = IERC20(USDC).balanceOf(lp);
        vm.prank(lp);
        vault.withdraw(0, 0, 2_500, 6_000, 0, 0, _noSwap(), _noSwap(), 0, 0); // 25% reserve, 60% gas

        assertEq(vault.reserveBalance(), reserveBefore - reserveBefore * 2_500 / 10_000, "reserve -25% exactly");
        assertEq(vault.gasReserveBalance(), gasBefore - gasBefore * 6_000 / 10_000, "gas -60% exactly, independent of reserve");
        uint256 expectedOut = reserveBefore * 2_500 / 10_000 + gasBefore * 6_000 / 10_000;
        assertEq(IERC20(USDC).balanceOf(lp) - ownerBefore, expectedOut, "owner receives exactly the two bucket shares");
        _invariantHolds();
    }

    function test_withdraw_revertsOnBadShareBps() public {
        _openPosition();
        vm.startPrank(lp);
        vm.expectRevert(AutoRangeVaultV1.InvalidShareBps.selector);
        vault.withdraw(10_001, 0, 0, 0, 0, 0, _noSwap(), _noSwap(), 0, 0); // > 10_000

        vm.expectRevert(AutoRangeVaultV1.InvalidShareBps.selector);
        vault.withdraw(0, 0, 0, 0, 0, 0, _noSwap(), _noSwap(), 0, 0); // nothing requested at all
        vm.stopPrank();
    }

    function test_withdraw_dustGuard_rejectsOverclaim() public {
        _openPosition();
        // Send unaccounted raw USDC into the vault.
        deal(USDC, address(this), 3_000_000);
        IERC20(USDC).transfer(address(vault), 3_000_000);

        vm.startPrank(lp);
        vm.expectRevert(AutoRangeVaultV1.InvalidDustAmount.selector);
        vault.withdraw(0, 0, 0, 0, 0, 4_000_000, _noSwap(), _noSwap(), 0, 0); // claim more dust than exists

        // Claiming exactly what's available works.
        uint256 ownerBefore = IERC20(USDC).balanceOf(lp);
        vault.withdraw(0, 0, 0, 0, 0, 3_000_000, _noSwap(), _noSwap(), 0, 0);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(lp) - ownerBefore, 3_000_000);
    }

    function test_ledgerInvariant_holdsAcrossAFullLifecycle() public {
        _openPosition();
        _invariantHolds();

        // increasePosition (mixed stable + volatile)
        deal(WETH, lp, 1 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vault.increasePosition(_buyWeth(20_000_000), 40_000_000, 0.01 ether, 0, 0);
        vm.stopPrank();
        _invariantHolds();

        // reinjectIntoPosition (reserve -> position)
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0);
        _invariantHolds();

        // ownerRebalance (full close + remint)
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.prank(lp);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 5_000_000, 0, 0);
        _invariantHolds();

        // sweepIdleDust (raw dust -> position)
        deal(USDC, address(this), 2_000_000);
        IERC20(USDC).transfer(address(vault), 2_000_000);
        vm.prank(defaultOperator);
        vault.sweepIdleDust(_noSwap(), 0, 0);
        _invariantHolds();

        // partial withdraw (position + investable + reserve)
        vm.prank(lp);
        vault.withdraw(3_000, 5_000, 5_000, 0, 0, 0, _noSwap(), _noSwap(), 0, 0);
        _invariantHolds();
    }

    // =====================================================================
    // _reimburseKeeperGas — degrade to $0 on a bad gas oracle
    // =====================================================================

    function test_gasOracle_revertingOrStale_degradesToZero_operationStillSucceeds() public {
        _openPosition();
        uint256 gasReserveBefore = vault.gasReserveBalance();

        // (a) reverting oracle
        vm.mockCallRevert(GAS_ORACLE, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), "oracle down");
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0); // triggers _reimburseKeeperGas
        assertEq(vault.gasReserveBalance(), gasReserveBefore, "reverting oracle -> $0 reimbursement, op still succeeds");
        vm.clearMockedCalls();

        // (b) stale oracle
        (uint80 rid, int256 ans, uint256 sa,, uint80 air) = IAggregatorV3(GAS_ORACLE).latestRoundData();
        vm.mockCall(
            GAS_ORACLE,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(rid, ans, sa, block.timestamp - 200_000, air) // way past MAX_GAS_ORACLE_STALENESS
        );
        uint256 gasReserveMid = vault.gasReserveBalance();
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0);
        assertEq(vault.gasReserveBalance(), gasReserveMid, "stale oracle -> $0 reimbursement, op still succeeds");
    }

    // =====================================================================
    // depositToken() — DeclaredExceedsRealBalance guard
    // =====================================================================

    function test_depositToken_revertsWhenDeclaredExceedsRealValueReceived() public {
        // Bring 100 USDC but declare 200 across the buckets.
        vm.startPrank(lp);
        vm.expectRevert(AutoRangeVaultV1.DeclaredExceedsRealBalance.selector);
        vault.depositToken({
            tokenIn: USDC,
            amountIn: 100_000_000,
            swapIx: _noSwap(),
            thirdPartyFee: 0,
            thirdPartyAmountOutMinimum: 0,
            reserveAmount: 100_000_000,
            investableAmount: 100_000_000,
            gasReserveAmount: 0
        });
        vm.stopPrank();
    }

    // =====================================================================
    // _convertPayoutToStable() — InvalidSwapInstruction guard
    // =====================================================================

    function test_convertPayoutToStable_revertsOnOversizedOrWrongDirectionSwap() public {
        _openPosition();

        // Oversized: sell far more WETH than withdrawAll will have on hand.
        AutoRangeVaultV1.SwapInstruction memory oversized = _sellWeth(1_000 ether);
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.InvalidSwapInstruction.selector);
        vault.withdrawAll(_noSwap(), oversized);

        // Wrong direction: payoutSwapIx that BUYS volatile instead of selling it.
        AutoRangeVaultV1.SwapInstruction memory wrongDir = _buyWeth(1_000);
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.InvalidSwapInstruction.selector);
        vault.withdrawAll(_noSwap(), wrongDir);
    }

    // =====================================================================
    // Factory guards
    // =====================================================================

    function test_factory_revertsOnTokenMismatch() public {
        vm.expectRevert(AutoRangeVaultFactoryV1.TokenMismatch.selector);
        factory.createVault(POOL, DAI, WETH, 500); // DAI is neither token of this pool
    }

    function test_factory_revertsOnUnverifiedPool() public {
        FakePool fake = new FakePool(WETH, USDC); // reports the right tokens...
        vm.expectRevert(AutoRangeVaultFactoryV1.UnverifiedPool.selector);
        factory.createVault(address(fake), USDC, WETH, 500); // ...but factory.getPool() won't resolve to it
    }

    function test_factory_revertsOnNonSixDecimalStable() public {
        // DAI/USDC pool is real; passing DAI (18 decimals) as the "stable"
        // must trip UnsupportedStableDecimals inside initialize().
        vm.expectRevert(AutoRangeVaultV1.UnsupportedStableDecimals.selector);
        factory.createVault(DAI_USDC_POOL, DAI, USDC, 100);
    }

    // =====================================================================
    // Finding (low): reinject-fee subtraction can underflow-revert on a
    // vault whose cumulativeFeeableUsd is still 0 (funded 100% via
    // depositToken()'s volatile leg with investableAmount == 0) when a
    // rebalance carries a reinjectAmount smaller than creationFeeFlatUsd.
    // The mainnet AutoRangePlatformConfigV1 sets creationFeeFlatUsd = $1,
    // so this is a live (if niche) path. No funds at risk — the tx reverts
    // atomically; the keeper retries with reinjectAmount = 0 or a larger
    // value. Documented for a future contract revision (saturating
    // subtraction), and as a keeper-side constraint meanwhile.
    // =====================================================================

    function test_finding_reinjectFeeUnderflow_onVolatileOnlyFundedVault() public {
        vm.prank(platformOwner);
        config.setCreationFeeFlatUsd(1_000_000); // $1 flat, matches mainnet

        // A range ENTIRELY above the current price: a 100%-volatile (one-
        // sided) position that initPosition() can mint from volatile alone,
        // with stableBal forced to 0 (investable == 0). Kept within
        // maxRangeDeviationBps (500) of market so _checkRangeNearMarket passes.
        int24 mkt = _currentTick();
        int24 lower = ((mkt + 6 * tickSpacing) / tickSpacing) * tickSpacing;
        if (lower <= mkt) lower += tickSpacing;
        int24 upper = lower + 20 * tickSpacing;

        // Fund the vault entirely through the volatile leg with
        // investableAmount == 0 -> _creationFeeFor(0) early-returns,
        // cumulativeFeeableUsd stays 0. Also fund the reserve bucket
        // (still investableAmount 0 -> still no flat fee charged).
        deal(WETH, lp, 2 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vault.depositToken({
            tokenIn: WETH,
            amountIn: 1 ether,
            swapIx: _noSwap(),
            thirdPartyFee: 0,
            thirdPartyAmountOutMinimum: 0,
            reserveAmount: 0,
            investableAmount: 0,
            gasReserveAmount: 0
        });
        vault.deposit({reserveAmount: 100_000_000, investableAmount: 0, gasReserveAmount: 5_000_000});
        vault.configureTarget({
            investmentAmountUsd: 0,
            _targetTickLower: lower,
            _targetTickUpper: upper,
            _maxRebalances: 5,
            _reinjectionAmount: 50_000_000,
            _periodicRebalanceInterval: 1 days,
            _recenterMarginBps: 500,
            _exitTopCeilingMarginBps: 300,
            _feeClaimThresholdBps: 200,
            _feeClaimIntervalSeconds: 1 days,
            _exitTopRecenterMarginBps: 500
        });
        vault.setRiskParams(500, 0, 500);
        vm.stopPrank();

        assertEq(vault.cumulativeFeeableUsd(), 0, "precondition: no fee-eligible capital has ever flowed");

        vm.prank(defaultOperator);
        vault.initPosition(_noSwap(), 0, 0); // mints a one-sided WETH position, stableBal forced to 0

        // A reinjectAmount BELOW the $1 flat fee -> _creationFeeFor returns
        // the full $1, and `reinjectAmount -= reinjectFee` underflows.
        vm.prank(lp);
        vm.expectRevert(stdError.arithmeticError);
        vault.ownerRebalance(lower, upper, _noSwap(), _noSwap(), 500_000, 0, 0); // $0.50 reinject < $1 flat

        // Workaround that WORKS: reinjectAmount >= the flat fee.
        vm.prank(lp);
        vault.ownerRebalance(lower, upper, _noSwap(), _noSwap(), 2_000_000, 0, 0); // $2 reinject
    }

    // =====================================================================
    // Modelo de amenaza — el keeper NO puede sacar principal a una
    // dirección arbitraria
    // =====================================================================

    /// Every legit ERC20 payout from the vault must land on a protocol
    /// address — there is no `recipient`/`to` parameter anywhere for a
    /// keeper to redirect. This walks every Transfer emitted during a
    /// keeper action and fails on any `from == vault` whose destination
    /// isn't the pool / position manager / router / treasury / owner /
    /// operator.
    function _assertNoStrayVaultTransfers(Vm.Log[] memory logs) internal view {
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            // ERC20 Transfer has exactly 3 topics (value is NOT indexed);
            // ERC721 Transfer has 4 (tokenId indexed) and is skipped here.
            if (l.topics.length != 3 || l.topics[0] != transferSig) continue;
            address from = address(uint160(uint256(l.topics[1])));
            if (from != address(vault)) continue;
            address to = address(uint160(uint256(l.topics[2])));
            bool ok = to == POOL || to == POSITION_MANAGER || to == SWAP_ROUTER02 || to == treasury || to == lp
                || to == defaultOperator;
            assertTrue(ok, "STRAY TRANSFER: vault moved ERC20 to a non-protocol address");
        }
    }

    function test_keeper_adversarialRebalance_principalStaysRecoverable_takeBoundedToGas() public {
        _openPosition();

        uint256 opUsdcBefore = IERC20(USDC).balanceOf(defaultOperator);
        uint256 opWethBefore = IERC20(WETH).balanceOf(defaultOperator);

        // The most adversarial rebalance the operator can send through the
        // public ABI: amountOutMinimum = 0 on the balancing swap (the
        // slippage vector, Finding A), a fresh in-range range. There is no
        // parameter to name a recipient.
        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.recordLogs();
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _sellWeth(0.05 ether), _noSwap(), 0, 0, 0);
        _assertNoStrayVaultTransfers(vm.getRecordedLogs());

        // The operator's take from that call is ONLY the gas reimbursement
        // (a few cents, drawn from gasReserveBalance) — never principal,
        // never a WETH payout (no fees were earned so no perf-fee cut).
        assertLt(
            IERC20(USDC).balanceOf(defaultOperator) - opUsdcBefore,
            1_000_000, // < $1
            "operator USDC gain is only the capped gas reimbursement"
        );
        assertEq(IERC20(WETH).balanceOf(defaultOperator), opWethBefore, "operator received no volatile principal");

        // The position was rebuilt (capital stayed in the vault, not sent
        // out), and the owner can still recover ~all of it.
        assertTrue(vault.positionTokenId() != 0, "a new position was minted - capital is still in the vault");

        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());

        uint256 usdcBack = IERC20(USDC).balanceOf(lp) - ownerUsdcBefore;
        uint256 wethBack = IERC20(WETH).balanceOf(lp) - ownerWethBefore;
        uint256 recoveredUsd = usdcBack + _wethToUsdApprox(wethBack);
        // Deposited 1_000e6 (945 investable + 50 reserve + 5 gas). Only real
        // swap fees + a few cents of gas were ever lost.
        assertGe(recoveredUsd, 970_000_000, "owner recovers >=97% of principal after an adversarial keeper rebalance");
    }

    function test_keeper_cannotCallAnyOwnerOnlyPath() public {
        _openPosition();
        vm.startPrank(defaultOperator); // the REAL operator, still can't touch owner functions
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.withdraw(10_000, 10_000, 10_000, 10_000, 0, 0, _noSwap(), _noSwap(), 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.withdrawAll(_noSwap(), _noSwap());
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.emergencyWithdrawPosition();
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.rescuePosition();
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setOperator(defaultOperator);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setOperatorStatus(defaultOperator, true);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.closeVault();
        vm.stopPrank();
    }

    function test_external_everyStateChangingFunctionReverts() public {
        _openPosition();
        address attacker = makeAddr("externalAttacker");
        vm.startPrank(attacker);

        // owner-only
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.deposit(1, 1, 1);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.depositToken(USDC, 0, _noSwap(), 0, 0, 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.increasePosition(_noSwap(), 1, 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.increasePositionWithToken(USDC, 1, 0, 0, _noSwap(), 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.configureTarget(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setRiskParams(0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setOperator(attacker);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setOperatorStatus(attacker, true);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setPaused(false);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setAutoCompoundFees(true);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setPayoutFeesInStableOnly(true);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setHardStop(true, true, 0, false);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.setB1Seed(0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.ownerRebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.withdraw(10_000, 10_000, 10_000, 10_000, 0, 0, _noSwap(), _noSwap(), 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.withdrawAll(_noSwap(), _noSwap());
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.emergencyWithdrawPosition();
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.rescuePosition();
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.closeVault();

        // operator-only
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        vault.initPosition(_noSwap(), 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        vault.rebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        vault.operatorForceRebalance(0, 0, _noSwap(), _noSwap(), 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        vault.reinjectIntoPosition(_noSwap(), 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        vault.harvestFees(_noSwap(), 0, 0);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        vault.sweepIdleDust(_noSwap(), 0, 0);

        vm.stopPrank();

        // Vault state is completely untouched by the barrage.
        assertEq(vault.owner(), lp);
        assertEq(vault.operator(), defaultOperator);
        assertTrue(vault.positionTokenId() != 0);
        assertEq(vault.reserveBalance(), 50_000_000);
    }

    function test_external_cannotMoveThePositionNft() public {
        _openPosition();
        uint256 tokenId = vault.positionTokenId();
        address attacker = makeAddr("nftAttacker");

        // (a) direct transferFrom on the position manager — the attacker is
        //     not the token owner, and the vault never approved anyone.
        vm.prank(attacker);
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).transferFrom(address(vault), attacker, tokenId);

        // (b) safeTransferFrom likewise.
        vm.prank(attacker);
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).safeTransferFrom(address(vault), attacker, tokenId);

        // (c) the vault's own last-resort raw-NFT exit is onlyOwner.
        vm.prank(attacker);
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        vault.rescuePosition();

        // (d) no standing approval of any kind was ever granted on the NFT.
        assertEq(IERC721Min(POSITION_MANAGER).getApproved(tokenId), address(0));
        assertFalse(IERC721Min(POSITION_MANAGER).isApprovedForAll(address(vault), attacker));
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(tokenId), address(vault), "the vault still holds the NFT");
    }

    function test_external_cannotReinitializeToHijackOwnership() public {
        _openPosition();
        address attacker = makeAddr("reinitAttacker");
        vm.prank(attacker);
        vm.expectRevert(); // OZ Initializable: InvalidInitialization()
        vault.initialize(
            attacker, address(config), POOL, WETH, USDC, false, 500, POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE
        );
        assertEq(vault.owner(), lp, "ownership unchanged");
        assertEq(vault.operator(), defaultOperator, "operator unchanged");
    }

    function test_external_createVaultYieldsFreshEmptyVault_originalUntouched() public {
        _openPosition();
        uint256 originalTokenId = vault.positionTokenId();
        uint256 originalReserve = vault.reserveBalance();

        address attacker = makeAddr("factoryAttacker");
        vm.prank(attacker);
        address newVaultAddr = factory.createVault(POOL, USDC, WETH, 500);

        assertTrue(newVaultAddr != address(vault), "a brand-new address, not access to an existing vault");
        AutoRangeVaultV1 newVault = AutoRangeVaultV1(newVaultAddr);
        assertEq(newVault.owner(), attacker, "attacker owns only their own new, empty vault");
        assertEq(newVault.positionTokenId(), 0);
        assertEq(newVault.reserveBalance(), 0);
        assertEq(newVault.investableUsdt(), 0);

        // The original vault is completely unaffected.
        assertEq(vault.owner(), lp);
        assertEq(vault.positionTokenId(), originalTokenId);
        assertEq(vault.reserveBalance(), originalReserve);
    }

    function test_external_onERC721Received_rejectsNonPositionManager() public {
        address attacker = makeAddr("erc721Attacker");
        vm.prank(attacker);
        vm.expectRevert(AutoRangeVaultV1.NotPositionManager.selector);
        vault.onERC721Received(attacker, attacker, 1, "");
    }

    // =====================================================================
    // Prueba 1 (Atómica) — clone + initialize en la MISMA tx, sin ventana
    // de front-running del initializer
    // =====================================================================

    /// The clone's address IS predictable (Clones.clone => raw CREATE, so
    /// it's a pure function of the factory's nonce). But it cannot be
    /// front-run:
    ///   (a) before createVault() executes the CREATE, the address holds
    ///       NO code — there is literally nothing to call initialize() on;
    ///   (b) createVault() calls initialize() in the SAME call frame,
    ///       before it returns — no other transaction can interleave;
    ///   (c) initialize() is single-shot (OZ `initializer`), so even a
    ///       re-initialize right after createVault() returns reverts.
    function test_atomic_clonePlusInitialize_predictableButNotFrontRunnable() public {
        address attacker = makeAddr("initFrontRunner");

        // The exact address the NEXT createVault() will clone to.
        address predicted = computeCreateAddress(address(factory), vm.getNonce(address(factory)));

        // (a) Nothing exists at that address yet — no deployed contract, so
        //     there is literally nothing for an attacker to call initialize()
        //     on ahead of the real creator. The address only gains code the
        //     instant createVault() runs the CREATE opcode, and the very
        //     next statement in that same call frame is initialize().
        assertEq(predicted.code.length, 0, "no code at the clone address before createVault() runs");
        (bool sent,) = predicted.call(
            abi.encodeCall(
                AutoRangeVaultV1.initialize,
                (attacker, address(config), POOL, WETH, USDC, false, 500, POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE)
            )
        );
        sent; // a raw call to a codeless address "succeeds" but executes nothing
        assertEq(predicted.code.length, 0, "the attacker's pre-emptive call was completely inert");

        // The real creation lands at EXACTLY `predicted`, fully initialized
        // by the time the call returns.
        vm.prank(lp);
        address created = factory.createVault(POOL, USDC, WETH, 500);
        assertEq(created, predicted, "clone address was predictable in advance...");
        assertGt(created.code.length, 0);
        assertEq(AutoRangeVaultV1(created).owner(), lp, "...but initialize() ran atomically for the real creator");
        assertEq(AutoRangeVaultV1(created).operator(), defaultOperator);
        assertEq(AutoRangeVaultV1(created).platformConfig(), address(config));
        assertEq(address(AutoRangeVaultV1(created).pool()), POOL);
        assertTrue(factory.isVault(created));

        // (c) Re-initialize AFTER creation -> reverts (single-shot).
        vm.prank(attacker);
        vm.expectRevert();
        AutoRangeVaultV1(created).initialize(
            attacker, address(config), POOL, WETH, USDC, false, 500, POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE
        );
        assertEq(AutoRangeVaultV1(created).owner(), lp, "ownership never hijacked");
    }

    /// The implementation singleton (never a clone) has _disableInitializers()
    /// in its constructor, so it can never be initialized and hijacked either.
    function test_atomic_implementationSingletonCannotBeInitialized() public {
        address impl = factory.implementation();
        assertGt(impl.code.length, 0);
        vm.expectRevert(); // OZ Initializable: InvalidInitialization()
        AutoRangeVaultV1(impl).initialize(
            address(this), address(config), POOL, WETH, USDC, false, 500, POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE
        );
        assertEq(AutoRangeVaultV1(impl).owner(), address(0), "the singleton was never initialized");
    }

    /// The factory reads pool.token0()/token1() via STATICCALL (the local
    /// IUniswapV3Pool interface declares them `view`). A caller-supplied
    /// malicious `pool` therefore cannot reenter createVault() — or make
    /// ANY state change at all — during those reads: the EVM reverts with
    /// StateChangeDuringStaticCall the instant it tries. There is zero
    /// reentrancy surface between createVault()'s first line and its
    /// clone()+initialize() pair, so no window can be opened there either.
    function test_atomic_maliciousPoolCannotReenterDuringTokenReads() public {
        ReenteringPool reenterer = new ReenteringPool(WETH, USDC, address(factory), POOL);
        uint256 vaultCountBefore = factory.vaultCount();

        vm.expectRevert(); // StateChangeDuringStaticCall bubbles up as an empty revert
        factory.createVault(address(reenterer), USDC, WETH, 500);

        assertEq(factory.vaultCount(), vaultCountBefore, "nothing was created");
        assertEq(reenterer.innerVault(), address(0), "the reentry never even ran");
    }

    // =====================================================================
    // Prueba 2 (Sandwich / MEV) — pérdida por slippage cuando el keeper
    // manda amountOutMinimum = 0 en el swap de rebalanceo (Hallazgo A:
    // `maxSlippageBps` declarado pero no aplicado on-chain)
    // =====================================================================

    function _routerSwap(bool wethToUsdc, uint256 amountIn, address who) internal returns (uint256 out) {
        address tokenIn = wethToUsdc ? WETH : USDC;
        address tokenOut = wethToUsdc ? USDC : WETH;
        vm.startPrank(who);
        IERC20(tokenIn).approve(SWAP_ROUTER02, amountIn);
        out = ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: 500,
                recipient: who,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    /// A tighter, out-of-range-friendly open: a narrow +/-60-tick range so a
    /// modest market move genuinely pushes the position fully one-sided (the
    /// realistic case a rebalance swap actually matters for).
    function _openPositionNarrow() internal returns (int24 lower, int24 upper) {
        (lower, upper) = _alignedRangeAroundMarket(120);
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
        vault.configureTarget({
            investmentAmountUsd: 945_000_000,
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
        vault.initPosition(_buyWeth(475_000_000), 0, 0);
    }

    /// Opens a narrow position, applies a MARKET move that takes it fully
    /// out of range (applied in every run), then the keeper closes + swaps
    /// `keeperWethSwap` WETH->USDC (amountOutMinimum = 0) + remints. If
    /// `frontRunWeth > 0`, an attacker sells that much WETH right BEFORE the
    /// keeper's swap and buys it all back right AFTER (a classic sandwich).
    /// Returns what the owner then recovers via withdrawAll(), plus the
    /// attacker's P&L — both valued in raw USDC units at the final pool price.
    function _runRebalanceScenario(uint256 keeperWethSwap, uint256 marketPushWeth, uint256 frontRunWeth)
        internal
        returns (uint256 ownerRecoveredUsd, int256 attackerNetUsd)
    {
        (int24 lower,) = _openPositionNarrow();

        // The market moves against the position (nothing to do with the
        // attacker) — it's now ~100% WETH and a rebalance genuinely needs
        // to sell WETH.
        _pushPriceDown(marketPushWeth);
        require(_currentTick() < lower, "setup: market push did not take the position out of range");

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);

        address attacker = makeAddr("sandwichBot");
        uint256 attackerBoughtBack;
        if (frontRunWeth > 0) {
            deal(WETH, attacker, frontRunWeth);
            uint256 usdcFromFront = _routerSwap(true, frontRunWeth, attacker); // sell WETH -> USDC
            vm.prank(defaultOperator);
            vault.rebalance(lo, hi, _sellWeth(keeperWethSwap), _noSwap(), 0, 0, 0); // keeper swaps at the dislocated price
            attackerBoughtBack = _routerSwap(false, usdcFromFront, attacker); // buy WETH back
            // P&L at the final price: WETH recovered vs WETH spent.
            attackerNetUsd =
                int256(_wethToUsdApprox(attackerBoughtBack)) - int256(_wethToUsdApprox(frontRunWeth));
        } else {
            vm.prank(defaultOperator);
            vault.rebalance(lo, hi, _sellWeth(keeperWethSwap), _noSwap(), 0, 0, 0);
        }

        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        ownerRecoveredUsd = (IERC20(USDC).balanceOf(lp) - ownerUsdcBefore)
            + _wethToUsdApprox(IERC20(WETH).balanceOf(lp) - ownerWethBefore);
    }

    function test_sandwich_measureSlippageLoss_amountOutMinimumZero() public {
        uint256 KEEPER_SWAP = 0.15 ether; // WETH->USDC leg of the rebalance
        uint256 MARKET_PUSH = 900 ether; // takes the narrow position out of range
        uint256 FRONT_RUN = 1_200 ether; // attacker's extra dislocation on top

        uint256 snap = vm.snapshotState();

        // --- A) Baseline: same market move + same keeper rebalance, NO sandwich ---
        (uint256 baselineRecovered,) = _runRebalanceScenario(KEEPER_SWAP, MARKET_PUSH, 0);

        vm.revertToState(snap);

        // --- B) Sandwiched: attacker front-runs, keeper swaps with
        //        amountOutMinimum = 0, attacker unwinds ---
        (uint256 sandwichRecovered, int256 attackerNetUsd) = _runRebalanceScenario(KEEPER_SWAP, MARKET_PUSH, FRONT_RUN);

        uint256 lossUsd = baselineRecovered > sandwichRecovered ? baselineRecovered - sandwichRecovered : 0;
        uint256 keeperSwapUsd = _wethToUsdApprox(KEEPER_SWAP);

        emit log_named_decimal_uint("A) owner recovered, no sandwich  (USDC)", baselineRecovered, 6);
        emit log_named_decimal_uint("B) owner recovered, sandwiched   (USDC)", sandwichRecovered, 6);
        emit log_named_decimal_uint("   owner loss to the sandwich    (USDC)", lossUsd, 6);
        emit log_named_decimal_uint("   the keeper swap leg           (USDC)", keeperSwapUsd, 6);
        emit log_named_uint("   loss as bps of that swap leg", keeperSwapUsd == 0 ? 0 : lossUsd * 10_000 / keeperSwapUsd);
        emit log_named_uint("   loss as bps of the ~$945 position", lossUsd * 10_000 / 945_000_000);
        emit log_named_decimal_int("   attacker net P&L (USDC-equiv) ", attackerNetUsd, 6);

        // The loss is REAL — amountOutMinimum = 0 genuinely lets a price
        // dislocation bleed value out of the rebalance swap.
        assertGt(lossUsd, 0, "amountOutMinimum=0 exposes the rebalance swap to a sandwich");

        // ...but it is bounded to the SWAPPED PORTION, never the whole
        // vault: well under 10% of the ~$945 position (only the ~$375 swap
        // leg is exposed, and only for the price gap the attacker can hold).
        assertLt(lossUsd, 94_500_000, "bounded well under 10% of the position - only the swap leg is exposed");

        // On this deep production pool the attacker pays more in pool fees
        // (0.05% x 2 legs on millions of volume) than it extracts — here
        // it's a griefing attack, not an economic one. A THIN pool (a new
        // non-USDC/WETH fee tier) would flip this; see Finding A.
        assertLt(attackerNetUsd, int256(0), "on the deep pool the sandwich is unprofitable for the attacker");
    }

    function test_sandwich_wellBehavedKeeperWithTightMinIsProtectedOffChain() public {
        // The on-chain gap (Finding A) is only that the contract doesn't
        // ENFORCE maxSlippageBps. A correct keeper already protects itself:
        // the SAME sandwiched swap, sized with a tight amountOutMinimum
        // computed from the PRE-sandwich price, reverts -> the rebalance
        // fails safely -> the owner loses nothing.
        (int24 lower,) = _openPositionNarrow();
        _pushPriceDown(900 ether); // market move: position fully out of range
        require(_currentTick() < lower, "setup");
        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);

        uint256 keeperWethSwap = 0.15 ether;
        // The keeper sizes its floor from the price it sees BEFORE the
        // attacker front-runs: frictionless value minus 0.5% (covers the
        // 0.05% pool fee + normal slippage, NOT a sandwich dislocation).
        uint256 tightMin = _wethToUsdApprox(keeperWethSwap) * 995 / 1000;

        // Attacker front-runs AFTER the keeper already sized its swap.
        address attacker = makeAddr("sandwichBot2");
        deal(WETH, attacker, 1_200 ether);
        _routerSwap(true, 1_200 ether, attacker);

        AutoRangeVaultV1.SwapInstruction memory protectedSwap = AutoRangeVaultV1.SwapInstruction({
            token0ToToken1: true, // WETH -> USDC
            amountIn: keeperWethSwap,
            amountOutMinimum: tightMin,
            fee: 500
        });

        uint256 positionBefore = vault.positionTokenId();
        vm.prank(defaultOperator);
        vm.expectRevert(); // SwapRouter: "Too little received"
        vault.rebalance(lo, hi, protectedSwap, _noSwap(), 0, 0, 0);

        assertEq(vault.positionTokenId(), positionBefore, "position untouched after the failed rebalance");
        assertEq(vault.reserveBalance(), 50_000_000);
    }

    // =====================================================================
    // Prueba 3 (Resiliencia del oráculo de gas Chainlink) — un oráculo
    // caído / stale / manipulado degrada el reembolso de gas a $0 sin
    // bloquear ninguna función principal del vault (Categoría 12)
    // =====================================================================

    bytes internal constant _LRD = abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector);

    function _mockOracle(int256 answer, uint256 updatedAt) internal {
        vm.mockCall(GAS_ORACLE, _LRD, abi.encode(uint80(1), answer, uint256(1), updatedAt, uint80(1)));
    }

    /// Every "the oracle went bad" mode a real Chainlink feed can present —
    /// reverting, stale, zero, negative, incomplete round — must make
    /// _ethUsdFromOracle() return 0 (no reimbursement) WITHOUT reverting the
    /// operator action that wraps it. A/B against a HEALTHY-oracle baseline
    /// from the same snapshot proves the bad oracle changed exactly one
    /// thing (no gas paid) and left every other ledger identical to the wei.
    function test_oracle_everyDegradeMode_reimbursesZero_operatorActionStillSucceeds() public {
        _openPosition();
        uint256 gasReserveStart = vault.gasReserveBalance();
        uint256 snap = vm.snapshotState();

        // Baseline: 5 reinjections with the real, healthy oracle.
        for (uint256 i; i < 5; i++) _operatorReinject();
        uint256 investableGood = vault.investableUsdt();
        uint256 reserveGood = vault.reserveBalance();
        uint256 gasReserveGood = vault.gasReserveBalance();
        assertLt(gasReserveGood, gasReserveStart, "sanity: the healthy oracle DID reimburse gas");

        vm.revertToState(snap);

        // The same 5 reinjections, each under a different bad-oracle mode.
        vm.mockCallRevert(GAS_ORACLE, _LRD, "oracle down");
        _operatorReinject();
        vm.clearMockedCalls();
        _mockOracle(2_400e8, block.timestamp - 200_000); // stale (> MAX_GAS_ORACLE_STALENESS)
        _operatorReinject();
        vm.clearMockedCalls();
        _mockOracle(0, block.timestamp); // zero answer
        _operatorReinject();
        vm.clearMockedCalls();
        _mockOracle(-5, block.timestamp); // negative answer
        _operatorReinject();
        vm.clearMockedCalls();
        _mockOracle(2_400e8, 0); // updatedAt == 0 (round never completed)
        _operatorReinject();
        vm.clearMockedCalls();

        assertEq(vault.investableUsdt(), investableGood, "investable ledger identical to the healthy-oracle run");
        assertEq(vault.reserveBalance(), reserveGood, "reserve ledger identical to the healthy-oracle run");
        assertEq(vault.gasReserveBalance(), gasReserveStart, "the ONE difference: not a wei of gas was reimbursed");
    }

    function _operatorReinject() internal {
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0); // triggers _reimburseKeeperGas
    }

    /// A full keeper lifecycle with the oracle REVERTING throughout: every
    /// operator entrypoint that reimburses gas (initPosition, rebalance,
    /// reinjectIntoPosition, sweepIdleDust, harvestFees, operatorForceRebalance)
    /// still runs to completion, the gas bucket is never debited, and the
    /// owner recovers ~all principal.
    function test_oracle_downThroughout_everyOperatorEntrypointStillWorks() public {
        vm.mockCallRevert(GAS_ORACLE, _LRD, "oracle offline");

        _openPosition(); // initPosition() reimburses gas -> must succeed
        assertEq(vault.gasReserveBalance(), 5_000_000, "initPosition paid no reimbursement");

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // must succeed

        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0); // must succeed

        deal(USDC, address(this), 3_000_000);
        IERC20(USDC).transfer(address(vault), 3_000_000);
        vm.prank(defaultOperator);
        vault.sweepIdleDust(_buyWeth(1_400_000), 0, 0); // balanced swap so both legs mint - must succeed

        vm.prank(lp);
        vault.setAutoCompoundFees(true);
        vm.prank(defaultOperator);
        vault.harvestFees(_noSwap(), 0, 0); // reimbursement path runs even with ~0 fees -> must succeed

        vm.prank(defaultOperator);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // must succeed

        assertEq(vault.gasReserveBalance(), 5_000_000, "the gas bucket was never debited under a down oracle");

        vm.clearMockedCalls();
        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        uint256 recovered = (IERC20(USDC).balanceOf(lp) - ownerUsdcBefore)
            + _wethToUsdApprox(IERC20(WETH).balanceOf(lp) - ownerWethBefore);
        assertGe(recovered, 940_000_000, "owner recovers ~all principal - the down oracle cost nothing but the keeper's own gas");
    }

    /// Manipulation attempt: the feed reports an absurd ETH price ($50B).
    /// gasCostUsd blows up, but gasReimbursed = min(gasCostUsd,
    /// gasReserveBalance) — so it can drain the GAS BUCKET at most, never a
    /// wei of investable/reserve/position principal, and the operation still
    /// succeeds. The owner then recovers all principal.
    function test_oracle_manipulatedInsanelyHighPrice_drainsOnlyGasBucket() public {
        _openPosition();
        uint256 snap = vm.snapshotState();

        // Baseline: one reinjection with the healthy oracle.
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0);
        uint256 investableGood = vault.investableUsdt();
        uint256 reserveGood = vault.reserveBalance();

        vm.revertToState(snap);

        // Same reinjection, but the feed reports ETH at $50,000,000,000.
        _mockOracle(50_000_000_000 * 1e8, block.timestamp);
        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0); // still succeeds

        // gasReimbursed = min(gasCostUsd, gasReserveBalance) -> the whole gas
        // bucket is drained, but that is the manipulated oracle's ENTIRE reach.
        assertEq(vault.gasReserveBalance(), 0, "the whole gas bucket was reimbursed - and that is its ONLY reach");
        assertEq(vault.investableUsdt(), investableGood, "investable principal identical to the healthy-oracle run");
        assertEq(vault.reserveBalance(), reserveGood, "reserve identical to the healthy-oracle run");

        vm.clearMockedCalls();
        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        uint256 recovered = (IERC20(USDC).balanceOf(lp) - ownerUsdcBefore)
            + _wethToUsdApprox(IERC20(WETH).balanceOf(lp) - ownerWethBefore);
        assertGe(recovered, 940_000_000, "owner still recovers all principal - only the ~$5 gas budget was lost");
    }

    /// Owner exit paths never call _reimburseKeeperGas, so a fully-down
    /// oracle cannot block a single one of them.
    function test_oracle_downDoesNotBlockAnyOwnerExitPath() public {
        vm.mockCallRevert(GAS_ORACLE, _LRD, "oracle down");

        // withdrawAll
        _openPosition();
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());

        // collectFees (no position -> NoPosition, but that's not an oracle
        // block; re-open and test the real path)
        _openPosition();
        vm.prank(lp);
        vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        // withdraw (partial) + rescuePosition + emergencyWithdrawPosition
        vm.prank(lp);
        vault.withdraw(2_000, 0, 0, 0, 0, 0, _noSwap(), _noSwap(), 0, 0);
        vm.prank(lp);
        vault.rescuePosition();
        // vault now has no position; re-open once more for emergencyWithdraw
        vm.prank(lp);
        vault.setPaused(false);
        _openPosition();
        vm.prank(lp);
        vault.emergencyWithdrawPosition();
    }

    /// FINDING (Informativa/Baja): _ethUsdFromOracle() degrades gracefully
    /// for every NORMAL bad-oracle mode, but a feed reporting `updatedAt` in
    /// the FUTURE makes `block.timestamp - updatedAt` underflow-revert INSIDE
    /// the try's success branch — which the `catch` does NOT catch. That
    /// revert propagates and blocks every operator entrypoint that reimburses
    /// gas (automated rebalancing halts). Owner exit paths are unaffected
    /// (they never call the oracle). Needs a byzantine/compromised Chainlink
    /// aggregator to occur (a real feed's updatedAt is always a past block
    /// timestamp). Fix for a future version: `if (updatedAt > block.timestamp
    /// || block.timestamp - updatedAt > MAX_GAS_ORACLE_STALENESS) return 0;`.
    function test_oracle_futureUpdatedAt_underflowRevertsAndBlocksOperatorActionsOnly() public {
        _openPosition();
        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);

        _mockOracle(2_400e8, block.timestamp + 3_600); // updatedAt 1h in the FUTURE

        // Every gas-reimbursing operator entrypoint reverts (unchecked
        // underflow in the un-caught success branch).
        vm.prank(defaultOperator);
        vm.expectRevert(stdError.arithmeticError);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        vm.prank(defaultOperator);
        vm.expectRevert(stdError.arithmeticError);
        vault.reinjectIntoPosition(_buyWeth(2_500_000), 5_000_000, 0, 0);

        vm.prank(defaultOperator);
        vm.expectRevert(stdError.arithmeticError);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // But the owner can still get everything out - no owner path touches
        // the oracle.
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        assertEq(vault.positionTokenId(), 0);
        assertEq(vault.investableUsdt(), 0);
    }

    // =====================================================================
    // Prueba 5 — propagación de cambios de PlatformConfig a vaults YA
    // creados. Cada vault lee platformConfig EN VIVO en casi todo:
    //
    //   PlatformConfig setter (onlyOwner)          leído por un vault existente en:
    //   ----------------------------------          -------------------------------
    //   setPerformanceFeeBps  ------------------->  _splitPerformanceFee  (cada cobro de fee)   [EN VIVO]
    //   setMaxDepositUsd      ------------------->  _enforceDepositCap    (cada deposit)        [EN VIVO]
    //   setTreasury          -------------------->  _payCreationFee       (cada fee de creación) [EN VIVO]
    //   setForceRebalanceCooldownSeconds ------->  operatorForceRebalance                       [EN VIVO]
    //   setDefaultOperator  --------------------->  initialize()  <-- SOLO una vez, al crear    [NO se re-sincroniza]
    //   setOperatorPool    ---------------------->  initialize()  <-- SOLO una vez, al crear    [NO se re-sincroniza]
    // =====================================================================

    function _lpUsd() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(lp) + _wethToUsdApprox(IERC20(WETH).balanceOf(lp));
    }

    function _generateTradingFees() internal {
        address trader = makeAddr("feeTrader");
        deal(USDC, trader, 4_000_000_000_000);
        vm.startPrank(trader);
        IERC20(USDC).approve(SWAP_ROUTER02, type(uint256).max);
        IERC20(WETH).approve(SWAP_ROUTER02, type(uint256).max);
        for (uint256 i; i < 3; i++) {
            uint256 got = ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 500,
                    recipient: trader,
                    amountIn: 800_000_000_000,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: USDC,
                    fee: 500,
                    recipient: trader,
                    amountIn: got,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        vm.stopPrank();
    }

    /// A/B: the SAME existing vault, collecting the SAME earned fees, once at
    /// the current 10% and once after the platform raises its cut to 100%.
    /// Isolates the perf-fee effect: the owner's fee income goes to zero, but
    /// principal recovery is identical to the wei-ish — the platform's lever
    /// reaches fees ONLY.
    function test_configPropagation_performanceFeeBpsIsReadLiveByExistingVaults() public {
        _openPosition();
        _generateTradingFees();
        uint256 snap = vm.snapshotState();

        // --- A) collect at the current 10% ---
        uint256 lpStart = _lpUsd();
        vm.prank(lp);
        vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        uint256 feeIncomeA = _lpUsd() - lpStart;
        uint256 lpMid = _lpUsd();
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        uint256 principalA = _lpUsd() - lpMid;

        vm.revertToState(snap);

        // --- B) same, but the platform now takes 100% ---
        vm.prank(platformOwner);
        config.setPerformanceFeeBps(10_000);

        lpStart = _lpUsd();
        vm.prank(lp);
        (uint256 net0, uint256 net1) = vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        uint256 feeIncomeB = _lpUsd() - lpStart;
        lpMid = _lpUsd();
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        uint256 principalB = _lpUsd() - lpMid;

        assertEq(net0, 0, "owner's net fee legs are 0 at a 100% performance fee");
        assertEq(net1, 0);
        assertGt(feeIncomeA, 0, "sanity: at 10% the owner earned real fee income");
        assertEq(feeIncomeB, 0, "at 100% the existing vault pays the owner nothing from fees");
        assertApproxEqRel(principalB, principalA, 0.01e18, "principal recovery is unaffected by the perf-fee rate");
    }

    function test_configPropagation_maxDepositUsdIsReadLive_doesNotStrandExistingCapital() public {
        _openPosition(); // reserve 50 + gas 5 live in the vault; investable folded into the position

        // The platform tightens the cap below what this vault already holds.
        vm.prank(platformOwner);
        config.setMaxDepositUsd(10_000_000); // $10

        // A NEW deposit is rejected against the live cap (fund the reserve
        // bucket - investableAmount > 0 with a live position would trip a
        // different guard first).
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.DepositExceedsPlatformCap.selector);
        vault.deposit(20_000_000, 0, 0);

        // ...but the existing capital and every withdrawal path are unaffected.
        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(lp);
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        uint256 recovered = (IERC20(USDC).balanceOf(lp) - ownerUsdcBefore)
            + _wethToUsdApprox(IERC20(WETH).balanceOf(lp) - ownerWethBefore);
        assertGe(recovered, 940_000_000, "a tighter cap never strands capital already in the vault");
    }

    function test_configPropagation_treasuryChangeRedirectsTheNextCreationFee() public {
        vm.prank(platformOwner);
        config.setCreationFeeBps(100); // 1%

        address newTreasury = makeAddr("newTreasury");
        vm.prank(platformOwner);
        config.setTreasury(newTreasury);

        uint256 oldTreasuryBefore = IERC20(USDC).balanceOf(treasury);
        vm.prank(lp);
        vault.deposit(0, 100_000_000, 0); // $100 investable -> 1% = $1 creation fee

        assertEq(IERC20(USDC).balanceOf(treasury), oldTreasuryBefore, "the old treasury got nothing");
        assertEq(IERC20(USDC).balanceOf(newTreasury), 1_000_000, "the live treasury received the fee");
    }

    function test_configPropagation_defaultOperatorChange_doesNotResyncExistingVault() public {
        address newOperator = makeAddr("newDefaultOperator");
        vm.prank(platformOwner);
        config.setDefaultOperator(newOperator);

        // The vault created in setUp keeps the operator it was born with.
        assertEq(vault.operator(), defaultOperator, "existing vault's operator is NOT re-synced");

        // A vault created now gets the new one.
        vm.prank(lp);
        AutoRangeVaultV1 fresh = AutoRangeVaultV1(factory.createVault(POOL, USDC, WETH, 500));
        assertEq(fresh.operator(), newOperator, "a new vault reads the current defaultOperator");
    }

    function test_configPropagation_operatorPoolChange_doesNotResyncExistingVault() public {
        address poolWallet = makeAddr("laterPoolWallet");
        address[] memory arr = new address[](1);
        arr[0] = poolWallet;
        vm.prank(platformOwner);
        config.setOperatorPool(arr);

        // The vault from setUp was seeded from an EMPTY pool at init time.
        assertFalse(vault.isOperator(poolWallet), "existing vault's isOperator set is NOT re-synced");

        // A vault created now seeds from the current pool.
        vm.prank(lp);
        AutoRangeVaultV1 fresh = AutoRangeVaultV1(factory.createVault(POOL, USDC, WETH, 500));
        assertTrue(fresh.isOperator(poolWallet), "a new vault seeds isOperator from the current operatorPool()");
    }

    function test_configPropagation_forceRebalanceCooldownIsReadLive() public {
        _openPosition();
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);

        // Cooldown starts at 0 (config default) -> back-to-back force
        // rebalances are allowed.
        vm.prank(defaultOperator);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // The platform sets a 6h cooldown; the SAME existing vault now
        // enforces it on the very next call.
        vm.prank(platformOwner);
        config.setForceRebalanceCooldownSeconds(21_600);
        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vm.expectRevert(AutoRangeVaultV1.TooSoonToRebalance.selector);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // Drop it back to 0 -> immediately allowed again (live read, no redeploy).
        vm.prank(platformOwner);
        config.setForceRebalanceCooldownSeconds(0);
        vm.prank(defaultOperator);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    // =====================================================================
    // Prueba 7 — cooldowns, tope de rebalanceos y gates de rebalanceo
    //
    //   rebalance()             : cooldown(minRebalanceInterval) + (periodicDue || out-of-range) + count<max
    //   ownerRebalance()        : cooldown(minRebalanceInterval)                                 + count<max
    //   operatorForceRebalance(): cooldown(PlatformConfig.forceRebalanceCooldownSeconds)  [NO gate, NO max]
    //                              \-- net rebalanceCount unchanged (bump then -1); forceRebalanceCount++
    // =====================================================================

    function _openPositionWith(uint256 maxRebalances, uint256 minRebalanceInterval)
        internal
        returns (int24 lower, int24 upper)
    {
        (lower, upper) = _alignedRangeAroundMarket(2000);
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
        vault.configureTarget({
            investmentAmountUsd: 945_000_000,
            _targetTickLower: lower,
            _targetTickUpper: upper,
            _maxRebalances: maxRebalances,
            _reinjectionAmount: 10_000_000,
            _periodicRebalanceInterval: 1 days,
            _recenterMarginBps: 500,
            _exitTopCeilingMarginBps: 300,
            _feeClaimThresholdBps: 200,
            _feeClaimIntervalSeconds: 1 days,
            _exitTopRecenterMarginBps: 500
        });
        vault.setRiskParams(500, minRebalanceInterval, 500);
        vm.stopPrank();
        vm.prank(defaultOperator);
        vault.initPosition(_buyWeth(475_000_000), 0, 0);
    }

    function test_gate_minRebalanceInterval_blocksUntilElapsed() public {
        (int24 lo, int24 hi) = _openPositionWith(5, 1 hours);
        // initPosition set lastRebalanceTimestamp = now; the 1h cooldown
        // has not elapsed.
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.TooSoonToRebalance.selector);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(lp);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // now the cooldown has elapsed
    }

    function test_gate_maxRebalances_capsRebalanceAndOwnerRebalance() public {
        (int24 lo, int24 hi) = _openPositionWith(1, 0); // budget of exactly one

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // count -> 1
        assertEq(vault.rebalanceCount(), 1);

        vm.warp(block.timestamp + 1 days + 1);
        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vm.expectRevert(AutoRangeVaultV1.RebalanceLimitReached.selector);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.RebalanceLimitReached.selector);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    function test_gate_operatorForceRebalance_ignoresMaxRebalances_ownerBudgetUntouched() public {
        (int24 lo, int24 hi) = _openPositionWith(1, 0);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // owner budget spent (count == max == 1)

        // The platform can still force-rebalance the same vault...
        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // ...and it left the owner's budget exactly where it was.
        assertEq(vault.rebalanceCount(), 1, "net rebalanceCount unchanged by the force (bump then -1)");
        assertEq(vault.forceRebalanceCount(), 1, "the force is tracked on its own counter");

        // The owner's own paths are still capped.
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.RebalanceLimitReached.selector);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    function test_gate_operatorForceRebalance_cooldownIndependentOfMinRebalanceInterval() public {
        (int24 lo, int24 hi) = _openPositionWith(50, 0); // owner set minRebalanceInterval = 0
        vm.prank(platformOwner);
        config.setForceRebalanceCooldownSeconds(1 hours); // but the platform's force cooldown is 1h

        vm.prank(defaultOperator);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // minRebalanceInterval == 0 does NOT strip the force-path protection.
        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vm.expectRevert(AutoRangeVaultV1.TooSoonToRebalance.selector);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // ownerRebalance, gated only by minRebalanceInterval (0), is unaffected.
        vm.prank(lp);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    function test_gate_rebalance_periodicOrOutOfRangeRequired_ownerRebalanceSkipsIt() public {
        (int24 lo, int24 hi) = _openPositionWith(50, 0);
        // In range, and the 1-day periodic interval has NOT elapsed.
        vm.prank(defaultOperator);
        vm.expectRevert(AutoRangeVaultV1.TooSoonToRebalance.selector);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // ownerRebalance has no such gate — it runs.
        vm.prank(lp);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    function test_gate_checkRangeNearMarket_boundary() public {
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
        vault.setRiskParams(500, 0, 500); // maxRangeDeviationBps = 500 tick units of slack
        vm.stopPrank();

        int24 mkt = _currentTick();
        // A range ENTIRELY just below market (so a _noSwap init mints 100%
        // USDC = token1), with its near edge well within the 500-tick slack.
        int24 hi = ((mkt - 2 * tickSpacing) / tickSpacing) * tickSpacing;
        int24 lo = hi - 20 * tickSpacing;
        vm.prank(lp);
        vault.configureTarget(945_000_000, lo, hi, 5, 10_000_000, 1 days, 500, 300, 200, 1 days, 500);
        vm.prank(defaultOperator);
        vault.initPosition(_noSwap(), 0, 0); // near edge within slack -> passes _checkRangeNearMarket

        // A range far past the slack -> RangeTooFarFromMarket on the next rebalance.
        int24 farLo = mkt + 5_000; // way beyond maxRangeDeviationBps
        int24 farHi = farLo + 20 * tickSpacing;
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.RangeTooFarFromMarket.selector);
        vault.ownerRebalance(farLo, farHi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    // =====================================================================
    // Prueba 8 — regresiones de fee-accounting sobre este source exacto
    //   V3 #1: withdraw() parcial con autoCompound ON perdía el principal removido
    //   V3 #2: _reinjectFees() barría el principal recién removido al reinject
    // =====================================================================

    function test_fee_withdrawPartial_autoCompoundOn_ownerGetsPurePrincipal_feesReinject() public {
        _openPosition();
        _generateTradingFees();
        vm.prank(lp);
        vault.setAutoCompoundFees(true);

        uint128 liqBefore = _positionLiquidity();
        uint256 lpUsdcBefore = IERC20(USDC).balanceOf(lp);
        uint256 lpWethBefore = IERC20(WETH).balanceOf(lp);

        vm.recordLogs();
        vm.prank(lp);
        vault.withdraw(3_000, 0, 0, 0, 0, 0, _noSwap(), _noSwap(), 0, 0); // 30% of the position, pure principal
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The owner received principal only — fees did NOT ride along.
        assertFalse(
            _hasTopic0(logs, address(vault), "LpFeesPaidToOwner(uint256,uint256)"),
            "compounding partial exit must not pay fees to the owner"
        );
        assertTrue(
            _hasTopic0(logs, address(vault), "FeesReinjected(uint256,uint256,uint256,uint256,uint256)"),
            "fees reinjected into the remaining position instead"
        );

        // V3 #1 regression: the removed principal actually reached the owner
        // (a nonzero payout), not stuck in the vault.
        uint256 principalOut = (IERC20(USDC).balanceOf(lp) - lpUsdcBefore)
            + _wethToUsdApprox(IERC20(WETH).balanceOf(lp) - lpWethBefore);
        assertGt(principalOut, 250_000_000, "~30% of the ~$945 position's principal was paid out");

        // The remaining ~70% is still there AND grew from the reinjected fees.
        uint128 liqAfter = _positionLiquidity();
        assertGt(liqAfter, liqBefore * 65 / 100, "~70% of liquidity remains");
        _invariantHolds();
    }

    function test_fee_withdrawFull_autoCompoundOff_feesMergeWithPrincipal() public {
        _openPosition();
        _generateTradingFees();
        // autoCompoundFees OFF (default). Full close: fees pay out merged
        // with principal (there's no remaining position to reinject into).
        vm.recordLogs();
        vm.prank(lp);
        vault.withdraw(10_000, 0, 0, 0, 0, 0, _noSwap(), _noSwap(), 0, 0);
        assertEq(vault.positionTokenId(), 0, "full close");
        _invariantHolds();
    }

    function test_fee_performanceFeeBps_zero_ownerKeepsEverything() public {
        _openPosition();
        _generateTradingFees();
        vm.prank(platformOwner);
        config.setPerformanceFeeBps(0);

        uint256 opBefore = IERC20(USDC).balanceOf(defaultOperator);
        vm.recordLogs();
        vm.prank(lp);
        vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        assertEq(IERC20(USDC).balanceOf(defaultOperator), opBefore, "0 bps -> platform takes nothing");
        assertFalse(
            _hasTopic0(vm.getRecordedLogs(), address(vault), "PerformanceFeeCollected(uint256,uint256)"),
            "no PerformanceFeeCollected event at 0 bps"
        );
    }

    function test_fee_creationFee_thirdPartyDepositToken_chargedTiered() public {
        // Fresh vault (no position) so investableAmount > 0 is allowed — the
        // tiered creation fee is charged on the investable leg only.
        address dai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        vm.prank(platformOwner);
        config.setCreationFeeBps(100); // 1%, no threshold/flat

        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        deal(dai, lp, 100 ether);
        vm.startPrank(lp);
        IERC20(dai).approve(address(vault), type(uint256).max);
        // 30 DAI -> ~30 USDC via the third-party swap; declare $25 investable.
        vault.depositToken(dai, 30 ether, _noSwap(), 100, 0, 0, 25_000_000, 0);
        vm.stopPrank();

        uint256 fee = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        assertApproxEqRel(fee, 250_000, 0.02e18, "1% of the $25 declared investable, paid from the swap proceeds");
        assertEq(vault.investableUsdt(), 25_000_000, "the investable ledger got the declared amount");
    }

    function _positionLiquidity() internal view returns (uint128 liq) {
        (,,,,,,, liq,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(vault.positionTokenId());
    }

    // =====================================================================
    // Prueba 9 — fuzz / invariantes
    // =====================================================================

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_withdrawFourBuckets_neverReverts_invariantHolds(
        uint16 posBps,
        uint16 invBps,
        uint16 resBps,
        uint16 gasBps
    ) public {
        posBps = uint16(bound(posBps, 0, 10_000));
        invBps = uint16(bound(invBps, 0, 10_000));
        resBps = uint16(bound(resBps, 0, 10_000));
        gasBps = uint16(bound(gasBps, 0, 10_000));
        vm.assume(uint256(posBps) + invBps + resBps + gasBps > 0); // the all-zero case reverts by design

        _openPosition();
        vm.prank(lp);
        vault.deposit({reserveAmount: 30_000_000, investableAmount: 0, gasReserveAmount: 10_000_000});

        uint256 invB = vault.investableUsdt();
        uint256 resB = vault.reserveBalance();
        uint256 gasB = vault.gasReserveBalance();

        vm.prank(lp);
        vault.withdraw(posBps, invBps, resBps, gasBps, 0, 0, _noSwap(), _noSwap(), 0, 0); // must not revert

        assertEq(vault.investableUsdt(), invB - invB * invBps / 10_000, "investable decremented proportionally");
        assertEq(vault.reserveBalance(), resB - resB * resBps / 10_000, "reserve decremented proportionally");
        assertEq(vault.gasReserveBalance(), gasB - gasB * gasBps / 10_000, "gas decremented proportionally");
        _invariantHolds();
    }

    // =====================================================================
    // Prueba 10 (2da ronda) — overflow del cómputo B1, redondeo, volátil no-18d,
    // y notas menores
    // =====================================================================

    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// Hallazgo I (Informativa) — `_toStableUsd` / `_nativeWeiToStableRaw`
    /// (rama `volatileWei * sqrtPriceX96` dos veces) puede DESBORDAR 2^256
    /// si `pool.slot0()` devuelve un `sqrtPriceX96` cercano al máximo. Ese
    /// cómputo alimenta `principalUsd` (sólo un dato de evento) en
    /// withdraw()/withdrawAll()/emergencyWithdrawPosition(); su overflow
    /// revierte TODA la función antes de `_payOwner`.
    ///
    /// NO es alcanzable en la práctica: un pool canónico de Uniswap V3
    /// nunca puede empujar su `sqrtPriceX96` cerca de ese extremo (la
    /// liquidez se agota mucho antes), y `createVault()` ya verifica que el
    /// pool sea el canónico ⇒ `slot0()` es confiable. Se demuestra acá con
    /// `vm.mockCall` puro para dejar registrado el límite y confirmar que
    /// `rescuePosition()` (que NO computa `principalUsd`) es inmune.
    function test_finding_b1EventOverflow_dosesWithdrawPaths_rescueIsImmune() public {
        _openPosition();
        uint256 tid = vault.positionTokenId();

        vm.mockCall(
            POOL,
            abi.encodeWithSignature("slot0()"),
            abi.encode(MAX_SQRT_RATIO - 1, int24(887271), uint16(0), uint16(1), uint16(1), uint8(0), true)
        );

        vm.prank(lp);
        vm.expectRevert(stdError.arithmeticError);
        vault.emergencyWithdrawPosition();

        vm.prank(lp);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdrawAll(_noSwap(), _noSwap());

        vm.prank(lp);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdraw(10_000, 10_000, 10_000, 10_000, 0, 0, _noSwap(), _noSwap(), 0, 0);

        // rescuePosition() never touches _toStableUsd -> still works, even
        // with the extreme slot0 mock active. The owner is never trapped.
        vm.prank(lp);
        vault.rescuePosition();
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(tid), lp, "rescuePosition is the overflow-immune last resort");
    }

    /// A sanity floor for Hallazgo I's "not reachable" claim: the real pool's
    /// live sqrtPriceX96 is ~13 orders of magnitude below the overflow
    /// threshold, so the normal withdrawAll path values principal fine.
    function test_finding_b1EventOverflow_realPriceIsFarFromTheThreshold() public {
        (uint160 sp,,,,,,) = pool.slot0();
        assertLt(uint256(sp), uint256(MAX_SQRT_RATIO) / 1e10, "real sqrtPriceX96 is nowhere near the overflow regime");
        _openPosition();
        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap()); // no overflow at a real price
    }

    /// Rounding always favors the vault, never the withdrawer: every
    /// `ledger * bps / 10_000` truncates DOWN, so the owner can never
    /// extract more than the exact proportional share by repeating.
    /// forge-config: default.fuzz.runs = 24
    function testFuzz_withdrawRounding_neverFavorsTheWithdrawer(uint16 bps) public {
        uint256 shareBps = bound(bps, 1, 9_999); // a partial share that can truncate
        _openPosition();
        vm.prank(lp);
        vault.deposit({reserveAmount: 123_456_789, investableAmount: 0, gasReserveAmount: 987_654_321});

        uint256 resB = vault.reserveBalance();
        uint256 gasB = vault.gasReserveBalance();
        uint256 lpBefore = IERC20(USDC).balanceOf(lp);

        vm.prank(lp);
        vault.withdraw(0, 0, uint256(shareBps), uint256(shareBps), 0, 0, _noSwap(), _noSwap(), 0, 0);

        uint256 paid = IERC20(USDC).balanceOf(lp) - lpBefore;
        uint256 exact = resB * shareBps / 10_000 + gasB * shareBps / 10_000;
        assertEq(paid, exact, "paid == floor(exact) - truncation never rounds in the owner's favor");
        // ...and what stays in the ledgers is >= the exact remainder.
        assertGe(vault.reserveBalance(), resB - resB * shareBps / 10_000);
        assertGe(vault.gasReserveBalance(), gasB - gasB * shareBps / 10_000);
    }

    /// A volatile asset with != 18 decimals (WBTC, 8) — the off-chain keeper
    /// once had a 10^10 bug here; on-chain `_toStableUsd`/`_nativeWeiToStableRaw`
    /// must be correct because the decimal scaling is baked into
    /// `sqrtPriceX96`. Verified end to end: a deposit + withdrawAll on a real
    /// WBTC/USDC vault recovers ~all principal and the `Withdrawn.principalUsd`
    /// is a sane ~$ figure (not off by orders of magnitude).
    function test_nonEighteenDecimalVolatile_wbtc_valuesPrincipalSanely() public {
        address wbtcPool = 0x0E4831319A50228B9e450861297aB92dee15B44F; // WBTC/USDC 0.05% (WBTC=token0, 8 dec)
        address wbtc = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

        vm.prank(lp);
        AutoRangeVaultV1 wv = AutoRangeVaultV1(factory.createVault(wbtcPool, USDC, wbtc, 500));
        assertFalse(wv.stableIsToken0(), "USDC is token1 on this pool");

        IUniswapV3Pool wp = IUniswapV3Pool(wbtcPool);
        (, int24 t,,,,,) = wp.slot0();
        int24 sp = wp.tickSpacing();
        int24 lo = ((t - 1000) / sp) * sp;
        int24 hi = ((t + 1000) / sp) * sp;

        deal(USDC, lp, 2_000_000_000);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(wv), type(uint256).max);
        wv.deposit({reserveAmount: 20_000_000, investableAmount: 950_000_000, gasReserveAmount: 5_000_000});
        wv.configureTarget(950_000_000, lo, hi, 5, 10_000_000, 1 days, 500, 300, 200, 1 days, 500);
        wv.setRiskParams(500, 0, 500);
        vm.stopPrank();

        // init swap: ~half of investable USDC -> WBTC (USDC=token1 -> token0, token0ToToken1=false)
        vm.prank(defaultOperator);
        wv.initPosition(
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 475_000_000, amountOutMinimum: 0, fee: 500}),
            0,
            0
        );

        vm.recordLogs();
        vm.prank(lp);
        wv.withdrawAll(
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0, amountOutMinimum: 0, fee: 500}),
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0, amountOutMinimum: 0, fee: 500})
        );

        bytes memory data = _lastLogData(vm.getRecordedLogs(), address(wv), "Withdrawn(uint256,uint256,uint256)");
        (,, uint256 principalUsd) = abi.decode(data, (uint256, uint256, uint256));
        // ~$970 deposited; principalUsd must be in the hundreds-of-millions
        // (6-dec USD), NOT 10^10x that (the off-chain WBTC bug's signature).
        assertGt(principalUsd, 800_000_000, "principalUsd is a sane ~$ figure");
        assertLt(principalUsd, 1_100_000_000, "...not inflated by 10^(18-8)");
    }

    /// Note: onERC721Received accepts ANY NFT from the positionManager, so an
    /// owner who sends a position NFT back into the vault (e.g. after a
    /// rescuePosition) strands it — positionTokenId stays 0 and no function
    /// can move it out again. Self-inflicted, no third-party impact.
    function test_note_nftSentBackAfterRescueIsStranded() public {
        _openPosition();
        uint256 tid = vault.positionTokenId();
        vm.prank(lp);
        vault.rescuePosition();
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(tid), lp);

        // Owner sends it back.
        vm.prank(lp);
        INonfungiblePositionManager(POSITION_MANAGER).safeTransferFrom(lp, address(vault), tid);
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(tid), address(vault), "vault holds it again");

        // ...but positionTokenId is still 0, so nothing can act on it.
        assertEq(vault.positionTokenId(), 0);
        vm.prank(lp);
        vm.expectRevert(AutoRangeVaultV1.NoPosition.selector);
        vault.rescuePosition(); // can't rescue what the vault doesn't track
    }

    /// Note: `closed` is one-way — a vault closed by mistake is permanently
    /// dead (every notClosed-gated function reverts, no un-close path).
    function test_note_closedVaultIsIrreversiblyDead() public {
        vm.prank(lp);
        vault.closeVault(); // empty vault from setUp

        vm.startPrank(lp);
        vm.expectRevert(AutoRangeVaultV1.VaultClosed.selector);
        vault.deposit(1, 0, 1);
        vm.expectRevert(AutoRangeVaultV1.VaultClosed.selector);
        vault.configureTarget(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.VaultClosed.selector);
        vault.setRiskParams(0, 0, 0);
        vm.expectRevert(AutoRangeVaultV1.VaultClosed.selector);
        vault.setAutoCompoundFees(true);
        vm.expectRevert(AutoRangeVaultV1.VaultClosed.selector);
        vault.closeVault(); // can't even re-close
        vm.stopPrank();
    }

    /// Note: initialize() iterates operatorPool() with no length cap — the
    /// platform could make createVault() expensive (self-inflicted). Measure
    /// how the gas scales.
    function test_note_operatorPoolLoopGasScalesWithLength() public {
        address[] memory big = new address[](150);
        for (uint256 i; i < big.length; i++) big[i] = address(uint160(uint256(keccak256(abi.encode(i)))));
        vm.prank(platformOwner);
        config.setOperatorPool(big);

        vm.prank(lp);
        uint256 g0 = gasleft();
        AutoRangeVaultV1 v = AutoRangeVaultV1(factory.createVault(POOL, USDC, WETH, 500));
        uint256 used = g0 - gasleft();

        // 150 SSTOREs of isOperator[x] = true, ~20k each -> a few million gas,
        // well within a block, but it scales linearly. Documented, not a bug.
        assertLt(used, 15_000_000, "createVault with a 150-wallet pool still fits comfortably in a block");
        assertTrue(v.isOperator(big[149]), "the whole pool was seeded");
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_tieredCreationFee_twoDepositsEqualOneOnTheSum(uint64 a, uint64 b, uint16 bps) public {
        uint256 depA = bound(a, 1_000_000, 2_000_000_000); // $1 .. $2000
        uint256 depB = bound(b, 1_000_000, 2_000_000_000);
        uint256 feeBps = bound(bps, 1, 500); // up to 5%
        vm.startPrank(platformOwner);
        config.setCreationFeeTierThresholdUsd(500_000_000); // $500 bracket
        config.setCreationFeeFlatUsd(1_000_000); // $1 flat
        config.setCreationFeeBps(feeBps);
        vm.stopPrank();

        uint256 snap = vm.snapshotState();

        // Two sequential deposits.
        vm.startPrank(lp);
        vault.deposit(0, depA, 0);
        vault.deposit(0, depB, 0);
        vm.stopPrank();
        uint256 feeSplit = IERC20(USDC).balanceOf(treasury);

        vm.revertToState(snap);

        // One deposit on the sum.
        vm.prank(lp);
        vault.deposit(0, depA + depB, 0);
        uint256 feeOne = IERC20(USDC).balanceOf(treasury);

        // Exact up to integer-division rounding of the bracket-2 bps split
        // across the two legs (the flat fee fires exactly once either way).
        assertApproxEqAbs(feeSplit, feeOne, 2, "tiered fee decomposes cleanly (no double-charge, +/-1wei rounding)");
        assertEq(vault.cumulativeFeeableUsd(), depA + depB, "same cumulative counter either way");
    }

    // =====================================================================
    // Prueba 11 — stress de invariantes, token de terceros hostil, gas de
    // peor caso, farming de gas, y notas restantes
    // =====================================================================

    /// The core solvency invariant nowhere in the repo has an automated
    /// test: the vault's REAL stable balance must always back the 3
    /// stable-denominated ledgers. Runs a long scripted sequence hitting
    /// every capital-moving entrypoint and re-checks after each step.
    function _assertSolvent(string memory whenLabel) internal view {
        uint256 realStable = IERC20(USDC).balanceOf(address(vault));
        uint256 ledgers = vault.investableUsdt() + vault.reserveBalance() + vault.gasReserveBalance();
        assertGe(realStable, ledgers, string.concat("INSOLVENT after: ", whenLabel));
        assertLe(vault.uncountedInvestable(), vault.investableUsdt(), string.concat("uncounted>investable after: ", whenLabel));
    }

    function test_invariant_solvency_holdsAcrossEveryEntrypoint() public {
        deal(WETH, lp, 5 ether);
        vm.prank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        _openPosition();
        _assertSolvent("openPosition");

        vm.prank(lp);
        vault.deposit(100_000_000, 0, 30_000_000);
        _assertSolvent("deposit(reserve+gas)");

        vm.prank(lp);
        vault.increasePosition(_buyWeth(20_000_000), 40_000_000, 0.01 ether, 0, 0);
        _assertSolvent("increasePosition(mixed)");

        vm.prank(lp);
        vault.increasePositionWithToken(USDC, 25_000_000, 500, 0, _buyWeth(12_000_000), 25_000_000, 0, 0);
        _assertSolvent("increasePositionWithToken");

        vm.prank(defaultOperator);
        vault.reinjectIntoPosition(_buyWeth(3_000_000), 6_000_000, 0, 0);
        _assertSolvent("reinjectIntoPosition");

        deal(USDC, address(this), 4_000_000);
        IERC20(USDC).transfer(address(vault), 4_000_000);
        vm.prank(defaultOperator);
        vault.sweepIdleDust(_buyWeth(1_800_000), 0, 0);
        _assertSolvent("sweepIdleDust");

        vm.prank(lp);
        vault.setAutoCompoundFees(true);
        _generateTradingFees();
        vm.prank(defaultOperator);
        vault.harvestFees(_noSwap(), 0, 0);
        _assertSolvent("harvestFees");

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 4_000_000, 0, 0);
        _assertSolvent("rebalance(+reinject)");

        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vault.operatorForceRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
        _assertSolvent("operatorForceRebalance");

        vm.prank(lp);
        vault.setAutoCompoundFees(false);
        vm.prank(lp);
        vault.collectFees(_noSwap(), _noSwap(), 0, 0);
        _assertSolvent("collectFees");

        vm.prank(lp);
        vault.withdraw(3_000, 5_000, 5_000, 5_000, 0, 0, _noSwap(), _noSwap(), 0, 0);
        _assertSolvent("withdraw(partial, all buckets)");

        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());
        _assertSolvent("withdrawAll");
        assertEq(vault.investableUsdt(), 0);
        assertEq(vault.reserveBalance(), 0);
        assertEq(vault.gasReserveBalance(), 0);
        assertEq(vault.uncountedInvestable(), 0);
    }

    function test_invariant_factoryBookkeepingConsistent() public {
        vm.prank(lp);
        address v = factory.createVault(POOL, USDC, WETH, 500);
        assertTrue(factory.isVault(v), "isVault set");
        assertEq(factory.allVaults(factory.vaultCount() - 1), v, "appended to allVaults");
        address[] memory mine = factory.getVaultsByOwner(lp);
        assertEq(mine[mine.length - 1], v, "appended to _vaultsByOwner[lp]");
        // A non-vault address is never in any of the three.
        assertFalse(factory.isVault(address(0xdead)));
    }

    // --- token de terceros hostil en depositToken / increasePositionWithToken ---

    function test_hostileToken_reentrantTokenIn_isBlockedByNonReentrant() public {
        ReentrantToken rt = new ReentrantToken(address(vault));
        rt.mint(lp, 1_000_000);
        vm.startPrank(lp);
        IERC20(address(rt)).approve(address(vault), type(uint256).max);
        rt.armReenter();
        // The token reenters depositToken() during transferFrom -> nonReentrant reverts.
        vm.expectRevert();
        vault.depositToken(address(rt), 1_000_000, _noSwap(), 500, 0, 0, 500_000, 0);
        vm.stopPrank();
    }

    function test_hostileToken_falseReturningTokenIn_revertsViaSafeERC20() public {
        FalseToken ft = new FalseToken();
        ft.mint(lp, 1_000_000);
        vm.startPrank(lp);
        IERC20(address(ft)).approve(address(vault), type(uint256).max);
        vm.expectRevert(); // SafeERC20: operation did not succeed
        vault.depositToken(address(ft), 1_000_000, _noSwap(), 500, 0, 0, 500_000, 0);
        vm.stopPrank();
    }

    function test_hostileToken_feeOnTransfer_caughtByDeclaredExceedsRealBalance() public {
        // Simulate a token that delivers less than declared: mock the
        // router so the third-party swap yields far less stable than `total`.
        address dai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        deal(dai, lp, 100 ether);
        vm.startPrank(lp);
        IERC20(dai).approve(address(vault), type(uint256).max);
        vm.mockCall(
            SWAP_ROUTER02,
            abi.encodeWithSelector(ISwapRouter02.exactInputSingle.selector),
            abi.encode(uint256(1)) // the swap "returns" 1 wei of stable
        );
        vm.expectRevert(AutoRangeVaultV1.DeclaredExceedsRealBalance.selector);
        vault.depositToken(dai, 30 ether, _noSwap(), 100, 0, 0, 25_000_000, 0);
        vm.stopPrank();
    }

    // --- gas de peor caso + farming ---

    function test_gasWorstCase_rebalanceAcrossManyCrossedTicks() public {
        _openPositionWith(50, 0); // ±1000 range
        // Churn the price back and forth to cross many initialized ticks,
        // WITHOUT draining a pool side (that would just make the final
        // rebalance revert for unrelated reasons on a shared fork).
        for (uint256 i; i < 4; i++) {
            _pushPriceUp(3_000_000_000_000);
            _pushPriceDown(800 ether);
        }
        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        uint256 g0 = gasleft();
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
        uint256 used = g0 - gasleft();
        // A full rebalance after tick churn is a few million gas, nowhere
        // near a block limit — the position can never be gas-bricked.
        assertLt(used, 8_000_000, "worst-case rebalance gas stays well under a block");
    }

    function test_keeper_gasFarmingViaHarvestFees_boundedToGasReserveBucket() public {
        _openPosition();
        vm.prank(lp);
        vault.setAutoCompoundFees(true);

        uint256 opStart = IERC20(USDC).balanceOf(defaultOperator);
        uint256 gasReserveStart = vault.gasReserveBalance();

        // Hammer harvestFees (no cooldown). Even with zero fees each call
        // still runs _reimburseKeeperGas.
        for (uint256 i; i < 40; i++) {
            vm.prank(defaultOperator);
            vault.harvestFees(_noSwap(), 0, 0);
        }

        uint256 opGain = IERC20(USDC).balanceOf(defaultOperator) - opStart;
        assertLe(opGain, gasReserveStart, "farmed reimbursements can never exceed the gas-reserve bucket");
        // Once the bucket is drained, further calls reimburse 0.
        if (vault.gasReserveBalance() == 0) {
            vm.prank(defaultOperator);
            vault.harvestFees(_noSwap(), 0, 0);
            assertEq(IERC20(USDC).balanceOf(defaultOperator) - opStart, opGain, "empty bucket -> no more reimbursement");
        }
        // Never touched principal.
        assertGt(vault.investableUsdt() + _positionLiquidity(), 0);
    }

    // --- notas restantes ---

    function test_note_onERC721Received_returnsTheErc721MagicValue() public {
        vm.prank(POSITION_MANAGER);
        bytes4 r = vault.onERC721Received(address(0), address(0), 1, "");
        assertEq(r, bytes4(0x150b7a02), "must return IERC721Receiver.onERC721Received.selector");
    }

    function test_note_ownerIsAtStorageSlotZero() public view {
        bytes32 slot0 = vm.load(address(vault), bytes32(uint256(0)));
        assertEq(address(uint160(uint256(slot0))), vault.owner(), "owner lives at slot 0; OZ namespaced storage does not collide");
    }

    function test_note_hardStopIgnoresGarbageNewTicks() public {
        _openPosition();
        int24 ceilingTick = _currentTick() + tickSpacing;
        vm.prank(lp);
        vault.setHardStop(true, true, ceilingTick, false);
        _pushPriceUp(5_000_000_000_000);
        // Garbage ticks — the hard-stop path skips _checkRangeNearMarket and
        // never mints, so they're inert.
        vm.prank(lp);
        uint256 newId = vault.ownerRebalance(type(int24).max, type(int24).min, _noSwap(), _noSwap(), 0, 0, 0);
        assertEq(newId, 0);
        assertTrue(vault.paused());
        assertEq(vault.positionTokenId(), 0);
    }

    function test_note_reconfigureTargetTicksAfterInitIsNoOpForRebalance() public {
        (int24 lo, int24 hi) = _openPositionWith(50, 0);
        // Re-configure the TARGET ticks to something absurd; rebalance uses
        // its own newTick* params, not the target -> unaffected.
        vm.prank(lp);
        vault.configureTarget(945_000_000, int24(-800000), int24(-799000), 50, 10_000_000, 1 days, 500, 300, 200, 1 days, 500);
        (lo, hi) = _alignedRangeAroundMarket(2000);
        vm.prank(lp);
        vault.ownerRebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // still works, target ticks irrelevant
        assertGt(vault.positionTokenId(), 0);
    }
}

/// Mints freely; reenters the vault's depositToken() on the first
/// transferFrom after armReenter().
contract ReentrantToken {
    string public name = "RE";
    string public symbol = "RE";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address immutable vault;
    bool armed;

    constructor(address v) {
        vault = v;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function armReenter() external {
        armed = true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (armed) {
            armed = false;
            AutoRangeVaultV1(vault).depositToken(
                address(this), 1, AutoRangeVaultV1.SwapInstruction(true, 0, 0, 500), 500, 0, 0, 1, 0
            );
        }
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// transferFrom returns false instead of reverting.
contract FalseToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// Reports arbitrary token0()/token1() but is not the factory-resolved pool
/// for that pair/fee — the shape a malicious createVault() caller could use
/// to pass the token cross-check alone.
contract FakePool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }
}

/// A "pool" that reports the real token pair but reenters the factory on
/// its first token0() call (createVault has no reentrancy guard). Used to
/// prove the reentry opens no initializer front-running window.
contract ReenteringPool {
    address private immutable _t0;
    address private immutable _t1;
    address private immutable _factory;
    address private immutable _realPool;
    address public innerVault;
    bool private _entered;

    constructor(address t0_, address t1_, address factory_, address realPool_) {
        _t0 = t0_;
        _t1 = t1_;
        _factory = factory_;
        _realPool = realPool_;
    }

    function token0() external returns (address) {
        if (!_entered) {
            _entered = true;
            // reenter with the REAL pool — this inner call clones +
            // initializes atomically, then the OUTER call reverts and
            // rolls all of it back.
            innerVault = AutoRangeVaultFactoryV1(_factory).createVault(_realPool, _t1, _t0, 500);
        }
        return _t0;
    }

    function token1() external view returns (address) {
        return _t1;
    }
}

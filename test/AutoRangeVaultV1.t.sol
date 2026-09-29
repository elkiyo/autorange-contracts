// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {AutoRangePlatformConfigV1} from "../src/official/AutoRangePlatformConfigV1.sol";
import {AutoRangeVaultFactoryV1} from "../src/official/AutoRangeVaultFactoryV1.sol";
import {AutoRangeVaultV1} from "../src/official/AutoRangeVaultV1.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";

/// Fork tests against real Arbitrum mainnet, for AutoRangeVaultV1 /
/// AutoRangeVaultFactoryV1. Covers the tiered creation fee, the volatile
/// top-up path in increasePosition()/increasePositionWithToken(), the
/// exitTopRecenterMarginBps configuration field (stored and emitted
/// distinctly from recenterMarginBps, purely off-chain-consumed), and the
/// isOperator backup-wallet redundancy layer seeded from
/// AutoRangePlatformConfigV1's own operatorPool() at vault-creation time.
contract AutoRangeVaultV1Test is Test {
    address constant POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // USDC/WETH 0.05%
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // real token1 here
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // real token0 here
    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant GAS_ORACLE = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

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

        config =
            new AutoRangePlatformConfigV1(platformOwner, USDC, defaultOperator, MAX_DEPOSIT_USD, PERFORMANCE_FEE_BPS, 0, treasury);

        factory =
            new AutoRangeVaultFactoryV1(address(config), POSITION_MANAGER, SWAP_ROUTER02, GAS_ORACLE, UNISWAP_V3_FACTORY);

        vm.prank(lp);
        address v = factory.createVault(POOL, USDC, WETH, 500);
        vault = AutoRangeVaultV1(v);

        deal(USDC, lp, 10_000_000_000); // 10,000 USDC (6 decimals) — comfortably above every test's own total
        vm.prank(lp);
        IERC20(USDC).approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _setTieredFeeParams(uint256 thresholdUsd, uint256 flatUsd, uint256 bps) internal {
        vm.startPrank(platformOwner);
        config.setCreationFeeTierThresholdUsd(thresholdUsd);
        config.setCreationFeeFlatUsd(flatUsd);
        config.setCreationFeeBps(bps);
        vm.stopPrank();
    }

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

        AutoRangeVaultV1.SwapInstruction memory initSwap = AutoRangeVaultV1.SwapInstruction({
            token0ToToken1: false,
            amountIn: 475_000_000,
            amountOutMinimum: 0,
            fee: 500
        });
        vm.prank(defaultOperator);
        vault.initPosition(initSwap, 0, 0);
    }

    function _noSwap() internal pure returns (AutoRangeVaultV1.SwapInstruction memory) {
        return AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0, amountOutMinimum: 0, fee: 500});
    }

    function _lastLogData(Vm.Log[] memory logs, address emitter, string memory eventSig)
        internal
        pure
        returns (bytes memory data)
    {
        bytes32 topic0 = keccak256(bytes(eventSig));
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter == emitter && log.topics.length > 0 && log.topics[0] == topic0) {
                return log.data;
            }
        }
        revert("event not found in recorded logs");
    }

    // ---------------------------------------------------------------------
    // Tiered creation fee
    // ---------------------------------------------------------------------

    function test_creationFee_belowThreshold_flatFeeOnlyOnFirstCall() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100); // $1000 threshold, $1 flat, 1% bps

        vm.prank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 500_000_000, gasReserveAmount: 0}); // $500

        assertEq(vault.cumulativeFeeableUsd(), 500_000_000);
        assertEq(IERC20(USDC).balanceOf(treasury), 1_000_000, "flat fee only, still under threshold");
    }

    function test_creationFee_exactlyAtThreshold_viaTwoCalls_flatChargedOnlyOnce() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);

        vm.startPrank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 500_000_000, gasReserveAmount: 0});
        uint256 treasuryAfterFirst = IERC20(USDC).balanceOf(treasury);
        vault.deposit({reserveAmount: 0, investableAmount: 500_000_000, gasReserveAmount: 0});
        vm.stopPrank();

        assertEq(vault.cumulativeFeeableUsd(), 1_000_000_000);
        assertEq(treasuryAfterFirst, 1_000_000, "first call: flat fee only");
        assertEq(IERC20(USDC).balanceOf(treasury), 1_000_000, "second call: exactly at threshold, no extra charge");
    }

    function test_creationFee_crossingThreshold_midCall_onlyExcessPaysBps() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);

        vm.startPrank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 500_000_000, gasReserveAmount: 0}); // -> 500
        vault.deposit({reserveAmount: 0, investableAmount: 1_000_000_000, gasReserveAmount: 0}); // -> 1500
        vm.stopPrank();

        // second call: excessAfter=1500-1000=500, excessBefore=0 -> tier2=500, fee=500*1%=5
        assertEq(IERC20(USDC).balanceOf(treasury), 1_000_000 + 5_000_000, "$1 flat + $5 on only the $500 excess");
    }

    function test_creationFee_firstCallAloneAboveThreshold_paysFlatAndBps() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);

        vm.prank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 5_000_000_000, gasReserveAmount: 0}); // $5000

        // excess=5000-1000=4000, fee=$1 + 4000*1%=$40 => $41
        assertEq(IERC20(USDC).balanceOf(treasury), 41_000_000);
    }

    function test_creationFee_laterDepositsAfterCrossing_alwaysFullBpsNoFlat() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);

        vm.startPrank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 5_000_000_000, gasReserveAmount: 0});
        uint256 treasuryAfterFirst = IERC20(USDC).balanceOf(treasury);
        vault.deposit({reserveAmount: 0, investableAmount: 1_000_000_000, gasReserveAmount: 0});
        vm.stopPrank();

        uint256 secondFee = IERC20(USDC).balanceOf(treasury) - treasuryAfterFirst;
        assertEq(secondFee, 10_000_000, "100% tier-2: 1000*1%=$10, no flat fee again");
    }

    function test_creationFee_reinjectPath_tieredCorrectly() public {
        // Threshold below _openPosition()'s own $945 deposit, so that deposit
        // itself already crosses — lets this test isolate the REINJECT
        // call's own incremental fee cleanly.
        _setTieredFeeParams(900_000_000, 1_000_000, 100);
        _openPosition();
        // priorTotal=0->945: flat $1 + tier2=45*1%=$0.45 => $1.45
        uint256 treasuryAfterOpen = IERC20(USDC).balanceOf(treasury);
        assertEq(treasuryAfterOpen, 1_450_000);

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, _noSwap(), _noSwap(), 10_000_000, 0, 0);

        // priorTotal=945 (already all above threshold) + reinject 10 -> tier2=10, fee=10*1%=$0.10
        assertEq(IERC20(USDC).balanceOf(treasury), treasuryAfterOpen + 100_000);
        assertEq(vault.cumulativeFeeableUsd(), 955_000_000);
    }

    function test_creationFee_sharedCounterAcrossEntrypoints() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);
        _openPosition(); // cumulativeFeeableUsd = 945e6

        // A real balancing swap (roughly half into WETH) — a pure one-sided
        // top-up with no swap at all can't mint against a normal two-sided
        // position (Uniswap's own mint() reverts on the resulting near-zero
        // liquidity), same constraint every increasePosition() call already
        // has, unrelated to this test's own subject (the shared counter).
        AutoRangeVaultV1.SwapInstruction memory balanceSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 15_000_000, amountOutMinimum: 0, fee: 500});

        vm.prank(lp);
        vault.increasePosition(balanceSwap, 30_000_000, 0, 0, 0);
        assertEq(vault.cumulativeFeeableUsd(), 975_000_000);

        // tokenIn == the vault's own stable — a no-swap-of-tokenIn
        // passthrough (the SwapInstruction param still balances the mint),
        // still charges via usdtAmount, proving the SAME counter is shared
        // with increasePositionWithToken() too.
        AutoRangeVaultV1.SwapInstruction memory balanceSwap2 =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 15_000_000, amountOutMinimum: 0, fee: 500});
        vm.prank(lp);
        vault.increasePositionWithToken(USDC, 30_000_000, 500, 0, balanceSwap2, 30_000_000, 0, 0);
        assertEq(vault.cumulativeFeeableUsd(), 1_005_000_000, "crossed the threshold via the shared counter");
    }

    function test_cumulativeFeeableUsd_neverDecreasesOnWithdraw() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);
        _openPosition();
        uint256 before = vault.cumulativeFeeableUsd();
        assertGt(before, 0);

        vm.prank(lp);
        vault.withdrawAll(_noSwap(), _noSwap());

        assertEq(vault.cumulativeFeeableUsd(), before, "must never decrease");
    }

    function test_creationFee_zeroBaseAmountDoesNotChargeFlatOrAdvanceCounter() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);

        // First-ever deposit: only reserve/gas funded, investableAmount=0.
        vm.prank(lp);
        vault.deposit({reserveAmount: 10_000_000, investableAmount: 0, gasReserveAmount: 5_000_000});
        assertEq(vault.cumulativeFeeableUsd(), 0, "zero base must not advance the counter");
        assertEq(IERC20(USDC).balanceOf(treasury), 0, "zero base must not charge the flat fee");

        // A LATER real contribution still correctly charges the flat fee.
        vm.prank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 100_000_000, gasReserveAmount: 0});
        assertEq(IERC20(USDC).balanceOf(treasury), 1_000_000, "flat fee still fires on the first REAL contribution");
    }

    function test_creationFee_thresholdZero_degradesToFlatBpsOnEverything() public {
        _setTieredFeeParams(0, 0, 100); // threshold=0, flat=0, 1% bps

        vm.prank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 500_000_000, gasReserveAmount: 0});
        assertEq(IERC20(USDC).balanceOf(treasury), 5_000_000, "threshold set to 0 degrades to flat bps on everything");
    }

    function test_setCreationFeeTierThresholdUsd_and_setCreationFeeFlatUsd_onlyOwner() public {
        vm.expectRevert();
        config.setCreationFeeTierThresholdUsd(1);
        vm.expectRevert();
        config.setCreationFeeFlatUsd(1);

        vm.startPrank(platformOwner);
        config.setCreationFeeTierThresholdUsd(123);
        config.setCreationFeeFlatUsd(456);
        vm.stopPrank();
        assertEq(config.creationFeeTierThresholdUsd(), 123);
        assertEq(config.creationFeeFlatUsd(), 456);
    }

    // ---------------------------------------------------------------------
    // Fix #1 — increasePositionWithToken(tokenIn: volátil) no rompe la
    // aprobación del router
    // ---------------------------------------------------------------------

    function test_increasePositionWithToken_volatileTokenIn_doesNotBreakRouterApproval() public {
        // Real finding during development: a pure volatile top-up
        // (usdtAmount=0) via this path can only mint successfully in the
        // SAME tx when the position is CURRENTLY one-sided (100% volatile)
        // at the pool's live price — Fix #1 only removed the (unsafe)
        // swap-to-stable step, it never claimed to make a two-sided
        // position accept a hard-zero stable side (Uniswap's own mint()
        // rejects that, independent of this vault's own code). A NARROW
        // range (±20 ticks, vs. _openPosition()'s own ±1000) so a modest
        // price move genuinely pushes it fully out of range — the
        // realistic scenario this feature actually targets (a position
        // already skewed one-sided after a real price move).
        (int24 lower, int24 upper) = _alignedRangeAroundMarket(40);
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 0, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
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
        vault.initPosition(
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 475_000_000, amountOutMinimum: 0, fee: 500}),
            0,
            0
        );

        // Push the price down just enough to fall below `lower`.
        address pusher = makeAddr("pricePusherVolatileTopUp");
        deal(WETH, pusher, 200 ether);
        vm.startPrank(pusher);
        IERC20(WETH).approve(SWAP_ROUTER02, type(uint256).max);
        ISwapRouter02(SWAP_ROUTER02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: 500,
                recipient: pusher,
                amountIn: 200 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertLt(_currentTick(), lower, "sanity: the trade should have pushed the position fully out of range");

        deal(WETH, lp, 1 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vault.increasePositionWithToken(WETH, 0.1 ether, 500, 0, _noSwap(), 0, 0, 0);
        vm.stopPrank();

        assertEq(
            IERC20(WETH).allowance(address(vault), SWAP_ROUTER02),
            type(uint256).max,
            "router approval must remain untouched - the whole point of Fix #1"
        );

        // Prove it's practically unbroken too: a later rebalance that needs
        // to SELL WETH must still work (would revert with STF before Fix #1).
        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        AutoRangeVaultV1.SwapInstruction memory sellSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0.01 ether, amountOutMinimum: 0, fee: 500});
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, sellSwap, _noSwap(), 0, 0, 0);
    }

    // ---------------------------------------------------------------------
    // tokenIn == the vault's own volatile), no fee double-charge
    // ---------------------------------------------------------------------

    function test_increasePositionWithToken_volatileTopUp_partialSell_mintsBothLegs() public {
        // In-range (two-sided) position — the exact case Fix #1's own
        // router-approval test above deliberately does NOT cover (that one
        // uses a narrow range pushed fully out of range so a pure top-up
        // can mint with zero stable). This is the realistic, common case
        // this fix targets: the owner wants to add 100% volatile to a
        _openPosition();
        deal(WETH, lp, 0.2 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        // Sell half of the 0.2 WETH typed via the internal swap — a rough
        // 50/50-by-value split, close to what _openPosition()'s own
        // roughly-centered ±1000-tick range genuinely needs to mint on
        // both legs without leaving much dust behind.
        AutoRangeVaultV1.SwapInstruction memory sellSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0.1 ether, amountOutMinimum: 0, fee: 500});
        uint256 usdtAmount = _wethToUsdApprox(0.1 ether);

        vm.recordLogs();
        vault.increasePositionWithToken(WETH, 0.2 ether, 0, 0, sellSwap, usdtAmount, 0, 0);
        vm.stopPrank();

        bytes memory data =
            _lastLogData(vm.getRecordedLogs(), address(vault), "PositionIncreased(uint256,uint256,uint256,uint256,uint256)");
        (uint256 emittedUsdt, uint256 used0, uint256 used1,, uint256 volatileFoldedUsd) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256));

        assertEq(emittedUsdt, usdtAmount);
        assertGt(used1, 0, "stable leg (token1 = USDC), funded by the internal sale, must have minted");
        assertGt(used0, 0, "volatile leg (token0 = WETH), the un-sold remainder, must have minted");
        assertGt(volatileFoldedUsd, 0, "the un-sold remainder must still count toward B1");
    }

    function test_increasePositionWithToken_volatileTopUp_partialSell_feeNotDoubleCharged() public {
        // Threshold below _openPosition()'s own $945 deposit — that deposit
        // alone already crosses it, so every USD unit of THIS call's own
        // contribution is 100% tier-2 bps, no flat-fee complication to
        // untangle (same isolation technique
        // test_creationFee_reinjectPath_tieredCorrectly already uses).
        _setTieredFeeParams(900_000_000, 1_000_000, 100); // $900 threshold, $1 flat, 1% bps
        _openPosition();
        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);

        deal(WETH, lp, 0.2 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        AutoRangeVaultV1.SwapInstruction memory sellSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0.1 ether, amountOutMinimum: 0, fee: 500});
        uint256 usdtAmount = _wethToUsdApprox(0.1 ether);

        vault.increasePositionWithToken(WETH, 0.2 ether, 0, 0, sellSwap, usdtAmount, 0, 0);
        vm.stopPrank();

        uint256 unsoldVolatileUsd = _wethToUsdApprox(0.1 ether); // 0.2 - 0.1, the un-sold remainder
        uint256 expectedFee = ((usdtAmount + unsoldVolatileUsd) * 100) / 10_000; // 1% bps, tier-2 only
        uint256 preFixDoubleChargedFee = ((usdtAmount + _wethToUsdApprox(0.2 ether)) * 100) / 10_000;

        uint256 actualFee = IERC20(USDC).balanceOf(treasury) - treasuryBefore;
        // 1% tolerance for the approximate USD pricing (_wethToUsdApprox
        // reads the pool's price AFTER the sale already moved it slightly)
        // — the point of this test is the ~1% double-charge gap being
        // closed, not pixel-perfect fee accounting.
        assertApproxEqRel(actualFee, expectedFee, 0.01e18, "the sold portion must pay its fee exactly once, via usdtAmount");
        assertLt(actualFee, preFixDoubleChargedFee, "sanity: strictly less than the pre-fix double-charge would have been");
    }

    function test_increasePositionWithToken_volatileTopUp_partialSell_b1IsExact() public {
        _openPosition();
        deal(WETH, lp, 0.2 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        AutoRangeVaultV1.SwapInstruction memory sellSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0.1 ether, amountOutMinimum: 0, fee: 500});
        uint256 usdtAmount = _wethToUsdApprox(0.1 ether);

        vm.recordLogs();
        vault.increasePositionWithToken(WETH, 0.2 ether, 0, 0, sellSwap, usdtAmount, 0, 0);
        vm.stopPrank();

        bytes memory data =
            _lastLogData(vm.getRecordedLogs(), address(vault), "PositionIncreased(uint256,uint256,uint256,uint256,uint256)");
        (uint256 emittedUsdt,,,, uint256 volatileFoldedUsd) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256));

        uint256 totalContributedUsd = _wethToUsdApprox(0.2 ether); // full contribution's value at call time
        uint256 b1Delta = emittedUsdt + volatileFoldedUsd;
        assertLe(b1Delta, totalContributedUsd + totalContributedUsd / 20, "B1 must never count materially more than what genuinely entered");
        assertGe(
            b1Delta,
            totalContributedUsd - totalContributedUsd / 20,
            "B1 must capture at least 95% (rest is un-minted dust, picked up on a later sweepIdleDust cycle)"
        );
    }

    function test_increasePositionWithToken_volatileTopUp_partialSell_doesNotBreakRouterApproval() public {
        _openPosition();
        deal(WETH, lp, 0.2 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        AutoRangeVaultV1.SwapInstruction memory sellSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0.1 ether, amountOutMinimum: 0, fee: 500});
        vault.increasePositionWithToken(WETH, 0.2 ether, 0, 0, sellSwap, _wethToUsdApprox(0.1 ether), 0, 0);
        vm.stopPrank();

        // Real finding while writing this test: _executeSwap() never calls
        // forceApprove() (that's the whole point — it relies on the
        // PERSISTENT approval instead of a fresh exact one, see this
        // contract's own class docstring) — but a plain ERC20 allowance
        // still decrements by the amount actually transferFrom'd,
        // REGARDLESS of the approved value being type(uint256).max.
        // Arbitrum's canonical WETH does not special-case "infinite"
        // approval to skip that decrement (confirmed here: after selling
        // 0.1 ether, the allowance is exactly type(uint256).max - 0.1
        // ether, not still exactly max). The original Fix #1 test above
        // never caught this because it uses _noSwap() (amountIn=0), so
        // _executeSwap() returns early without ever calling the router —
        // this is the first test in the suite to exercise a REAL swap
        // through this path. This is not a regression: the approval is
        // "persistent" in the sense that matters (never re-set to a small
        // EXACT amount that a single swap can fully exhaust to zero, the
        // real bug Fix #1 closed) — it just isn't literally immutable, the
        // same as any real ERC20 allowance being spent down. At this scale
        // (2^256), no realistic volume of real swaps ever gets close to
        // exhausting it — asserting "still astronomically large" here,
        // and proving it's PRACTICALLY unbroken via the real rebalance
        // below, which is what actually matters.
        assertGt(
            IERC20(WETH).allowance(address(vault), SWAP_ROUTER02),
            type(uint256).max - 1 ether,
            "the approval must still be functionally unlimited after a partial-sell top-up"
        );

        // Prove it's practically unbroken too: a later rebalance that needs
        // to SELL WETH must still work (same scenario Fix #1's own test
        // above protects, exercised again after this new code path ran).
        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        AutoRangeVaultV1.SwapInstruction memory laterSell =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 0.01 ether, amountOutMinimum: 0, fee: 500});
        vm.prank(defaultOperator);
        vault.rebalance(lo, hi, laterSell, _noSwap(), 0, 0, 0);
    }

    // ---------------------------------------------------------------------
    // Fix #3/#4 — atomic volatile top-up, B1 counting, tiered fee on it
    // ---------------------------------------------------------------------

    function test_increasePosition_mixedTopUp_foldsVolatileAndCountsInB1() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);
        _openPosition();
        deal(WETH, lp, 1 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        // Mixed contribution: real stable AND real volatile in the SAME
        // call — the common real-world case this fix targets (see
        // AutoRangeVaultV1.sol's own class docstring, item 3).
        AutoRangeVaultV1.SwapInstruction memory balanceSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 20_000_000, amountOutMinimum: 0, fee: 500});
        vm.recordLogs();
        vault.increasePosition(balanceSwap, 30_000_000, 0.01 ether, 0, 0);
        vm.stopPrank();

        bytes memory data =
            _lastLogData(vm.getRecordedLogs(), address(vault), "PositionIncreased(uint256,uint256,uint256,uint256,uint256)");
        (uint256 usdtAmount,,,, uint256 volatileFoldedUsd) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
        assertEq(usdtAmount, 30_000_000);
        assertGt(volatileFoldedUsd, 0, "the mixed-contribution case must fold and count the volatile leg");
    }

    function test_increasePosition_volatileTopUp_neverDoubleCountsPreexistingDust() public {
        _setTieredFeeParams(1_000_000_000, 1_000_000, 100);
        _openPosition();
        deal(WETH, lp, 1 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        // Pre-existing dust: a raw WETH transfer with no accompanying call —
        // never counted anywhere until something folds it in.
        IERC20(WETH).transfer(address(vault), 0.005 ether);

        AutoRangeVaultV1.SwapInstruction memory balanceSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 20_000_000, amountOutMinimum: 0, fee: 500});
        vm.recordLogs();
        // realVolatileTopUp (measured, atomic) = 0.01 ether — the dust above
        // is NOT part of this call's own measured delta.
        vault.increasePosition(balanceSwap, 30_000_000, 0.01 ether, 0, 0);
        vm.stopPrank();

        bytes memory data =
            _lastLogData(vm.getRecordedLogs(), address(vault), "PositionIncreased(uint256,uint256,uint256,uint256,uint256)");
        (,,,, uint256 volatileFoldedUsd) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
        // Even if the mint happened to fold MORE than 0.01 ether worth of
        // volatile (pulling from the pre-existing dust too), volatileFoldedUsd
        // must be bounded by the MEASURED top-up alone — proving the min()
        // in _finishIncreasePosition actually closes the double-count gap.
        uint256 topUpValueUsd = _wethToUsdApprox(0.01 ether);
        assertLe(volatileFoldedUsd, topUpValueUsd + topUpValueUsd / 100, "never counts more than this call's own measured top-up (1% slippage tolerance)");
    }

    function _wethToUsdApprox(uint256 wethRaw) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        // stableIsToken0 == false on this pool (USDC=token1) — same formula
        // as _nativeWeiToStableRaw's own else-branch.
        uint256 step1 = (wethRaw * uint256(sqrtPriceX96)) >> 96;
        return (step1 * uint256(sqrtPriceX96)) >> 96;
    }

    function test_increasePositionWithToken_thirdParty_volatileFoldedUsdStaysZero() public {
        _openPosition();
        // DAI as a genuine third-party token — never the vault's own volatile.
        address dai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        deal(dai, lp, 100 ether);
        vm.startPrank(lp);
        IERC20(dai).approve(address(vault), type(uint256).max);
        // Real balancing swap — same reasoning as
        // test_creationFee_sharedCounterAcrossEntrypoints's own comment.
        AutoRangeVaultV1.SwapInstruction memory balanceSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 14_000_000, amountOutMinimum: 0, fee: 500});
        vm.recordLogs();
        vault.increasePositionWithToken(dai, 30 ether, 100, 0, balanceSwap, 29_000_000, 0, 0);
        vm.stopPrank();

        bytes memory data =
            _lastLogData(vm.getRecordedLogs(), address(vault), "PositionIncreased(uint256,uint256,uint256,uint256,uint256)");
        (,,,, uint256 volatileFoldedUsd) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256));
        assertEq(volatileFoldedUsd, 0, "a genuine third-party token never touches the volatile-leg accounting");
    }

    function test_increasePosition_revertsWithNoPosition_evenWithOnlyVolatileTopUp() public {
        deal(WETH, lp, 1 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vm.expectRevert(AutoRangeVaultV1.NoPosition.selector);
        vault.increasePosition(_noSwap(), 0, 0.1 ether, 0, 0);
        vm.stopPrank();
    }

    function test_increasePositionWithToken_volatileTopUp_partialSell_feeDrawsFromSwapProceedsOnLeanVault() public {
        // Real bug found during the pre-deploy audit, confirmed with this
        // exact test before the fix existed (reverted with "ERC20:
        // transfer amount exceeds balance" every time): _finishIncreasePosition()
        // used to pay the creation fee BEFORE running swapIx — safe for
        // somewhere else in the same call by the time this ran), but not
        // for THIS version's own new use case, where swapIx can be the
        // ONLY source of stable available. Fixed by running the swap
        // first — this test locks that ordering in.
        _setTieredFeeParams(0, 0, 100); // pure 1% bps from the start, no threshold/flat noise
        _openPosition();

        // A big enough contribution that its 1% fee on the un-sold leg
        // alone exceeds _openPosition()'s own leftover reserve+gas buckets
        // (50 + 5 = 55 USDC combined raw balance) — the ONLY stable
        // _payCreationFee() could draw from if it ran BEFORE the internal
        // swap generates fresh proceeds.
        deal(WETH, lp, 5 ether);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(vault), type(uint256).max);

        AutoRangeVaultV1.SwapInstruction memory sellSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: true, amountIn: 2.5 ether, amountOutMinimum: 0, fee: 500});
        uint256 usdtAmount = _wethToUsdApprox(2.5 ether);

        vault.increasePositionWithToken(WETH, 5 ether, 0, 0, sellSwap, usdtAmount, 0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // recenterMarginBps
    // ---------------------------------------------------------------------

    function test_exitTopRecenterMarginBps_storedAndEmittedDistinctFromRecenterMarginBps() public {
        (int24 lower, int24 upper) = _alignedRangeAroundMarket(2000);
        vm.startPrank(lp);
        vault.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});

        vm.recordLogs();
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
            _exitTopRecenterMarginBps: 750 // deliberately DIFFERENT from recenterMarginBps (500)
        });
        vm.stopPrank();

        assertEq(vault.recenterMarginBps(), 500);
        assertEq(
            vault.exitTopRecenterMarginBps(), 750, "must be stored independently, not aliased to recenterMarginBps"
        );

        bytes memory data = _lastLogData(
            vm.getRecordedLogs(),
            address(vault),
            "TargetConfigured(uint256,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        (,,,,,, uint256 emittedRecenterMarginBps,,,, uint256 emittedExitTopRecenterMarginBps) = abi.decode(
            data, (uint256, int24, int24, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
        );
        assertEq(emittedRecenterMarginBps, 500);
        assertEq(emittedExitTopRecenterMarginBps, 750, "TargetConfigured must emit the new field distinctly");
    }

    function test_exitTopRecenterMarginBps_reconfigureCanChangeItWithoutTouchingRecenterMarginBps() public {
        (int24 lower, int24 upper) = _openPosition(); // uses 500/500 for both margin fields by default
        assertEq(vault.recenterMarginBps(), 500);
        assertEq(vault.exitTopRecenterMarginBps(), 500);

        vm.prank(lp);
        vault.configureTarget({
            investmentAmountUsd: 945_000_000,
            _targetTickLower: lower,
            _targetTickUpper: upper,
            _maxRebalances: 5,
            _reinjectionAmount: 10_000_000,
            _periodicRebalanceInterval: 1 days,
            _recenterMarginBps: 500, // unchanged
            _exitTopCeilingMarginBps: 300,
            _feeClaimThresholdBps: 200,
            _feeClaimIntervalSeconds: 1 days,
            _exitTopRecenterMarginBps: 1200 // owner tightens ONLY the broke-above re-entry margin
        });

        assertEq(vault.recenterMarginBps(), 500, "the routine/broke-below margin must be untouched");
        assertEq(vault.exitTopRecenterMarginBps(), 1200, "only the broke-above margin changed");
    }

    // ---------------------------------------------------------------------
    // ---------------------------------------------------------------------

    function _createVaultWithPool(address[] memory pool) internal returns (AutoRangeVaultV1 v) {
        vm.prank(platformOwner);
        config.setOperatorPool(pool);
        vm.prank(lp);
        address addr = factory.createVault(POOL, USDC, WETH, 500);
        v = AutoRangeVaultV1(addr);
    }

    function _fundAndOpenPosition(AutoRangeVaultV1 v, address operatorToInit)
        internal
        returns (int24 lower, int24 upper)
    {
        (lower, upper) = _alignedRangeAroundMarket(2000);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(v), type(uint256).max);
        v.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
        v.configureTarget({
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
        v.setRiskParams(500, 0, 500);
        vm.stopPrank();

        AutoRangeVaultV1.SwapInstruction memory initSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 475_000_000, amountOutMinimum: 0, fee: 500});
        vm.prank(operatorToInit);
        v.initPosition(initSwap, 0, 0);
    }

    function test_isOperator_poolWalletCanActWhereDefaultOperatorNeverSigned() public {
        // The pool wallet, NEVER the vault's own primary `operator`, signs
        // initPosition() below — proves isOperator is a genuinely separate,
        // functional authorization path, not a fallback that only works
        // because `operator` also happens to succeed.
        address backupWallet = makeAddr("backupOperatorWalletA");
        address[] memory pool = new address[](1);
        pool[0] = backupWallet;
        AutoRangeVaultV1 v = _createVaultWithPool(pool);

        assertTrue(v.isOperator(backupWallet), "pool wallet must be seeded as an authorized operator at creation");
        assertEq(v.operator(), defaultOperator, "the single primary `operator` slot is untouched by pool seeding");

        _fundAndOpenPosition(v, backupWallet);
        assertGt(v.positionTokenId(), 0, "the pool wallet's initPosition() call must have genuinely succeeded");
    }

    function test_isOperator_neverAddedWalletCannotOperate() public {
        address backupWallet = makeAddr("backupOperatorWalletB");
        address[] memory pool = new address[](1);
        pool[0] = backupWallet;
        AutoRangeVaultV1 v = _createVaultWithPool(pool);

        (int24 lower, int24 upper) = _alignedRangeAroundMarket(2000);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(v), type(uint256).max);
        v.deposit({reserveAmount: 50_000_000, investableAmount: 945_000_000, gasReserveAmount: 5_000_000});
        v.configureTarget({
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
        v.setRiskParams(500, 0, 500);
        vm.stopPrank();

        address stranger = makeAddr("neverAuthorizedOperator");
        AutoRangeVaultV1.SwapInstruction memory initSwap =
            AutoRangeVaultV1.SwapInstruction({token0ToToken1: false, amountIn: 475_000_000, amountOutMinimum: 0, fee: 500});
        vm.prank(stranger);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        v.initPosition(initSwap, 0, 0);
    }

    function test_setOperatorStatus_grantsAndRevokes() public {
        address backupWallet = makeAddr("backupOperatorWalletC");
        AutoRangeVaultV1 v = _createVaultWithPool(new address[](0)); // empty pool at creation time
        assertFalse(v.isOperator(backupWallet), "not authorized yet - empty pool at vault creation");

        vm.prank(lp); // lp is this vault's owner (createVault's own msg.sender)
        v.setOperatorStatus(backupWallet, true);
        assertTrue(v.isOperator(backupWallet));

        _fundAndOpenPosition(v, backupWallet); // proves the grant is genuinely functional, not just a flag

        vm.prank(lp);
        v.setOperatorStatus(backupWallet, false);
        assertFalse(v.isOperator(backupWallet));

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);
        vm.prank(backupWallet);
        vm.expectRevert(AutoRangeVaultV1.NotOperator.selector);
        v.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);
    }

    function test_setOperatorStatus_onlyOwner() public {
        AutoRangeVaultV1 v = _createVaultWithPool(new address[](0));
        vm.expectRevert(AutoRangeVaultV1.NotOwner.selector);
        v.setOperatorStatus(makeAddr("someoneElse"), true);
    }

    function test_setPaused_blocksEveryOperatorRegardlessOfIsOperatorMapping() public {
        address backupWallet = makeAddr("backupOperatorWalletD");
        address[] memory pool = new address[](1);
        pool[0] = backupWallet;
        AutoRangeVaultV1 v = _createVaultWithPool(pool);
        _fundAndOpenPosition(v, backupWallet);

        vm.prank(lp);
        v.setPaused(true);

        vm.warp(block.timestamp + 1 days + 1);
        (int24 lo, int24 hi) = _alignedRangeAroundMarket(2000);

        vm.prank(defaultOperator);
        vm.expectRevert(AutoRangeVaultV1.Paused.selector);
        v.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        vm.prank(backupWallet);
        vm.expectRevert(AutoRangeVaultV1.Paused.selector);
        v.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0);

        // The kill switch is total, not selective — confirms pause() (not
        // per-wallet removal) remains the real emergency lever regardless of
        // how many addresses are currently authorized, exactly as designed.
        vm.prank(lp);
        v.setPaused(false);
        vm.prank(backupWallet);
        v.rebalance(lo, hi, _noSwap(), _noSwap(), 0, 0, 0); // must succeed again once unpaused
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {IPlatformConfig} from "../interfaces/IPlatformConfig.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title AutoRangeVaultV1
/// @notice Non-custodial Uniswap V3 concentrated-liquidity vault. The owner
/// deposits/withdraws/configures; the operator (or any wallet in the
/// platform's own operator pool) may only rebalance within the guardrails
/// the owner set — it can never move funds to an arbitrary address.
///
/// Key mechanisms:
///   - `exitTopRecenterMarginBps` — a dedicated recenter margin for the
///     out-of-range-top case, decoupled from `recenterMarginBps` (used by
///     every other recenter case: periodic, out-of-range-bottom,
///     ownerRebalance, operatorForceRebalance). Off-chain-consumed only,
///     stored purely as an owner-configurable knob for the keeper to read.
///     Set via configureTarget()'s 11th parameter, emitted as
///     TargetConfigured's 11th field.
///   - `isOperator` — a wallet-pool redundancy layer, additive on top of the
///     single `operator` slot (unchanged): every wallet in the platform's
///     own operator pool, seeded once from AutoRangePlatformConfigV1's
///     `operatorPool()` at initialize() time, becomes a valid operator for
///     this vault, so it's never stuck just because one assigned wallet is
///     temporarily out of gas or rate-limited. `setOperatorStatus()`
///     (onlyOwner) lets the owner adjust the set later. `setPaused()`
///     remains the one real emergency kill switch, blocking every
///     `onlyOperator` function regardless of how many wallets are
///     authorized.
///
/// Hard ceiling/floor: if the volatile asset's price crosses an owner-
/// configured absolute bound, the position is closed, optionally converted
/// to the stable asset, and the vault auto-pauses — recoverable at any time
/// via withdraw()/withdrawAll()/emergencyWithdrawPosition()/
/// rescuePosition(), none of which are ever gated on `paused`.
///
/// Known tradeoff, documented explicitly: `isOperator` widens the blast
/// radius of a single compromised operator wallet from "one vault" to
/// "every vault that had that wallet in its own operator pool at creation
/// time" (the mapping is seeded once, never re-synced — removing a wallet
/// from the platform-wide pool later does not retroactively revoke it from
/// vaults that already seeded it). Mitigated, not eliminated: (a)
/// `setPaused(true)`, owner-only, per-vault, instantly blocks ALL operator
/// access on that one vault; (b) every withdrawal path is always available
/// to the owner regardless of pause state; (c) none of the `onlyOperator`
/// functions (rebalance, operatorForceRebalance, reinjectIntoPosition)
/// accept an arbitrary recipient — every fund movement stays inside the
/// vault's own position/ledgers, the only external transfers are the fixed
/// operator/treasury performance-fee and creation-fee cuts.
contract AutoRangeVaultV1 is Initializable, ReentrancyGuardUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotOperator();
    error Paused();
    error AlreadyInitializedPosition();
    error NoPosition();
    error TargetNotConfigured();
    error RangeTooFarFromMarket();
    error TooSoonToRebalance();
    error RebalanceLimitReached();
    error InsufficientReserve();
    error InvalidSwapInstruction();
    error DepositExceedsPlatformCap();
    error ZeroAddress();
    error NotPositionManager();
    error VaultClosed();
    error VaultNotEmpty();
    error ReinjectionExceedsCap();
    error InvalidShareBps();
    error AutoCompoundNotEnabled();
    /// @notice The "invertible" bucket can only ever be funded before the
    /// first position exists. Use increasePosition()/increasePositionWithToken()
    /// to add capital to an already-open position instead.
    error InvestableAfterPositionExists();
    /// @notice dustAmount0/dustAmount1 in withdraw() exceeded what's actually
    /// sitting unaccounted-for in the vault's raw balance.
    error InvalidDustAmount();
    /// investableAmount + gasReserveAmount exceeds the real value (stable
    /// received + volatile received, valued at spot price) this call
    /// actually brought into the vault.
    error DeclaredExceedsRealBalance();
    /// hardCeilingTick once both are enabled (direction-aware — see
    /// _hardStopOrderValid()).
    error InvalidHardStopOrder();
    /// token, same as every pair this project has today; the gas-oracle
    /// conversion's fixed /1e20 divisor assumes it (see _ethUsdFromOracle).
    error UnsupportedStableDecimals();

    // ---------------------------------------------------------------------
    // Immutable-ish config (set once in initialize())
    // ---------------------------------------------------------------------

    address public owner;
    address public platformConfig;

    IUniswapV3Pool public pool;
    address public token0; // Uniswap's real token0 — the LOWER of the two addresses, not necessarily the stablecoin
    address public token1; // Uniswap's real token1
    bool public stableIsToken0; // true on Celo (USDT<WETH), false on Arbitrum (WETH<USDC)
    uint24 public feeTier;

    INonfungiblePositionManager public positionManager;
    ISwapRouter02 public swapRouter;
    /// reimbursement — deliberately NOT the vault's own pool (see
    /// _ethUsdFromOracle's own docstring for why that was wrong for any
    /// non-WETH volatile asset). Set once here, same immutable-at-creation
    /// pattern as positionManager/swapRouter — no setter, same precedent
    /// already accepted for platformConfig ("vaults created keep the config
    /// they were born with, forever").
    address public gasPriceOracle;

    // ---------------------------------------------------------------------
    // Operator
    // ---------------------------------------------------------------------

    address public operator;

    /// above. Seeded once from AutoRangePlatformConfigV1.operatorPool() at
    /// initialize() time (see that function), adjustable afterward via
    /// setOperatorStatus(). See this contract's own top docstring for the
    /// full rationale.
    mapping(address => bool) public isOperator;

    // ---------------------------------------------------------------------
    // Ledgers — all three are carved out of the same stable-leg balance but
    // must never be spent on each other's behalf.
    // ---------------------------------------------------------------------

    uint256 public investableUsdt; // capital not yet deployed into a position
    uint256 public reserveBalance; // capital available for the keeper to reinject into a position, over time
    // Dedicated, owner-funded budget for rebalance()'s keeper gas
    // reimbursement — deliberately separate from investableUsdt.
    uint256 public gasReserveBalance;

    /// @notice `investableUsdt` mixes two things that must be treated
    /// differently for B1 (cumulative investment) accounting off-chain:
    /// genuinely new capital from a LATER deposit()/depositToken() call (made
    /// after a position already exists) that hasn't been folded into the
    /// position yet, vs. leftover stable-side residue from a prior mint that
    /// was already counted once. `uncountedInvestable` tracks ONLY the
    /// former. A LATER deposit()/depositToken() call with investableAmount > 0
    /// always reverts (see InvestableAfterPositionExists), so this counter
    /// can now only ever grow via increasePosition()/increasePositionWithToken().
    ///
    /// Every function that reassigns investableUsdt from a freshly MEASURED
    /// balance (sweepIdleDust, rebalance, ownerRebalance, _reinjectFees,
    /// increasePosition, increasePositionWithToken, reinjectIntoPosition)
    /// clamps uncountedInvestable to never exceed it afterward — the
    /// invariant this field exists to protect, guarding against any
    /// measurement drift before it can compound into a real discrepancy.
    uint256 public uncountedInvestable;

    /// @notice Monotonically increasing running total of every
    /// fee-eligible dollar ever contributed to this vault: investableAmount
    /// at deposit()/depositToken(), usdtAmount AND the volatile leg's USD
    /// value at increasePosition()/increasePositionWithToken(), and
    /// reinjectAmount at _rebalanceCore's reinject step. Raw 6-decimal
    /// stable units. Deliberately NEVER decremented by withdraw() — a gross
    /// lifetime-inflow counter, not a live balance — so an owner can't cycle
    /// withdraw()+redeposit() to keep re-qualifying a large vault for
    /// bracket-1 (flat-fee-only) treatment. Written ONLY by
    /// _creationFeeFor(), which is the sole place that reads/advances it.
    uint256 public cumulativeFeeableUsd;

    // ---------------------------------------------------------------------
    // Interés compuesto — todos off-chain-only knobs salvo autoCompoundFees.
    // ---------------------------------------------------------------------

    bool public autoCompoundFees;
    /// @notice Only meaningful when autoCompoundFees == false — left settable
    /// regardless (not gated on autoCompoundFees being off) so the owner can
    /// pre-arm it before flipping the other switch, one fewer tx. Applies
    /// automatically, without any per-call choice, whenever a fee gets paid
    /// DIRECTLY to the owner: collectFees()'s non-compounding branch, and
    /// rebalance()/ownerRebalance()'s non-compounding branch — needed as a
    /// persistent on-chain flag specifically because rebalance() is
    /// keeper-triggered, not owner-triggered, so the keeper has no way to
    /// receive a per-call choice from the owner at the moment it runs.
    bool public payoutFeesInStableOnly;
    uint256 public feeClaimThresholdBps;
    uint256 public feeClaimIntervalSeconds;
    uint256 public lastFeeClaimTimestamp;

    // ---------------------------------------------------------------------
    // Hard ceiling — absolute price stop for the volatile asset
    // ---------------------------------------------------------------------

    /// @notice A separate bool instead of a sentinel tick value (e.g.
    /// type(int24).max) — avoids any ambiguity over which raw tick value
    /// means "disabled", and matches this contract's own established pattern
    /// (autoCompoundFees, payoutFeesInStableOnly) of a dedicated enabled flag.
    bool public hardCeilingEnabled;
    /// @notice Stored as a tick (Uniswap's native on-chain unit), same as
    /// targetTickLower/targetTickUpper — the frontend already converts a
    /// human price input to a tick for every other range field, same pattern
    /// here. IMPORTANT: a higher tick does NOT always mean a higher price —
    /// it depends on stableIsToken0 (documented gotcha in this exact
    /// direction unconditionally). See _hardStopTriggered() below for the
    /// direction-aware comparison — never compare hardCeilingTick to the
    /// current tick directly anywhere else.
    int24 public hardCeilingTick;

    // ---------------------------------------------------------------------
    // Hard floor — absolute price stop, mirrors hard ceiling
    // ---------------------------------------------------------------------

    bool public hardFloorEnabled;
    /// @notice Same direction gotcha as hardCeilingTick, opposite comparison —
    /// see _hardStopTriggered() below, never compare this tick directly anywhere else.
    int24 public hardFloorTick;
    /// @notice false (default) = exit with whatever composition results
    /// naturally, no forced swap — avoids selling into a panic. true = real
    /// stop-loss, converts 100% to stable via the same _convertPayoutToStable
    /// the ceiling always uses.
    bool public hardFloorConvertToStable;

    // ---------------------------------------------------------------------
    // B1 seed, on-chain declared "capital to recover"
    // ---------------------------------------------------------------------

    /// @notice Owner-declared B1 (raw stable units, same format as
    /// investableUsdt) for a vault created to migrate a devalued position's
    /// capital from elsewhere. Purely informational to this contract — read
    /// by the keeper as the B1 it hands uni-lab.xyz for this vault's first
    /// rebalance, exactly like a real B1 would behave from then on (grows/
    /// shrinks with real deposits/withdrawals same as any other vault — this
    /// field is only ever the STARTING point, off-chain B1 accounting still
    /// walks the normal event history layered on top of it).
    uint256 public b1SeedRaw;

    // ---------------------------------------------------------------------
    // Target config — owner-set, what the agent should build/maintain
    // ---------------------------------------------------------------------

    bool public targetConfigured;
    int24 public targetTickLower;
    int24 public targetTickUpper;
    uint256 public maxRebalances;
    uint256 public reinjectionAmount;
    uint256 public periodicRebalanceInterval;
    uint256 public recenterMarginBps;
    uint256 public exitTopCeilingMarginBps;
    /// out-of-range-top case, decoupled from recenterMarginBps above (which
    /// every OTHER recenter case keeps using). Off-chain-only, read by the
    /// keeper's runRebalanceExitTop(), never on-chain. See this contract's
    /// own top docstring.
    uint256 public exitTopRecenterMarginBps;

    // ---------------------------------------------------------------------
    // Risk params — owner-set bounds the operator must stay within
    // ---------------------------------------------------------------------

    uint256 public maxSlippageBps;
    uint256 public minRebalanceInterval;
    uint256 public maxRangeDeviationBps;

    // ---------------------------------------------------------------------
    // Runtime state
    // ---------------------------------------------------------------------

    uint256 public positionTokenId;
    uint256 public rebalanceCount;
    uint256 public lastRebalanceTimestamp;
    // operatorForceRebalance()'s own dedicated bookkeeping — deliberately
    // separate from rebalanceCount/lastRebalanceTimestamp above, see this
    // contract's own classdoc for why (never eats into the owner's
    // maxRebalances budget, never shares the owner's minRebalanceInterval
    // cooldown).
    uint256 public forceRebalanceCount;
    uint256 public lastForceRebalanceTimestamp;
    bool public paused;
    bool public closed;

    struct SwapInstruction {
        bool token0ToToken1;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint24 fee;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice `positionAlreadyExists` is now ALWAYS false — kept in the
    /// event signature regardless for off-chain event-decoding compatibility
    event Deposited(uint256 investableAmount, uint256 reserveAmount, uint256 gasReserveAmount, bool positionAlreadyExists);
    event CreationFeeCharged(uint256 amount);
    event TargetConfigured(
        uint256 investmentAmountUsd,
        int24 targetTickLower,
        int24 targetTickUpper,
        uint256 maxRebalances,
        uint256 reinjectionAmount,
        uint256 periodicRebalanceInterval,
        uint256 recenterMarginBps,
        uint256 exitTopCeilingMarginBps,
        uint256 feeClaimThresholdBps,
        uint256 feeClaimIntervalSeconds,
        uint256 exitTopRecenterMarginBps
    );
    event OperatorStatusUpdated(address indexed operator, bool authorized);
    event PositionInitialized(uint256 tokenId, uint256 amount0, uint256 amount1);
    /// @notice `consumedUncounted` — how much of this cycle's fold-in was
    /// genuinely new, not-yet-counted investable capital (see
    /// uncountedInvestable's own docstring). Shared by rebalance() and
    /// ownerRebalance(). newTokenId == 0 signals the hard-ceiling/hard-floor
    /// exit path (position closed, no new position minted) — see
    /// HardCeilingTriggered/HardFloorTriggered below for the dedicated
    /// events that accompany it instead of the usual mint-related fields.
    event Rebalanced(
        uint256 indexed newTokenId, int24 tickLower, int24 tickUpper, uint256 reinjectedAmount, uint256 consumedUncounted
    );
    event KeeperGasReimbursed(uint256 amountUsd, uint256 gasUsed, uint256 effectiveGasPrice);
    event LpFeesPaidToOwner(uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event PerformanceFeeCollected(uint256 amount0, uint256 amount1);
    event Withdrawn(uint256 amount0, uint256 amount1, uint256 principalUsd);
    /// @notice `consumedUncounted`, same meaning as Rebalanced's — shared by
    /// increasePosition() and increasePositionWithToken(). `volatileFoldedUsd`
    /// volatile top-up actually got folded into the mint this same call (0
    /// when no volatile top-up was involved) — see this contract's own class
    /// docstring, item 3, for why this can never double-count pre-existing
    /// dust.
    event PositionIncreased(
        uint256 usdtAmount, uint256 used0, uint256 used1, uint256 consumedUncounted, uint256 volatileFoldedUsd
    );
    event ReinjectedIntoPosition(uint256 amount, uint256 used0, uint256 used1);
    /// @notice `consumedUncounted`, same meaning as Rebalanced's.
    event IdleDustSwept(uint256 used0, uint256 used1, uint256 consumedUncounted);
    event OperatorUpdated(address newOperator);
    event RiskParamsUpdated(uint256 maxSlippageBps, uint256 minRebalanceInterval, uint256 maxRangeDeviationBps);
    event PausedSet(bool isPaused);
    event EmergencyWithdraw(uint256 amount0, uint256 amount1, uint256 principalUsd);
    event Closed();
    event AutoCompoundFeesSet(bool enabled);
    event FeesReinjected(uint256 netFee0, uint256 netFee1, uint256 used0, uint256 used1, uint256 netFeeUsd);
    event PayoutFeesInStableOnlySet(bool enabled);
    event HardCeilingSet(bool enabled, int24 tick);
    /// @notice Emitted instead of Rebalanced when the hard ceiling triggers a
    /// close-and-park-in-stable exit. `stableAmount` is the vault's
    /// resulting investableUsdt right after (raw stable-decimal units) — the
    /// capital isn't paid out, it stays in the vault, retrievable via
    /// withdraw()/withdrawAll() same as any other idle investable balance.
    event HardCeilingTriggered(uint256 stableAmount);
    event HardFloorSet(bool enabled, int24 tick, bool convertToStable);
    /// @notice Emitted instead of Rebalanced when the hard floor triggers a
    /// close-and-pause exit. `stableAmount` mirrors HardCeilingTriggered's
    /// own field — the resulting investableUsdt right after (only reflects
    /// the STABLE leg; if hardFloorConvertToStable is false, any volatile leg
    /// sits as raw balance instead, retrievable via the dust bucket in
    /// withdraw()).
    event HardFloorTriggered(uint256 stableAmount);
    event B1SeedSet(uint256 seedRaw);
    event PositionRescued(uint256 tokenId);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator && !isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier notClosed() {
        if (closed) revert VaultClosed();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Called once by AutoRangeVaultFactoryV1 right after cloning.
    function initialize(
        address _owner,
        address _platformConfig,
        address _pool,
        address _token0,
        address _token1,
        bool _stableIsToken0,
        uint24 _feeTier,
        address _positionManager,
        address _swapRouter,
        address _gasPriceOracle
    ) external initializer {
        if (
            _owner == address(0) || _platformConfig == address(0) || _pool == address(0)
                || _positionManager == address(0) || _swapRouter == address(0) || _gasPriceOracle == address(0)
        ) {
            revert ZeroAddress();
        }
        __ReentrancyGuard_init();

        owner = _owner;
        platformConfig = _platformConfig;
        pool = IUniswapV3Pool(_pool);
        token0 = _token0;
        token1 = _token1;
        stableIsToken0 = _stableIsToken0;
        feeTier = _feeTier;
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter02(_swapRouter);
        gasPriceOracle = _gasPriceOracle;

        // stable (see _ethUsdFromOracle's /1e20 divisor: wei[18d] ×
        // answer[8d] / 1e18[wei→ETH] × 1e6[USD→stable-6d] / 1e8[feed
        // decimals]) — every stable this project uses today (USDC, USDT0)
        // is 6 decimals. Reverting HERE, at vault creation (cheap, no funds
        // at risk yet) is far safer than a silent runtime mis-scale
        // discovered live in production, the way fix #6 itself was found.
        if (IERC20Metadata(_stableAddr()).decimals() != 6) revert UnsupportedStableDecimals();

        operator = IPlatformConfig(_platformConfig).defaultOperator();

        // contract's own top docstring and AutoRangePlatformConfigV1.operatorPool's
        // docstring). Read once, here, never re-synced later — a wallet
        // added to the pool AFTER this vault already exists only covers
        // vaults created from that point on, same "immutable clone" limit
        // every other per-vault-at-creation field in this project already
        // has. Bounded by the pool's own real size (a handful of keeper
        // wallets), never large enough to risk a gas-limit issue here.
        address[] memory pool = IPlatformConfig(_platformConfig).operatorPool();
        for (uint256 i = 0; i < pool.length; i++) {
            isOperator[pool[i]] = true;
        }

        IERC20(_token0).forceApprove(_positionManager, type(uint256).max);
        IERC20(_token1).forceApprove(_positionManager, type(uint256).max);
        IERC20(_token0).forceApprove(_swapRouter, type(uint256).max);
        IERC20(_token1).forceApprove(_swapRouter, type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Owner: capital + configuration
    // ---------------------------------------------------------------------

    /// @notice Reverts if investableAmount > 0 and a position already
    /// exists — the "invertible" bucket can only ever be funded once, before
    /// initPosition() has run. Use increasePosition() (or
    /// increasePositionWithToken()) afterward instead. reserveAmount/
    /// gasReserveAmount are unaffected — those buckets stay fundable anytime.
    function deposit(uint256 reserveAmount, uint256 investableAmount, uint256 gasReserveAmount)
        external
        onlyOwner
        notClosed
        nonReentrant
    {
        if (positionTokenId != 0 && investableAmount > 0) revert InvestableAfterPositionExists();

        uint256 total = reserveAmount + investableAmount + gasReserveAmount;
        _enforceDepositCap(total, true);

        // capital that's genuinely entering "capital under management" right
        // away. gasReserveAmount never charges (pure keeper-gas budget,
        // never becomes managed capital) and reserveAmount no longer charges
        // HERE either — it charges later, at the moment it's actually
        // reinjected into the position (see _rebalanceCore's reinject
        // block) — same principle B1 accounting already uses for the
        // reserve bucket (see CLAUDE.md's "B1/A1" section: reserve never
        // counts until it's genuinely folded in). _creationFeeFor is now
        uint256 creationFee = _creationFeeFor(investableAmount);
        IERC20(_stableAddr()).safeTransferFrom(msg.sender, address(this), total + creationFee);
        _payCreationFee(creationFee);

        _creditDepositLedgers(investableAmount, reserveAmount, gasReserveAmount);
    }

    /// @notice Depósito flexible, generalizado sobre _stableAddr()/_volatileAddr()
    /// en vez de asumir token0==stable. `tokenIn == _volatileAddr()`: swapIx
    /// vende el excedente o compra el faltante contra el rango objetivo, sin
    /// tocar la porción de volátil que ya calza. Cualquier otro token
    /// no-stable: se vende TODO al stable vía el router genérico.
    ///
    /// Vender el excedente PRODUCE stable nuevo — se acredita más abajo vía
    /// reserveAmount/investableAmount/gasReserveAmount, igual que un
    /// deposit() normal. Comprar el faltante, en cambio, GASTA investableUsdt
    /// ya acreditado (mismo capital ledgereado, no dinero nuevo) — hay que
    /// debitarlo explícitamente ANTES del swap, o el ledger terminaría
    /// sobreestimando el respaldo real en exactamente swapIx.amountIn (mismo
    /// tipo de bug de contabilidad que el resto del contrato evita en
    /// _reinjectFees/reinjectIntoPosition zerando investableUsdt primero).
    ///
    /// Same investableAmount-after-first-position restriction as deposit()
    /// above.
    function depositToken(
        address tokenIn,
        uint256 amountIn,
        SwapInstruction calldata swapIx,
        uint24 thirdPartyFee,
        uint256 thirdPartyAmountOutMinimum,
        uint256 reserveAmount,
        uint256 investableAmount,
        uint256 gasReserveAmount
    ) external onlyOwner notClosed nonReentrant {
        if (positionTokenId != 0 && investableAmount > 0) revert InvestableAfterPositionExists();

        // Checked BEFORE any transfer/swap runs (same order deposit() itself
        // uses) — a deposit that's certain to exceed the cap fails fast,
        // instead of spending gas on a transferFrom + swap it's just going to
        // unwind anyway. Doesn't depend on the swap's outcome either way:
        // reserveAmount/investableAmount/gasReserveAmount are caller-supplied,
        // independent of what tokenIn actually converts to.
        uint256 total = reserveAmount + investableAmount + gasReserveAmount;
        _enforceDepositCap(total, true);

        address stableAddr = _stableAddr();
        address volatileAddr = _volatileAddr();
        // snapshot BOTH legs before the transfer, so realValue below is
        // always measured from an actual balance delta, never trusted from
        // the caller-declared `amountIn`. Closes a fee-on-transfer/
        // deflationary-token gap (a token that delivers less than `amountIn`
        // would otherwise let the ledgers credit more than what really
        // arrived) — not exploitable against this project's real tokens
        // (USDC/USDT0/WETH/WBTC/LINK, none fee-on-transfer) and onlyOwner
        // regardless (self-only risk even if it were), but free to close
        // properly rather than leave as a documented assumption.
        uint256 stableBefore = IERC20(stableAddr).balanceOf(address(this));
        uint256 volatileBefore = IERC20(volatileAddr).balanceOf(address(this));

        if (amountIn > 0) IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // per branch. Deliberately NOT a post-SWAP balance-delta measurement
        // for the volatile branch (an earlier version of this fix used one,
        // and had a real hole: in the "buying" branch below, the swap spends
        // PRE-EXISTING investableUsdt to buy MORE volatile — a post-swap
        // volatile-balance delta would count that bought amount as if it
        // were new value, letting an owner launder already-counted capital
        // through a self-swap to fabricate an arbitrarily large fake
        // Deposited event, defeating the entire point of this fix. Found and
        // fixed before deploy via manual audit, not caught by the original
        // test suite). Measuring the volatile delta right here — after the
        // transfer, but strictly BEFORE _executeSwap runs below — sidesteps
        // that hole while still using a real measurement instead of trusting
        // `amountIn` blindly.
        uint256 realValue =
            tokenIn == volatileAddr ? _nativeWeiToStableRaw(IERC20(volatileAddr).balanceOf(address(this)) - volatileBefore) : 0;

        if (tokenIn == volatileAddr) {
            bool sellingVolatile = _sellsVolatileForStable(swapIx);
            if (!sellingVolatile && swapIx.amountIn > 0) {
                investableUsdt -= swapIx.amountIn;
                // This debit spends already-ledgered investableUsdt without
                // distinguishing whether it draws from the counted or
                // uncounted portion — clamp defensively so
                // uncountedInvestable can never end up exceeding
                // investableUsdt (which would later underflow-revert in
                // withdraw()/withdrawAll()). Errs toward undercounting B1 in
                // this specific edge case, never toward a stuck vault.
                if (uncountedInvestable > investableUsdt) uncountedInvestable = investableUsdt;
            }
            _executeSwap(swapIx);
        } else if (tokenIn == stableAddr) {
            // Measured, not trusted — same fee-on-transfer hardening as the
            // volatile branch above. No swap runs in this branch, so the
            // delta is exact and safe (no laundering risk here either way).
            realValue = IERC20(stableAddr).balanceOf(address(this)) - stableBefore;
        } else if (amountIn > 0) {
            _swapThirdPartyToStable(tokenIn, amountIn, thirdPartyFee, thirdPartyAmountOutMinimum, stableAddr);
            // Real swap proceeds, genuinely new — no pre-existing capital is
            // ever touched in this branch, so a post-swap delta is safe here
            // (unlike the volatile-buying branch above).
            realValue = IERC20(stableAddr).balanceOf(address(this)) - stableBefore;
        }

        if (realValue < total) revert DeclaredExceedsRealBalance();

        // deducted from the vault's own resulting stable balance (post-swap)
        // rather than pulled extra — same convention the old flat fee used.
        _payCreationFee(_creationFeeFor(investableAmount));

        _creditDepositLedgers(investableAmount, reserveAmount, gasReserveAmount);
    }

    /// safeTransferFrom, measured before/after — never trusted, same Fix #1
    /// pattern depositToken() already uses). Both legs now pay the tiered
    /// creation fee off the SAME cumulativeFeeableUsd counter — see this
    /// contract's own class docstring, items 3-4.
    ///
    /// `usdtAmount == 0` with `volatileTopUpRaw > 0` is ACCEPTED (doesn't
    /// revert here) but only actually MINTS in the same tx when the
    /// position is CURRENTLY one-sided (100% volatile) at the pool's live
    /// price — for a normal two-sided position, Uniswap's own mint()
    /// reverts on the resulting hard-zero stable side, independent of
    /// anything this contract does (confirmed via a real Foundry test
    /// during development). The frontend is expected to require some
    /// minimal usdtAmount alongside any volatile top-up as a result (see
    /// VaultDetail.tsx's own handleIncreasePosition) — this is NOT a
    /// general-purpose "always works" pure-volatile path, unlike what an
    /// earlier draft of this docstring claimed. The volatile leg's fee is
    /// simply added to the same _payCreationFee(...) transfer
    /// as the stable leg's — same "pull from whatever real stable balance
    /// already exists" convention depositToken()/_rebalanceCore's
    /// reinjection fee already use, not a dedicated swap (an earlier design
    /// used a caller-sized feeSwapIx here; dropped before deploy purely for
    /// EIP-170 bytecode budget — see this file's own class docstring).
    /// Reverts safely (never a stuck vault, just a failed tx to retry with
    /// any small stable top-up) if a pure-volatile call's fee genuinely has
    /// no real stable balance to draw from anywhere in the vault.
    function increasePosition(
        SwapInstruction calldata swapIx,
        uint256 usdtAmount,
        uint256 volatileTopUpRaw,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOwner notClosed nonReentrant {
        if (positionTokenId == 0) revert NoPosition();
        if (usdtAmount == 0 && volatileTopUpRaw == 0) return;

        address volatileAddr = _volatileAddr();
        // increasePositionWithToken() below. Extending this to also value
        // the volatile leg was considered and dropped: real bytecode cost
        // (another _nativeWeiToStableRaw() call inlined here) for a soft
        // cap that a determined owner could already work around by simply
        // EIP-170 margin.
        uint256 preExistingInvestable = _beginIncreasePosition(usdtAmount);

        uint256 feeStable = _creationFeeFor(usdtAmount);
        if (usdtAmount > 0) {
            IERC20(_stableAddr()).safeTransferFrom(msg.sender, address(this), usdtAmount + feeStable);
        }

        uint256 volatileBefore = IERC20(volatileAddr).balanceOf(address(this));
        if (volatileTopUpRaw > 0) IERC20(volatileAddr).safeTransferFrom(msg.sender, address(this), volatileTopUpRaw);
        uint256 realVolatileTopUp = IERC20(volatileAddr).balanceOf(address(this)) - volatileBefore;

        _finishAndEmitIncrease(usdtAmount, realVolatileTopUp, preExistingInvestable, feeStable, swapIx, amount0Min, amount1Min);
    }

    /// @notice Same as increasePosition() but accepts any ERC20 — reuses
    /// depositToken()'s third-party-swap pattern (sell 100% of tokenIn into
    /// the vault's own stable), then feeds the result into the exact same
    /// increaseLiquidity() tail. `tokenIn == the vault's own stable` degrades
    /// to a no-swap passthrough, so this is a strict superset of
    /// increasePosition().
    ///
    /// depositToken() — left un-swapped (never routed through
    /// _swapThirdPartyToStable, whose EXACT router approval would otherwise
    /// get fully consumed and zero out this vault's persistent
    /// type(uint256).max approval forever, see this contract's own class
    /// docstring item 2). The balance sweep in _finishIncreasePosition
    /// folds it into the mint only when the position's live composition
    /// allows it (see that function's own docstring, and
    /// increasePosition()'s, for the same real one-sided-mint constraint —
    /// this is NOT guaranteed "regardless"). Also charges the volatile
    /// leg's tiered creation fee, same convention as increasePosition() —
    /// see that function's own docstring for why there's no dedicated swap
    /// for it.
    function increasePositionWithToken(
        address tokenIn,
        uint256 amountIn,
        uint24 thirdPartyFee,
        uint256 thirdPartyAmountOutMinimum,
        SwapInstruction calldata swapIx,
        uint256 usdtAmount,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOwner notClosed nonReentrant {
        if (positionTokenId == 0) revert NoPosition();
        if (usdtAmount == 0 && amountIn == 0) return;

        address stableAddr = _stableAddr();
        address volatileAddr = _volatileAddr();
        bool isVolatileTopUp = tokenIn == volatileAddr;

        // leg" scope as increasePosition() above (see that function's own
        // comment on why extending it to the volatile leg was dropped).
        uint256 preExistingInvestable = _beginIncreasePosition(usdtAmount);

        // already uses. Only meaningful when tokenIn is the vault's own
        // volatile; realVolatileTopUp stays 0 for any other tokenIn.
        uint256 volatileBefore = isVolatileTopUp ? IERC20(volatileAddr).balanceOf(address(this)) : 0;
        if (amountIn > 0) IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 realVolatileTopUp = isVolatileTopUp ? IERC20(volatileAddr).balanceOf(address(this)) - volatileBefore : 0;

        if (tokenIn != stableAddr && !isVolatileTopUp && amountIn > 0) {
            _swapThirdPartyToStable(tokenIn, amountIn, thirdPartyFee, thirdPartyAmountOutMinimum, stableAddr);
        }

        uint256 feeStable = _creationFeeFor(usdtAmount);

        _finishAndEmitIncrease(usdtAmount, realVolatileTopUp, preExistingInvestable, feeStable, swapIx, amount0Min, amount1Min);
    }

    /// @dev Shared tail of increasePosition()/increasePositionWithToken() —
    /// identical from fee-charging onward in both (only how tokenIn/
    /// volatileTopUpRaw got pulled and feeStable got computed/collected
    /// differs, before this point — see each caller's own body). Factored
    /// contract well over EIP-170's limit before this consolidation — see
    /// this file's own class docstring), no behavior change beyond what's
    /// already documented at each caller.
    ///
    /// `feeVolatile` is simply added to feeStable and paid in the same
    /// _payCreationFee(...) transfer — pulling from whatever real stable
    /// balance the vault already has, same convention depositToken()/
    /// _rebalanceCore's reinjection fee already use (see increasePosition()'s
    /// own docstring for why this isn't a dedicated swap).
    ///
    /// `min(realVolatileTopUp, volatile actually used in this mint)` bounds
    /// `volatileFoldedUsd` so pre-existing dust already sitting in the vault
    /// (fungible, indistinguishable from this call's own top-up by balance
    /// alone) can never be double-counted — see this contract's own class
    /// docstring, item 3.
    ///
    /// of) THIS call's own `realVolatileTopUp` for stable — the mechanism
    /// that lets a 100%-volatile top-up still mint on both legs even when
    /// the position is currently two-sided, since `_executeSwap` below runs
    /// on the vault's own token0/token1 via the persistent max approval
    /// from initialize(), never the exact-approval path Fix #1 protects —
    /// that sold slice's USD value is already charged via `feeStable`
    /// (`usdtAmount` is expected to reflect the swap's own proceeds, same
    /// caller-declared-cap convention `usdtAmount` already has everywhere
    /// else in this function). Charging `feeVolatile` on the FULL
    /// `realVolatileTopUp` on top of that would double-charge the sold
    /// closed here. `volatileSoldRaw` is bounded by `realVolatileTopUp`
    /// itself, so a sale that happens to also touch pre-existing volatile
    /// dust can only ever UNDER-charge the volatile leg's fee, never
    /// over-charge — same safe-direction convention as everywhere else in
    /// this contract.
    function _finishIncreasePosition(
        uint256 usdtAmount,
        uint256 realVolatileTopUp,
        uint256 preExistingInvestable,
        uint256 feeStable,
        SwapInstruction calldata swapIx,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 used0, uint256 used1, uint256 consumedUncounted, uint256 volatileFoldedUsd) {
        uint256 volatileSoldRaw =
            _sellsVolatileForStable(swapIx) ? (swapIx.amountIn < realVolatileTopUp ? swapIx.amountIn : realVolatileTopUp) : 0;
        uint256 feeVolatile = _creationFeeFor(_nativeWeiToStableRaw(realVolatileTopUp - volatileSoldRaw));

        // Found during a pre-deploy audit ("audita que cada función que
        // incremente algún contador también tenga la de decrementarlo" —
        // same standing instruction that caught a real bug elsewhere in
        // this file's ledger bookkeeping): _executeSwap() must run BEFORE
        // _payCreationFee(), not after. On a lean vault (little/no idle
        // stable sitting in reserveBalance/gasReserveBalance/investableUsdt
        // — the realistic case for a 100%-volatile top-up, exactly the
        // scenario this fee-on-a-pure-volatile-call feature exists for),
        // swapIx is the ONLY source of the stable needed to pay
        // feeVolatile — paying first means _payCreationFee's plain
        // safeTransfer reverts with
        // "ERC20: transfer amount exceeds balance" on a genuinely
        // well-formed call, even though the swap right after would have
        // produced more than enough. Confirmed live with a dedicated test
        // before this fix (a real vault, 5 ETH contributed, 2.5 ETH sold,
        // reverted every time) and confirmed fixed after (same call
        // succeeds). Executing the swap first only ever ADDS to what's
        // available to pay from — never removes anything that was already
        // there — so this is strictly safer for every other caller too
        // (increasePosition()'s mixed top-up, any third-party-token sale),
        // not just the new pure-volatile case.
        _executeSwap(swapIx);
        _payCreationFee(feeStable + feeVolatile);

        (uint256 stableBal, uint256 volatileBal) = _measureAvailable(preExistingInvestable, 0);
        if (stableBal > usdtAmount) stableBal = usdtAmount;
        (uint256 amount0, uint256 amount1) = _toToken01(stableBal, volatileBal);

        // Increment by the MEASURED amount that actually arrived (stableBal),
        // never the caller-declared usdtAmount — see uncountedInvestable's
        // own docstring for why the distinction matters.
        uncountedInvestable += stableBal;

        (used0, used1) = _increaseLiquidity(amount0, amount1, amount0Min, amount1Min);

        consumedUncounted = _foldCapitalAndClamp(preExistingInvestable, stableBal, _stableOf(used0, used1));

        if (realVolatileTopUp > 0) {
            uint256 volatileUsedInMint = stableIsToken0 ? used1 : used0;
            uint256 volatileCountedRaw = realVolatileTopUp < volatileUsedInMint ? realVolatileTopUp : volatileUsedInMint;
            volatileFoldedUsd = _nativeWeiToStableRaw(volatileCountedRaw);
        }
    }

    function configureTarget(
        uint256 investmentAmountUsd,
        int24 _targetTickLower,
        int24 _targetTickUpper,
        uint256 _maxRebalances,
        uint256 _reinjectionAmount,
        uint256 _periodicRebalanceInterval,
        uint256 _recenterMarginBps,
        uint256 _exitTopCeilingMarginBps,
        uint256 _feeClaimThresholdBps,
        uint256 _feeClaimIntervalSeconds,
        uint256 _exitTopRecenterMarginBps
    ) external onlyOwner notClosed {
        targetTickLower = _targetTickLower;
        targetTickUpper = _targetTickUpper;
        maxRebalances = _maxRebalances;
        reinjectionAmount = _reinjectionAmount;
        periodicRebalanceInterval = _periodicRebalanceInterval;
        recenterMarginBps = _recenterMarginBps;
        exitTopCeilingMarginBps = _exitTopCeilingMarginBps;
        feeClaimThresholdBps = _feeClaimThresholdBps;
        feeClaimIntervalSeconds = _feeClaimIntervalSeconds;
        exitTopRecenterMarginBps = _exitTopRecenterMarginBps;
        targetConfigured = true;

        emit TargetConfigured(
            investmentAmountUsd,
            _targetTickLower,
            _targetTickUpper,
            _maxRebalances,
            _reinjectionAmount,
            _periodicRebalanceInterval,
            _recenterMarginBps,
            _exitTopCeilingMarginBps,
            _feeClaimThresholdBps,
            _feeClaimIntervalSeconds,
            _exitTopRecenterMarginBps
        );
    }

    /// never enforced on-chain (see this file's own class docstring, item 2,
    /// reverted before deploy).
    function setRiskParams(uint256 _maxSlippageBps, uint256 _minRebalanceInterval, uint256 _maxRangeDeviationBps)
        external
        onlyOwner
        notClosed
    {
        maxSlippageBps = _maxSlippageBps;
        minRebalanceInterval = _minRebalanceInterval;
        maxRangeDeviationBps = _maxRangeDeviationBps;
        emit RiskParamsUpdated(_maxSlippageBps, _minRebalanceInterval, _maxRangeDeviationBps);
    }

    /// silently lock out every onlyOperator entrypoint (all automated
    /// rebalancing) until the owner corrects it. Self-inflicted and
    /// recoverable either way, but pointless to allow.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
        emit OperatorUpdated(newOperator);
    }

    /// on top of `operator` above (never touched by this — use
    /// setOperator() for that). One function instead of an add/remove pair
    /// (bytecode discipline, same reasoning as every other merged setter in
    /// this project — see setRiskParams above for the same shape). No
    /// zero-address guard: an accidental setOperatorStatus(address(0), true)
    /// is inert (address(0) can never be msg.sender), same reasoning as
    /// AutoRangePlatformConfigV1.setOperatorPool()'s own comment. pause() (below)
    /// remains the real all-operators kill switch regardless of how many
    /// addresses are currently authorized.
    function setOperatorStatus(address a, bool authorized) external onlyOwner {
        isOperator[a] = authorized;
        emit OperatorStatusUpdated(a, authorized);
    }

    /// bytecode-discipline reasoning as setOperatorStatus() above.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function setAutoCompoundFees(bool enabled) external onlyOwner notClosed {
        autoCompoundFees = enabled;
        emit AutoCompoundFeesSet(enabled);
    }

    /// @notice Settable regardless of autoCompoundFees's current value (see
    /// this field's own docstring above for why) — only actually changes
    /// behavior while autoCompoundFees is false.
    function setPayoutFeesInStableOnly(bool enabled) external onlyOwner notClosed {
        payoutFeesInStableOnly = enabled;
        emit PayoutFeesInStableOnlySet(enabled);
    }

    /// setHardFloor() — a higher tick means a HIGHER price when
    /// stableIsToken0 is false, but a LOWER price when stableIsToken0 is true
    /// (same gotcha documented on hardCeilingTick/_hardStopTriggered() below
    /// — never compare these two ticks directly anywhere else). Returns true
    /// iff the ceiling's price is genuinely above the floor's price.
    function _hardStopOrderValid(int24 ceilingTick, int24 floorTick) internal view returns (bool) {
        return stableIsToken0 ? ceilingTick < floorTick : ceilingTick > floorTick;
    }

    /// @notice `tick` is only meaningful while `enabled` is true — see
    /// enabling a ceiling that would sit on the wrong side of an already-
    /// enabled floor (direction-aware, see _hardStopOrderValid()).
    /// @notice TEMP EXPERIMENT — merged setHardCeiling/setHardFloor to
    /// measure bytecode impact. `isCeiling=true` ignores convertToStable
    /// (ceiling always converts).
    function setHardStop(bool isCeiling, bool enabled, int24 tick, bool convertToStable) external onlyOwner notClosed {
        if (isCeiling) {
            if (enabled && hardFloorEnabled && !_hardStopOrderValid(tick, hardFloorTick)) revert InvalidHardStopOrder();
            hardCeilingEnabled = enabled;
            hardCeilingTick = tick;
            emit HardCeilingSet(enabled, tick);
        } else {
            if (enabled && hardCeilingEnabled && !_hardStopOrderValid(hardCeilingTick, tick)) revert InvalidHardStopOrder();
            hardFloorEnabled = enabled;
            hardFloorTick = tick;
            hardFloorConvertToStable = convertToStable;
            emit HardFloorSet(enabled, tick, convertToStable);
        }
    }

    /// @notice No gate beyond onlyOwner — purely informational, moves no
    /// funds, same risk profile as every other config setter here.
    function setB1Seed(uint256 seedRaw) external onlyOwner notClosed {
        b1SeedRaw = seedRaw;
        emit B1SeedSet(seedRaw);
    }

    /// emergencyWithdrawPosition() all share the same decreaseLiquidity()+
    /// collect() path against positionManager; if that path ever breaks for
    /// a reason this vault can't route around, the owner can still pull the
    /// raw NFT out directly and manage it from their own wallet. Deliberately
    /// skips ALL of this vault's internal accounting (no fee split, no ledger
    /// updates, no B1 event) — the tradeoff is losing the platform's
    /// performance fee on whatever's inside the position at that moment,
    /// accepted as the price of a genuine last resort. No whenNotPaused, same
    /// reasoning as withdraw()/withdrawAll() — the owner must always be able
    /// to retrieve their own assets regardless of pause state.
    ///
    /// Uses the RAW transferFrom, not safeTransferFrom — found during the
    /// pre-deploy audit: safeTransferFrom reverts if `owner` is a contract
    /// without onERC721Received (confirmed live against a real EIP-7702-
    /// delegated address on an Arbitrum fork during this same audit), which
    /// would make this "last resort" itself blockable for exactly the kind
    /// of wallet most likely to need it. Same "never depend on something
    /// that can fail for reasons outside the vault's control" principle
    /// emergencyWithdrawPosition() already uses for its own swap-free design.
    function rescuePosition() external onlyOwner nonReentrant {
        if (positionTokenId == 0) revert NoPosition();
        uint256 tokenId = positionTokenId;
        positionTokenId = 0;
        paused = true;
        positionManager.transferFrom(address(this), owner, tokenId);
        emit PositionRescued(tokenId);
    }

    // ---------------------------------------------------------------------
    // Operator: build the initial position
    // ---------------------------------------------------------------------

    function initPosition(SwapInstruction calldata swapIx, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOperator
        whenNotPaused
        notClosed
        nonReentrant
        returns (uint256 tokenId)
    {
        uint256 gasStart = gasleft();

        if (positionTokenId != 0) revert AlreadyInitializedPosition();
        if (!targetConfigured) revert TargetNotConfigured();
        _checkRangeNearMarket(targetTickLower, targetTickUpper);

        uint256 investable = investableUsdt;
        investableUsdt = 0;

        _executeSwap(swapIx);

        (uint256 stableBal, uint256 volatileBal) = _measureAvailable(0, 0);
        if (stableBal > investable) {
            stableBal = investable;
        }
        (uint256 amount0, uint256 amount1) = _toToken01(stableBal, volatileBal);

        uint256 used0;
        uint256 used1;
        (tokenId, used0, used1) =
            _mintPosition(targetTickLower, targetTickUpper, amount0, amount1, amount0Min, amount1Min);

        positionTokenId = tokenId;
        lastRebalanceTimestamp = block.timestamp;

        (uint256 swept0, uint256 swept1) = _sweepDustIntoPosition(tokenId, amount0 - used0, amount1 - used1);

        investableUsdt = stableBal - _stableOf(used0, used1) - _stableOf(swept0, swept1);
        if (uncountedInvestable > investableUsdt) uncountedInvestable = investableUsdt;

        _reimburseKeeperGas(gasStart);

        emit PositionInitialized(tokenId, used0 + swept0, used1 + swept1);
    }

    // ---------------------------------------------------------------------
    // Operator: rebalance
    // ---------------------------------------------------------------------

    /// @notice `feePayoutSwapIx` is dual-purpose (mutually exclusive uses, so
    /// one param covers both): (a) normal case, non-compounding,
    /// payoutFeesInStableOnly enabled — sizes the fee's volatile-leg-to-stable
    /// conversion. (b) hard-ceiling/hard-floor-triggered case — sizes the
    /// FULL close-out-to-stable conversion (principal + fees combined)
    /// instead. `swapIx` (existing) is untouched — still only for the new
    /// mint's own balancing swap, never runs at all in the triggered case
    /// since no new mint happens there.
    function rebalance(
        int24 newTickLower,
        int24 newTickUpper,
        SwapInstruction calldata swapIx,
        SwapInstruction calldata feePayoutSwapIx,
        uint256 reinjectAmount,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOperator whenNotPaused notClosed nonReentrant returns (uint256 newTokenId) {
        uint256 gasStart = gasleft();

        if (positionTokenId == 0) revert NoPosition();
        if (rebalanceCount >= maxRebalances) revert RebalanceLimitReached();

        bool periodicDue = periodicRebalanceInterval != 0
            && block.timestamp >= lastRebalanceTimestamp + periodicRebalanceInterval;
        bool cooldownPassed = block.timestamp >= lastRebalanceTimestamp + minRebalanceInterval;
        if (!cooldownPassed) revert TooSoonToRebalance();
        if (!periodicDue && !_isOutOfRange()) revert TooSoonToRebalance();

        newTokenId =
            _rebalanceCore(newTickLower, newTickUpper, swapIx, feePayoutSwapIx, reinjectAmount, amount0Min, amount1Min);

        _reimburseKeeperGas(gasStart);
    }

    // ---------------------------------------------------------------------
    // Owner: force a rebalance on demand
    // ---------------------------------------------------------------------

    /// @notice Same effect as rebalance(), but the owner triggers it
    /// directly — no need to wait for the operator's next cycle to pick up
    /// a config change (recenterMarginBps, periodicRebalanceInterval, etc.).
    /// The new range still has to come from uni-lab.xyz's real calculation
    /// (computed off-chain, same as for rebalance()) — this function never
    /// derives newTickLower/newTickUpper itself, same as rebalance().
    /// Deliberately skips rebalance()'s periodicDue/_isOutOfRange() gate:
    /// the owner is choosing this is worth doing, not the keeper's automated
    /// heuristic — but the cooldown and rebalanceCount cap still apply, so
    /// this can't be spammed or used to exceed the owner's own configured
    /// limit. No _reimburseKeeperGas() — the owner pays their own gas
    /// directly, same reasoning as collectFees() (owner, no reimbursement)
    /// vs. harvestFees() (operator, reimbursed). Same feePayoutSwapIx
    /// dual-purpose param and hard-ceiling/hard-floor handling as rebalance()
    /// — see that function's own docstring.
    function ownerRebalance(
        int24 newTickLower,
        int24 newTickUpper,
        SwapInstruction calldata swapIx,
        SwapInstruction calldata feePayoutSwapIx,
        uint256 reinjectAmount,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOwner whenNotPaused notClosed nonReentrant returns (uint256 newTokenId) {
        if (positionTokenId == 0) revert NoPosition();
        if (rebalanceCount >= maxRebalances) revert RebalanceLimitReached();

        bool cooldownPassed = block.timestamp >= lastRebalanceTimestamp + minRebalanceInterval;
        if (!cooldownPassed) revert TooSoonToRebalance();

        newTokenId =
            _rebalanceCore(newTickLower, newTickUpper, swapIx, feePayoutSwapIx, reinjectAmount, amount0Min, amount1Min);
    }

    /// @notice Platform-operator equivalent of ownerRebalance() (inherited
    /// rebalance() enforces, but callable by the OPERATOR (the platform's
    /// the platform's own schedule rather than the owner's.
    ///
    /// Deliberately does NOT check rebalanceCount >= maxRebalances (unlike
    /// both rebalance() and ownerRebalance()) — this is a platform-wide
    /// lever, not something a per-vault owner-configured cap should
    /// constrain. Since _rebalanceCore() unconditionally bumps
    /// rebalanceCount by exactly 1 regardless of caller, that bump is
    /// cancelled right after the call (always safe — it can only ever have
    /// gone up by 1), and this path's own activity is tracked separately via
    /// forceRebalanceCount instead. This keeps the owner's own budget
    /// (rebalanceCount vs. maxRebalances) fully decoupled from platform
    /// action — an owner who set maxRebalances=20 still gets 20 of their
    /// own rebalance()/ownerRebalance() cycles, unaffected by how many times
    /// the platform separately force-rebalanced this vault.
    ///
    /// Cooldown is its own, dedicated gate (lastForceRebalanceTimestamp +
    /// PlatformConfig.forceRebalanceCooldownSeconds(), read live so the
    /// platform owner can retune it without a redeploy) — never
    /// minRebalanceInterval, which the vault's OWNER controls and could zero
    /// out for their own ownerRebalance() without meaning to also strip
    /// protection from this platform-level path.
    ///
    /// _reimburseKeeperGas() runs, same as rebalance() — this is a real
    /// operator-sent transaction, paid from this vault's own
    /// gasReserveBalance same as any other operator action.
    function operatorForceRebalance(
        int24 newTickLower,
        int24 newTickUpper,
        SwapInstruction calldata swapIx,
        SwapInstruction calldata feePayoutSwapIx,
        uint256 reinjectAmount,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOperator whenNotPaused notClosed nonReentrant returns (uint256 newTokenId) {
        uint256 gasStart = gasleft();

        if (positionTokenId == 0) revert NoPosition();
        uint256 cooldown = IPlatformConfig(platformConfig).forceRebalanceCooldownSeconds();
        if (block.timestamp < lastForceRebalanceTimestamp + cooldown) revert TooSoonToRebalance();

        newTokenId =
            _rebalanceCore(newTickLower, newTickUpper, swapIx, feePayoutSwapIx, reinjectAmount, amount0Min, amount1Min);

        lastForceRebalanceTimestamp = block.timestamp;
        rebalanceCount -= 1;
        forceRebalanceCount += 1;

        _reimburseKeeperGas(gasStart);
    }

    /// @dev Extracted from _rebalanceCore()/_withdrawPositionShare()/
    /// _closePositionRaw() — the decreaseLiquidity()+collect() pair was
    /// Factored out purely to keep bytecode down, no behavior change from
    /// having it inline at any of the 3 call sites.
    function _decreaseAndCollect(uint256 tokenId, uint128 liquidityToRemove, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256 removed0, uint256 removed1, uint256 collected0, uint256 collected1)
    {
        if (liquidityToRemove > 0) {
            (removed0, removed1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp
                })
            );
        }
        (collected0, collected1) = _collectAll(tokenId);
    }

    /// mint an identical MintParams struct, differing only in which range
    /// (targetTick*/newTick*) and token id they use. Factored out purely to
    /// keep bytecode down, no behavior change.
    function _mintPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 tokenId, uint256 used0, uint256 used1) {
        (tokenId,, used0, used1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: feeTier,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// shape (against positionTokenId, current-block deadline) was duplicated
    /// 4 times (_increaseLiquidityAndAccount, reinjectIntoPosition,
    /// sweepIdleDust, _reinjectFees). Factored out purely to keep bytecode
    /// down, no behavior change. Deliberately NOT reused by
    /// _sweepDustIntoPosition(), which needs the try/catch wrapper around the
    /// raw call and hardcoded 0,0 mins — different enough shape that sharing
    /// would cost more than it saves.
    function _increaseLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256 used0, uint256 used1)
    {
        (, used0, used1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionTokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
    }

    /// destructure, keeping only `liquidity`, was duplicated 3 times
    /// (_rebalanceCore, _withdrawPositionShare, _closePositionRaw).
    /// Factored out purely to keep bytecode down, no behavior change.
    /// Deliberately NOT reused by _isOutOfRange(), which needs
    /// tickLower/tickUpper from the same call too — different enough shape
    /// that sharing would cost more than it saves.
    function _currentLiquidity() internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(positionTokenId);
    }

    /// tokenId" (amount0Max/amount1Max both type(uint128).max) was
    /// duplicated identically 3 times (_rebalanceCore, collectFees,
    /// harvestFees). Factored out purely to keep bytecode down, no behavior
    /// change.
    function _collectAll(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// live position, then split off the platform's performance-fee cut"
    /// was duplicated identically in collectFees() and harvestFees().
    /// Factored out purely to keep bytecode down, no behavior change.
    function _collectAllAndSplitFee() internal returns (uint256 amount0, uint256 amount1) {
        (uint256 collected0, uint256 collected1) = _collectAll(positionTokenId);
        (amount0, amount1) = _splitPerformanceFee(collected0, collected1);
    }

    /// what this fold-in used, set investableUsdt to whatever's left over
    /// (plus any pre-existing balance), then clamp uncountedInvestable so it
    /// can never exceed investableUsdt" was duplicated identically 3 times
    /// (_increaseLiquidityAndAccount, _rebalanceCore, reinjectIntoPosition).
    /// Factored out purely to keep bytecode down, no behavior change —
    /// `preExistingInvestable` is 0 at the 2 call sites that don't have one.
    function _foldCapitalAndClamp(uint256 preExistingInvestable, uint256 stableBal, uint256 foldedIn)
        internal
        returns (uint256 consumedUncounted)
    {
        consumedUncounted = foldedIn < uncountedInvestable ? foldedIn : uncountedInvestable;
        uncountedInvestable -= consumedUncounted;
        investableUsdt = preExistingInvestable + (stableBal - foldedIn);
        if (uncountedInvestable > investableUsdt) uncountedInvestable = investableUsdt;
    }

    /// plus whatever's left of stableBal after folding in used0/used1, then
    /// clamp uncountedInvestable" (the smaller variant, without touching
    /// uncountedInvestable's own subtraction — these 2 call sites never
    /// added to uncountedInvestable in the first place) was duplicated
    /// identically in increasePosition() and increasePositionWithToken().
    /// Factored out purely to keep bytecode down, no behavior change.
    function _setInvestableAndClamp(uint256 preExistingInvestable, uint256 stableBal, uint256 usedStable) internal {
        investableUsdt = preExistingInvestable + (stableBal - usedStable);
        if (uncountedInvestable > investableUsdt) uncountedInvestable = investableUsdt;
    }

    /// @dev Shared body of rebalance()/ownerRebalance() — everything past
    /// each function's own gate check (periodicDue/_isOutOfRange() for the
    /// former, none for the latter) is identical between them: the hard-
    /// ceiling/hard-floor check, decrease+collect, fee handling, the mint
    /// swap, optional reserve reinjection, the new mint, dust sweep, and
    /// ledger update. Factored out purely to keep this contract's deployed
    /// bytecode under EIP-170's 24576-byte limit (same discipline every
    /// prior version already established). No behavior change from inlining
    /// this into each caller — gas reimbursement (rebalance()-only) and
    /// rebalanceCount/lastRebalanceTimestamp bookkeeping in the triggered
    /// branch stay exactly where they were.
    function _rebalanceCore(
        int24 newTickLower,
        int24 newTickUpper,
        SwapInstruction calldata swapIx,
        SwapInstruction calldata feePayoutSwapIx,
        uint256 reinjectAmount,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 newTokenId) {
        (bool aboveCeiling, bool belowFloor) = _hardStopTriggered();
        bool shouldClose = aboveCeiling || belowFloor;
        if (!shouldClose) _checkRangeNearMarket(newTickLower, newTickUpper);

        uint128 liquidity = _currentLiquidity();
        (uint256 removed0, uint256 removed1, uint256 collected0, uint256 collected1) =
            _decreaseAndCollect(positionTokenId, liquidity, 0, 0);

        if (shouldClose) {
            // Deducts the platform's cut from the fee portion only (same as
            // always), everything else (principal + net fees) stays in the
            // vault's own balance and gets handled by _closePositionAndPause
            // below — nothing pays out to the owner here, this is a
            // rebalance outcome, not a withdrawal. The owner retrieves it
            // later via withdraw()/withdrawAll(), same as any idle
            // investable balance (or, for a no-swap floor exit, via the dust
            // bucket).
            _splitPerformanceFee(collected0 - removed0, collected1 - removed1);
            // Ceiling always converts 100% to stable; floor's conversion is
            // the owner's own choice (hardFloorConvertToStable).
            bool convertToStable = aboveCeiling || hardFloorConvertToStable;
            _closePositionAndPause(convertToStable, feePayoutSwapIx);
            rebalanceCount += 1;
            lastRebalanceTimestamp = block.timestamp;
            if (aboveCeiling) {
                emit HardCeilingTriggered(investableUsdt);
            } else {
                emit HardFloorTriggered(investableUsdt);
            }
            return 0;
        }

        uint256 lpFee0 = collected0 - removed0;
        uint256 lpFee1 = collected1 - removed1;
        (uint256 netFee0, uint256 netFee1) = _splitPerformanceFee(lpFee0, lpFee1);
        if (autoCompoundFees) {
            if (netFee0 > 0 || netFee1 > 0) {
                lastFeeClaimTimestamp = block.timestamp;
                emit FeesReinjected(netFee0, netFee1, 0, 0, _toStableUsd(netFee0, netFee1));
            }
        } else {
            if (payoutFeesInStableOnly) (netFee0, netFee1) = _convertPayoutToStable(netFee0, netFee1, feePayoutSwapIx);
            _payFeesToOwner(netFee0, netFee1);
        }

        _executeSwap(swapIx);

        if (reinjectAmount > 0) {
            if (reinjectAmount > reinjectionAmount) revert ReinjectionExceedsCap();
            if (reinjectAmount > reserveBalance) revert InsufficientReserve();
            reserveBalance -= reinjectAmount;

            // deposit time anymore (see deposit()/depositToken()); it
            // charges HERE instead, cut directly from the reinjected amount
            // itself (same "cut while passing through" pattern
            // _splitPerformanceFee already uses elsewhere in this contract),
            // not pulled as an extra transfer — there's no new inbound
            // transfer in this code path to pull from. The mint below
            // receives the net amount; reserveBalance was already debited
            // the GROSS amount above, matching how much left the reserve
            // the exact same call shape.
            uint256 reinjectFee = _creationFeeFor(reinjectAmount);
            _payCreationFee(reinjectFee);
            reinjectAmount -= reinjectFee;
        }

        (uint256 stableBal, uint256 volatileBal) = _measureAvailable(0, 0);
        (uint256 amount0, uint256 amount1) = _toToken01(stableBal, volatileBal);

        uint256 used0;
        uint256 used1;
        (newTokenId, used0, used1) = _mintPosition(newTickLower, newTickUpper, amount0, amount1, amount0Min, amount1Min);

        positionTokenId = newTokenId;

        (uint256 swept0, uint256 swept1) = _sweepDustIntoPosition(newTokenId, amount0 - used0, amount1 - used1);

        uint256 foldedInStable = _stableOf(used0, used1) + _stableOf(swept0, swept1);
        uint256 consumedUncounted = _foldCapitalAndClamp(0, stableBal, foldedInStable);

        rebalanceCount += 1;
        lastRebalanceTimestamp = block.timestamp;

        emit Rebalanced(newTokenId, newTickLower, newTickUpper, reinjectAmount, consumedUncounted);
    }

    function reinjectIntoPosition(
        SwapInstruction calldata swapIx,
        uint256 amount,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOperator whenNotPaused notClosed nonReentrant {
        uint256 gasStart = gasleft();

        if (positionTokenId == 0) revert NoPosition();
        if (amount == 0) return;
        if (amount > reinjectionAmount) revert ReinjectionExceedsCap();
        if (amount > reserveBalance) revert InsufficientReserve();

        reserveBalance -= amount;

        uint256 preExistingInvestable = investableUsdt;
        investableUsdt = 0;

        _executeSwap(swapIx);

        (uint256 stableBal, uint256 volatileBal) = _measureAvailable(preExistingInvestable, 0);
        if (stableBal > amount) stableBal = amount;
        (uint256 amount0, uint256 amount1) = _toToken01(stableBal, volatileBal);

        (uint256 used0, uint256 used1) = _increaseLiquidity(amount0, amount1, amount0Min, amount1Min);

        _setInvestableAndClamp(preExistingInvestable, stableBal, _stableOf(used0, used1));

        _reimburseKeeperGas(gasStart);

        emit ReinjectedIntoPosition(amount, used0, used1);
    }

    /// @notice Reclamo programado de comisiones — ver RangeVaultCompound.sol.
    /// Reembolsa gas al keeper igual que el resto de entrypoints operator-only
    /// que el keeper envía como su propia transacción. Sigue requiriendo
    /// autoCompoundFees == true (harvestFees() never pays out directly to the
    /// owner, so payoutFeesInStableOnly has no bearing here).
    function harvestFees(SwapInstruction calldata swapIx, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOperator
        whenNotPaused
        notClosed
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 gasStart = gasleft();

        if (positionTokenId == 0) revert NoPosition();
        if (!autoCompoundFees) revert AutoCompoundNotEnabled();

        (amount0, amount1) = _collectAllAndSplitFee();

        _reinjectFees(amount0, amount1, swapIx, amount0Min, amount1Min, 0, 0);

        _reimburseKeeperGas(gasStart);
    }

    function sweepIdleDust(SwapInstruction calldata swapIx, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOperator
        whenNotPaused
        notClosed
        nonReentrant
    {
        uint256 gasStart = gasleft();

        if (positionTokenId == 0) revert NoPosition();

        _executeSwap(swapIx);

        (uint256 stableBal, uint256 volatileBal) = _measureAvailable(0, 0);
        (uint256 amount0, uint256 amount1) = _toToken01(stableBal, volatileBal);

        (uint256 used0, uint256 used1) = _increaseLiquidity(amount0, amount1, amount0Min, amount1Min);

        uint256 consumedUncounted = _foldCapitalAndClamp(0, stableBal, _stableOf(used0, used1));

        _reimburseKeeperGas(gasStart);

        emit IdleDustSwept(used0, used1, consumedUncounted);
    }

    // ---------------------------------------------------------------------
    // Owner: collect fees — trading fees only, principal untouched
    // ---------------------------------------------------------------------

    /// @notice `feePayoutSwapIx` — only consumed in the non-compounding
    /// branch when payoutFeesInStableOnly is enabled; a no-op (amountIn == 0)
    /// otherwise, same convention as every other SwapInstruction param in
    /// this contract.
    function collectFees(SwapInstruction calldata swapIx, SwapInstruction calldata feePayoutSwapIx, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (positionTokenId == 0) revert NoPosition();

        (amount0, amount1) = _collectAllAndSplitFee();

        if (autoCompoundFees) {
            _reinjectFees(amount0, amount1, swapIx, amount0Min, amount1Min, 0, 0);
        } else {
            if (payoutFeesInStableOnly) (amount0, amount1) = _convertPayoutToStable(amount0, amount1, feePayoutSwapIx);
            _payOwner(amount0, amount1);
            lastFeeClaimTimestamp = block.timestamp;
            emit FeesCollected(amount0, amount1);
        }
    }

    // ---------------------------------------------------------------------
    // Owner: withdraw — the only path principal can ever leave the vault
    // ---------------------------------------------------------------------

    /// @notice The 4 ledger buckets are fully independent. Layered behavior:
    ///   - Partial exit (positionShareBps < 10_000) with autoCompoundFees on:
    ///     fees reinject into the REMAINING position via `feeSwapIx` — pure
    ///     principal (no fees mixed in) is what reaches amount0/amount1.
    ///   - Partial exit with autoCompoundFees off: fees pay out directly,
    ///     optionally converted to stable first if payoutFeesInStableOnly is
    ///     on (`feeSwapIx` sized for that), tracked in their own
    ///     LpFeesPaidToOwner event — never merged into amount0/amount1.
    ///   - Full close (positionShareBps == 10_000): no remaining position to
    ///     reinject into either way — fees pay out merged with principal,
    ///     still respecting payoutFeesInStableOnly (intent-based: from the
    ///     owner's perspective a full close is indistinguishable from any
    ///     other direct fee payout).
    ///   - `payoutSwapIx` always runs LAST, on whatever total0/total1 end up
    ///     being after the branch above resolves — works identically
    ///     regardless of autoCompoundFees's state, since it only ever sees
    ///     pure principal (when compounding is on) or principal+fees (when
    ///     off), never double-converts what feeSwapIx already touched.
    ///   - `dustAmount0`/`dustAmount1` optionally sweep raw token0/token1
    ///     balance sitting in the vault unaccounted for by any of the 4
    ///     ledgers (a swap that didn't fold in exactly) — see
    ///     _availableDust() below. Never counted toward B1 either way.
    function withdraw(
        uint256 positionShareBps,
        uint256 investableShareBps,
        uint256 reserveShareBps,
        uint256 gasReserveShareBps,
        uint256 dustAmount0,
        uint256 dustAmount1,
        SwapInstruction calldata feeSwapIx,
        SwapInstruction calldata payoutSwapIx,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyOwner nonReentrant {
        if (
            positionShareBps > 10_000 || investableShareBps > 10_000 || reserveShareBps > 10_000
                || gasReserveShareBps > 10_000
        ) revert InvalidShareBps();
        // A dust-only withdrawal (all 4 shares at 0) is a valid request too,
        // so the "at least one thing requested" gate must also accept
        // dustAmount0/dustAmount1 alone.
        if (
            positionShareBps == 0 && investableShareBps == 0 && reserveShareBps == 0 && gasReserveShareBps == 0
                && dustAmount0 == 0 && dustAmount1 == 0
        ) revert InvalidShareBps();

        uint256 amount0;
        uint256 amount1;
        // Principal removed from the position — SEPARATE from amount0/amount1
        // above, which also fold in the owner's fee share in the full-close
        // case only (partial-exit-plus-compounding never merges them at
        // all). Fees never counted toward B1, so principalUsd below must be
        // computed from these, never from amount0/amount1 directly.
        uint256 removedPrincipal0;
        uint256 removedPrincipal1;

        if (positionShareBps > 0 && positionTokenId != 0) {
            (amount0, amount1, removedPrincipal0, removedPrincipal1) =
                _withdrawPositionShare(positionShareBps, feeSwapIx, amount0Min, amount1Min);
        }

        uint256 investableShare = (investableUsdt * investableShareBps) / 10_000;
        uint256 reserveShare = (reserveBalance * reserveShareBps) / 10_000;
        uint256 gasReserveShare = (gasReserveBalance * gasReserveShareBps) / 10_000;
        investableUsdt -= investableShare;
        reserveBalance -= reserveShare;
        gasReserveBalance -= gasReserveShare;

        // investableShare itself can be a mix of already-counted capital and
        // still-uncounted pending top-ups (see uncountedInvestable's own
        // docstring) — the slice proportional to investableShareBps shrinks
        // uncountedInvestable the same way the position/reserve/gas shares
        // above shrink their own ledgers, and principalUsd must exclude the
        // uncounted portion (can't subtract from B1 what was never added).
        uint256 uncountedShare = (uncountedInvestable * investableShareBps) / 10_000;
        uncountedInvestable -= uncountedShare;

        // Deliberately excludes fees (never in B1), reserveShare/
        // gasReserveShare (reserve only ever counts in B1 at the moment it's
        // REINJECTED — withdrawing it un-reinjected is withdrawing capital
        // that was never added to B1 in the first place, so it can't
        // subtract from it either), and uncountedShare (same reasoning,
        // applied to the investable leg).
        uint256 principalUsd = _toStableUsd(removedPrincipal0, removedPrincipal1) + (investableShare - uncountedShare);

        (uint256 ledger0, uint256 ledger1) = _toToken01(investableShare + reserveShare + gasReserveShare, 0);
        uint256 total0 = amount0 + ledger0;
        uint256 total1 = amount1 + ledger1;

        // Dust bucket, sized against what's genuinely unaccounted for AFTER
        // this call's own claims (total0/total1) and whatever ledger balance
        // remains for later withdrawals.
        (uint256 dust0, uint256 dust1) = _availableDust(total0, total1);
        if (dustAmount0 > dust0 || dustAmount1 > dust1) revert InvalidDustAmount();
        total0 += dustAmount0;
        total1 += dustAmount1;

        // Per-call "todo en stable", owner-sized, runs last, over whatever
        // this specific withdrawal ends up paying out.
        (total0, total1) = _convertPayoutToStable(total0, total1, payoutSwapIx);

        _payOwner(total0, total1);

        emit Withdrawn(total0, total1, principalUsd);
    }

    /// @notice How much of the vault's raw token0/token1 balance is
    /// genuinely unaccounted for: not part of `claimed0`/`claimed1` (this
    /// withdrawal's own position + ledger shares, already computed by the
    /// caller) and not part of whatever ledger balance REMAINS in the vault
    /// for future withdrawals (investableUsdt/reserveBalance/
    /// gasReserveBalance, read here AFTER withdraw() already decremented
    /// them by this call's shares). Whatever's left over is stray dust — a
    /// swap that didn't fold in exactly on a prior mint/increaseLiquidity(),
    /// or the natural leftover of a no-swap hard-floor exit.
    function _availableDust(uint256 claimed0, uint256 claimed1) internal view returns (uint256 dust0, uint256 dust1) {
        (uint256 remainingLedger0, uint256 remainingLedger1) =
            _toToken01(investableUsdt + reserveBalance + gasReserveBalance, 0);
        uint256 rawBal0 = IERC20(token0).balanceOf(address(this));
        uint256 rawBal1 = IERC20(token1).balanceOf(address(this));
        uint256 accounted0 = claimed0 + remainingLedger0;
        uint256 accounted1 = claimed1 + remainingLedger1;
        dust0 = rawBal0 > accounted0 ? rawBal0 - accounted0 : 0;
        dust1 = rawBal1 > accounted1 ? rawBal1 - accounted1 : 0;
    }

    /// @dev Extracted from withdraw() purely to keep local-variable count
    /// under control (stack-too-deep risk with 8 params + this much local
    /// state) — no behavior difference from having it inline. Returns
    /// amount0/amount1/removedPrincipal0/removedPrincipal1 — the caller MUST
    /// capture all four from the call site, Solidity doesn't mutate a
    /// value-type argument in place.
    function _withdrawPositionShare(
        uint256 positionShareBps,
        SwapInstruction calldata feeSwapIx,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 amount0, uint256 amount1, uint256 removedPrincipal0, uint256 removedPrincipal1) {
        uint128 partialLiquidity = uint128((uint256(_currentLiquidity()) * positionShareBps) / 10_000);
        (uint256 removed0, uint256 removed1, uint256 collected0, uint256 collected1) =
            _decreaseAndCollect(positionTokenId, partialLiquidity, 0, 0);
        (uint256 netFee0, uint256 netFee1) = _splitPerformanceFee(collected0 - removed0, collected1 - removed1);
        removedPrincipal0 = removed0;
        removedPrincipal1 = removed1;

        bool fullClose = positionShareBps == 10_000;
        // Shared by the full-close and non-compounding-partial branches below
        // (hoisted purely to keep bytecode down, same call either way) — NOT
        // applied in the autoCompoundFees-reinject branch, which never
        // converts anything.
        if ((fullClose || !autoCompoundFees) && payoutFeesInStableOnly) {
            (netFee0, netFee1) = _convertPayoutToStable(netFee0, netFee1, feeSwapIx);
        }

        if (fullClose) {
            positionTokenId = 0;
            // Full close — no remaining position to reinject into regardless
            // of autoCompoundFees; fees merge with principal, still
            // respecting payoutFeesInStableOnly (intent-based — see this
            // function's own docstring).
            amount0 = removed0 + netFee0;
            amount1 = removed1 + netFee1;
        } else if (autoCompoundFees) {
            // Fees reinject into the position that's staying open; the owner
            // receives pure principal only. removed0/removed1 must be
            // excluded from _reinjectFees()'s own balance measurement —
            // decreaseLiquidity() above already deposited them into the
            // vault's raw balance too, see _reinjectFees()'s own docstring.
            _reinjectFees(
                netFee0, netFee1, feeSwapIx, amount0Min, amount1Min, _stableOf(removed0, removed1),
                stableIsToken0 ? removed1 : removed0
            );
            amount0 = removed0;
            amount1 = removed1;
        } else {
            _payFeesToOwner(netFee0, netFee1);
            amount0 = removed0;
            amount1 = removed1;
        }
    }

    function withdrawAll(SwapInstruction calldata feeSwapIx, SwapInstruction calldata payoutSwapIx)
        external
        onlyOwner
        nonReentrant
    {
        (uint256 removed0, uint256 removed1, uint256 netFee0, uint256 netFee1) = _closePositionRaw();
        // Fees aren't tracked separately here (everything sweeps out
        // undifferentiated below) — if the preference is on, just convert
        // them in place; the stable proceeds land in the vault's own balance
        // and get swept out regardless of currency by the balanceOf reads
        // inside _sweepLedgersAndPrincipalUsd below.
        if (payoutFeesInStableOnly) _convertPayoutToStable(netFee0, netFee1, feeSwapIx);

        (uint256 principalUsd, uint256 amount0, uint256 amount1) = _sweepLedgersAndPrincipalUsd(removed0, removed1);

        // Owner-sized "todo en stable" over the full sweep.
        (amount0, amount1) = _convertPayoutToStable(amount0, amount1, payoutSwapIx);

        _payOwner(amount0, amount1);

        emit Withdrawn(amount0, amount1, principalUsd);
    }

    /// excludes any swap dependency entirely (no SwapInstruction param,
    /// ignores payoutFeesInStableOnly). This is the last-resort exit; its
    /// ENTIRE purpose is to work no matter what state the rest of the system
    /// is in. Adding a swap dependency here would reintroduce, in a worse
    /// form, exactly the category of risk this function exists to remove: an
    /// external call (swapRouter.exactInputSingle) that can revert for
    /// reasons entirely outside this vault's control — insufficient pool
    /// liquidity, an unmet amountOutMinimum, the router itself paused. An
    /// owner with payoutFeesInStableOnly enabled will get raw mixed-token
    /// funds specifically from this one call — a deliberate, documented
    /// inconsistency, not an oversight.
    function emergencyWithdrawPosition() external onlyOwner nonReentrant {
        paused = true;
        emit PausedSet(true);

        (uint256 removed0, uint256 removed1,,) = _closePositionRaw();
        (uint256 principalUsd, uint256 amount0, uint256 amount1) = _sweepLedgersAndPrincipalUsd(removed0, removed1);

        _payOwner(amount0, amount1);

        emit EmergencyWithdraw(amount0, amount1, principalUsd);
    }

    /// @dev Shared by withdrawAll()/emergencyWithdrawPosition() — fully
    /// closes whatever position exists (decreaseLiquidity 100% + collect +
    /// _splitPerformanceFee), returns the removed principal and net fee
    /// legs. Callers decide independently what to do with the fee (convert
    /// to stable, or just let it fall into the raw balanceOf sweep below).
    /// Returns all-zero, no-op if there's no open position. Deliberately
    /// keeps decreaseLiquidity()'s amount0Min/amount1Min hardcoded at 0,0 via
    /// _decreaseAndCollect() — same "no swap/slippage dependency, ever"
    /// principle as the rest of this last-resort path.
    function _closePositionRaw() internal returns (uint256 removed0, uint256 removed1, uint256 netFee0, uint256 netFee1) {
        if (positionTokenId == 0) return (0, 0, 0, 0);
        uint256 collected0;
        uint256 collected1;
        (removed0, removed1, collected0, collected1) = _decreaseAndCollect(positionTokenId, _currentLiquidity(), 0, 0);
        (netFee0, netFee1) = _splitPerformanceFee(collected0 - removed0, collected1 - removed1);
        positionTokenId = 0;
    }

    /// @dev Shared by withdrawAll()/emergencyWithdrawPosition() — saturating
    /// subtraction (this principalUsd figure only feeds the audit event, B1
    /// accounting off-chain, and must never be able to block the actual fund
    /// transfer), then zeroes all 4 ledgers and reads the vault's real raw
    /// balance to sweep. Factored out purely to keep bytecode down — no
    /// behavior change.
    function _sweepLedgersAndPrincipalUsd(uint256 removed0, uint256 removed1)
        internal
        returns (uint256 principalUsd, uint256 amount0, uint256 amount1)
    {
        uint256 investableCounted = investableUsdt > uncountedInvestable ? investableUsdt - uncountedInvestable : 0;
        principalUsd = _toStableUsd(removed0, removed1) + investableCounted;

        amount0 = IERC20(token0).balanceOf(address(this));
        amount1 = IERC20(token1).balanceOf(address(this));
        investableUsdt = 0;
        reserveBalance = 0;
        gasReserveBalance = 0;
        uncountedInvestable = 0;
    }

    function closeVault() external onlyOwner {
        if (closed) revert VaultClosed();
        if (
            positionTokenId != 0 || investableUsdt != 0 || reserveBalance != 0 || gasReserveBalance != 0
                || IERC20(token0).balanceOf(address(this)) != 0 || IERC20(token1).balanceOf(address(this)) != 0
        ) {
            revert VaultNotEmpty();
        }
        closed = true;
        emit Closed();
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    uint256 constant GAS_REIMBURSEMENT_OVERHEAD = 40_000;
    /// The Arbitrum ETH/USD Chainlink feed's real heartbeat is 24h — this
    /// constant leaves real margin above that, tightened as needed if the
    /// feed's own heartbeat ever changes.
    uint256 constant MAX_GAS_ORACLE_STALENESS = 90_000;

    function _reimburseKeeperGas(uint256 gasStart) internal {
        uint256 effectiveGasPrice = tx.gasprice < block.basefee * 3 ? tx.gasprice : block.basefee * 3;
        uint256 gasUsed = gasStart - gasleft() + GAS_REIMBURSEMENT_OVERHEAD;
        // VAULT'S OWN POOL price to convert gas cost (always genuinely ETH
        // wei) into stable. Silently correct only when the vault's volatile
        // asset happens to BE the L2's native gas token (WETH) — wrong for
        // any other pair (confirmed live: a WBTC/USDT0 vault computed a
        // ~$8 BILLION "gas cost" this way, draining its entire gas-reserve
        // bucket in a single call). _ethUsdFromOracle uses a dedicated,
        // decoupled Chainlink ETH/USD feed instead — see gasPriceOracle's
        // own docstring.
        uint256 gasCostUsd = _ethUsdFromOracle(gasUsed * effectiveGasPrice);
        uint256 gasReimbursed = gasCostUsd < gasReserveBalance ? gasCostUsd : gasReserveBalance;
        if (gasReimbursed > 0) {
            gasReserveBalance -= gasReimbursed;
            IERC20(_stableAddr()).safeTransfer(operator, gasReimbursed);
            emit KeeperGasReimbursed(gasReimbursed, gasUsed, effectiveGasPrice);
        }
    }

    /// units via gasPriceOracle, a dedicated Chainlink-style ETH/USD feed —
    /// deliberately NOT this vault's own pool (see _reimburseKeeperGas's own
    /// docstring for why that was wrong). Degrades to 0 on ANY failure
    /// (stale, reverting call, non-positive answer) rather than reverting
    /// the real operation this is called from (initPosition/rebalance/
    /// reinjectIntoPosition/harvestFees/sweepIdleDust) — same principle
    /// already established in this codebase: "proteger el capital del owner
    /// gana siempre sobre cobrarle al operador" (see CLAUDE.md's "Visibilidad
    /// de gas agotado"). Worst case here is simply the keeper not getting
    /// reimbursed for this one call, never a stuck vault.
    ///
    /// Formula: wei[18d] × answer[8d] / 1e18[wei→ETH] × 1e6[USD→stable-6d] /
    /// 1e8[feed decimals] = /1e20 — only valid for a 6-decimal stable, which
    /// initialize() already enforces (see UnsupportedStableDecimals).
    function _ethUsdFromOracle(uint256 weiAmount) internal view returns (uint256) {
        try IAggregatorV3(gasPriceOracle).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return 0;
            if (block.timestamp - updatedAt > MAX_GAS_ORACLE_STALENESS) return 0;
            return (weiAmount * uint256(answer)) / 1e20;
        } catch {
            return 0;
        }
    }

    /// @dev Reinyecta fees ya cobradas (post-_splitPerformanceFee) al principal
    /// de la posición abierta — ver RangeVaultCompound.sol para el porqué del
    /// swap mixto (fees llegan en las dos piernas a la vez). Generalizado
    /// sobre _stableAddr()/_volatileAddr()/_toToken01()/_stableOf() como el
    /// resto de esta variante Arbitrum.
    /// @dev `excludeStableExtra`/`excludeVolatileExtra` — additional balance
    /// to treat as "not available for this reinject", beyond the usual
    /// preExistingInvestable/reserveBalance/gasReserveBalance ledgers. Zero
    /// for collectFees()/harvestFees() (the vault's balance at that point
    /// genuinely is only the fee, nothing else). Nonzero for
    /// _withdrawPositionShare()'s compounding-partial-exit branch: that call
    /// site runs AFTER decreaseLiquidity() has already deposited the
    /// REMOVED PRINCIPAL into the vault's raw token balance too — without
    /// this exclusion, this function's balance-delta measurement can't tell
    /// principal and fee apart, sweeps the principal into the reinject
    /// alongside the fee, and then reverts trying to pay the owner an amount
    /// that's already been spent.
    function _reinjectFees(
        uint256 netFee0,
        uint256 netFee1,
        SwapInstruction calldata swapIx,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 excludeStableExtra,
        uint256 excludeVolatileExtra
    ) internal {
        if (netFee0 == 0 && netFee1 == 0) return;

        // Valued from the fee amounts themselves, at the pool's price right
        // now — before _executeSwap below, which only trades one leg for the
        // other at that same price and creates no new value, so computing it
        // here vs. after is equivalent modulo swap slippage/fees (negligible
        // for this accounting figure, same tolerance the rest of the B1/A1
        // design already accepts).
        uint256 netFeeUsd = _toStableUsd(netFee0, netFee1);

        uint256 preExistingInvestable = investableUsdt;
        investableUsdt = 0;

        _executeSwap(swapIx);

        (uint256 stableBal, uint256 volatileBal) =
            _measureAvailable(preExistingInvestable + excludeStableExtra, excludeVolatileExtra);
        (uint256 amount0, uint256 amount1) = _toToken01(stableBal, volatileBal);

        (uint256 used0, uint256 used1) = _increaseLiquidity(amount0, amount1, amount0Min, amount1Min);

        _setInvestableAndClamp(preExistingInvestable, stableBal, _stableOf(used0, used1));

        lastFeeClaimTimestamp = block.timestamp;
        emit FeesReinjected(netFee0, netFee1, used0, used1, netFeeUsd);
    }

    function _splitPerformanceFee(uint256 fee0, uint256 fee1) internal returns (uint256 net0, uint256 net1) {
        uint256 bps = IPlatformConfig(platformConfig).performanceFeeBps();
        uint256 platform0 = (fee0 * bps) / 10_000;
        uint256 platform1 = (fee1 * bps) / 10_000;
        if (platform0 > 0) IERC20(token0).safeTransfer(operator, platform0);
        if (platform1 > 0) IERC20(token1).safeTransfer(operator, platform1);
        if (platform0 > 0 || platform1 > 0) emit PerformanceFeeCollected(platform0, platform1);
        net0 = fee0 - platform0;
        net1 = fee1 - platform1;
    }

    /// token0/token1 to the owner" was duplicated identically across
    /// withdraw(), withdrawAll(), and emergencyWithdrawPosition() (each
    /// emits its own distinct event right after, so only the transfer pair
    /// itself is shared here, not the event). Factored out purely to keep
    /// bytecode down, no behavior change.
    function _payOwner(uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) IERC20(token0).safeTransfer(owner, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(owner, amount1);
    }

    /// then emit LpFeesPaidToOwner" tail was duplicated identically in
    /// _rebalanceCore()'s and _withdrawPositionShare()'s non-compounding
    /// branches. Factored out purely to keep bytecode down, no behavior
    /// change.
    function _payFeesToOwner(uint256 fee0, uint256 fee1) internal {
        _payOwner(fee0, fee1);
        if (fee0 > 0 || fee1 > 0) emit LpFeesPaidToOwner(fee0, fee1);
    }

    function _sweepDustIntoPosition(uint256 tokenId, uint256 leftover0, uint256 leftover1)
        internal
        returns (uint256 swept0, uint256 swept1)
    {
        if (leftover0 == 0 && leftover1 == 0) return (0, 0);
        try positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: leftover0,
                amount1Desired: leftover1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        ) returns (uint128, uint256 used0, uint256 used1) {
            swept0 = used0;
            swept1 = used1;
        } catch {
            swept0 = 0;
            swept1 = 0;
        }
    }

    /// @notice Converts up to swapIx.amountIn of whatever volatile-token leg
    /// is present in (amount0, amount1) into the vault's stable token,
    /// returning the resulting (out0, out1) with the same total economic
    /// value, just re-split toward stable. Shared by both mechanisms: the
    /// persistent payoutFeesInStableOnly preference (collectFees/rebalance/
    /// ownerRebalance's fee-only amounts) and the per-call payoutSwapIx
    /// (withdraw/withdrawAll's principal+fee amounts), plus the hard-ceiling/
    /// hard-floor full close-out. Operates on NET amounts only (post-
    /// _splitPerformanceFee where relevant) — the platform's cut is always
    /// taken first, in the original token split, never touched by this.
    ///
    /// swapIx.amountIn == 0 is a complete no-op (returns the input
    /// unchanged) — same convention as _executeSwap itself, so a caller who
    /// doesn't want any conversion just passes the same inert default used
    /// everywhere else in this contract.
    ///
    /// Deliberately reverts (rather than silently clamping) if
    /// swapIx.amountIn exceeds the volatile amount actually present in THIS
    /// call's (amount0, amount1) — the one place in this contract where a
    /// caller-supplied SwapInstruction gets validated against a hard,
    /// known-in-advance bound, unlike a mint/reinject swap's target amount
    /// (a heuristic, not a fact). Closes off selling volatile balance that
    /// has nothing to do with this specific payout. Under-sizing (amountIn
    /// less than the full volatile leg) degrades gracefully instead —
    /// whatever isn't converted just pays out raw alongside the converted
    /// stable, no revert.
    function _convertPayoutToStable(uint256 amount0, uint256 amount1, SwapInstruction calldata swapIx)
        internal
        returns (uint256 out0, uint256 out1)
    {
        uint256 volatileAmount = stableIsToken0 ? amount1 : amount0;
        if (swapIx.amountIn > volatileAmount) revert InvalidSwapInstruction();
        if (swapIx.amountIn == 0) return (amount0, amount1);

        bool sellsVolatileForStable = _sellsVolatileForStable(swapIx);
        if (!sellsVolatileForStable) revert InvalidSwapInstruction();

        uint256 stableBefore = IERC20(_stableAddr()).balanceOf(address(this));
        _executeSwap(swapIx);
        uint256 stableReceived = IERC20(_stableAddr()).balanceOf(address(this)) - stableBefore;

        uint256 remainingVolatile = volatileAmount - swapIx.amountIn;
        uint256 stableAmount = stableIsToken0 ? amount0 : amount1;
        (out0, out1) = _toToken01(stableAmount + stableReceived, remainingVolatile);
    }

    /// @notice Hard ceiling / hard floor share this exit path — closes the
    /// position and auto-pauses, called from rebalance()/ownerRebalance()
    /// once either trigger has been confirmed and decrease+collect have
    /// already run (the caller passes control here right after).
    /// `convertToStable == false` (only possible via a no-swap floor exit)
    /// leaves any volatile leg as raw, untracked balance — never folded into
    /// investableUsdt (a stable-only ledger) — retrievable via the dust
    /// bucket in withdraw() or withdrawAll()/emergencyWithdrawPosition().
    /// Reuses `paused`/`whenNotPaused` (already blocks initPosition()/
    /// rebalance()) instead of a new flag — this is also what stops
    /// checkVault() (keeper, off-chain) from mistaking positionTokenId == 0
    /// for "brand new vault, needs its first position" and trying to
    /// auto-reopen: initPosition() itself reverts while paused, no
    /// keeper-side change needed. withdraw() has no whenNotPaused gate, so
    /// the owner can always retrieve the parked balance regardless.
    function _closePositionAndPause(bool convertToStable, SwapInstruction calldata exitSwapIx) internal {
        uint256 stableBal = IERC20(_stableAddr()).balanceOf(address(this)) - reserveBalance - gasReserveBalance;

        if (convertToStable) {
            uint256 volatileBal = IERC20(_volatileAddr()).balanceOf(address(this));
            (uint256 exitAmount0, uint256 exitAmount1) = _toToken01(stableBal, volatileBal);
            (exitAmount0, exitAmount1) = _convertPayoutToStable(exitAmount0, exitAmount1, exitSwapIx);
            stableBal = _stableOf(exitAmount0, exitAmount1);
        }

        // Stays inside the vault as investableUsdt — this is a rebalance
        // outcome, not a withdrawal. The owner still owns this capital,
        // retrievable via withdraw()/withdrawAll() same as any other idle
        // investable balance (plus the dust bucket for any raw volatile leg
        // left behind when convertToStable is false).
        investableUsdt = stableBal;
        if (uncountedInvestable > investableUsdt) uncountedInvestable = investableUsdt;

        positionTokenId = 0;
        paused = true;
        emit PausedSet(true);
    }

    /// duplicated 4 times (deposit/depositToken include gasReserveBalance in
    /// currentTotal, increasePosition/increasePositionWithToken don't, since
    /// there's no gas-reserve bucket involved in a top-up to an existing
    /// position). `includeGasReserve` picks the right variant. Factored out
    /// purely to keep bytecode down, no behavior change.
    function _enforceDepositCap(uint256 addedAmount, bool includeGasReserve) internal view {
        uint256 cap = IPlatformConfig(platformConfig).maxDepositUsd();
        uint256 currentTotal = reserveBalance + investableUsdt + (includeGasReserve ? gasReserveBalance : 0);
        if (cap != 0 && currentTotal + addedAmount > cap) revert DepositExceedsPlatformCap();
    }

    /// event was duplicated identically in deposit() and depositToken().
    /// Factored out purely to keep bytecode down, no behavior change.
    function _creditDepositLedgers(uint256 investableAmount, uint256 reserveAmount, uint256 gasReserveAmount) internal {
        reserveBalance += reserveAmount;
        investableUsdt += investableAmount;
        gasReserveBalance += gasReserveAmount;
        emit Deposited(investableAmount, reserveAmount, gasReserveAmount, false);
    }

    /// investableUsdt while stashing its pre-existing value was duplicated
    /// identically in increasePosition() and increasePositionWithToken().
    /// Factored out purely to keep bytecode down, no behavior change.
    function _beginIncreasePosition(uint256 usdtAmount) internal returns (uint256 preExistingInvestable) {
        _enforceDepositCap(usdtAmount, false);
        preExistingInvestable = investableUsdt;
        investableUsdt = 0;
    }

    /// plus its PositionIncreased emit was duplicated identically in
    /// increasePosition() and increasePositionWithToken(). Factored out
    /// purely to keep bytecode down, no behavior change.
    function _finishAndEmitIncrease(
        uint256 usdtAmount,
        uint256 realVolatileTopUp,
        uint256 preExistingInvestable,
        uint256 feeStable,
        SwapInstruction calldata swapIx,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal {
        (uint256 used0, uint256 used1, uint256 consumedUncounted, uint256 volatileFoldedUsd) =
            _finishIncreasePosition(usdtAmount, realVolatileTopUp, preExistingInvestable, feeStable, swapIx, amount0Min, amount1Min);
        emit PositionIncreased(usdtAmount, used0, used1, consumedUncounted, volatileFoldedUsd);
    }

    /// tiered schedule — see this contract's own class docstring, item 1,
    /// for the full product rationale. `cumulativeFeeableUsd` is this
    /// vault's own running total of every fee-eligible dollar ever
    /// contributed (never decremented); `priorTotal`/`newTotal` bracket the
    /// delta THIS call contributes. The one-time flat fee only ever fires
    /// once, exactly when `priorTotal == 0` (this vault's very first
    /// fee-eligible call ever) — guarded by `baseAmount == 0` returning
    /// early so a deposit()/depositToken() call funding ONLY reserve/gas
    /// (investableAmount == 0) can never accidentally burn that one-time
    /// charge on zero real capital. `tier2` (the excess above the
    /// threshold) can never underflow: `newTotal >= priorTotal` always
    /// (baseAmount is added, never subtracted), so `excessAfter >=
    /// excessBefore` always holds too. Reads all 3 knobs (threshold, flat
    /// fee, bps) via ONE packed `creationFeeParams()` call — 2 extra
    /// external calls would each cost real bytecode this contract can't
    ///
    /// Called once per "leg" of a capital-increasing call (see
    /// increasePosition()/increasePositionWithToken() above, which now call
    /// this twice — once for the stable leg, once for the volatile leg) —
    /// since the counter is purely cumulative, two sequential calls give
    /// exactly the same combined total as one call on the summed amount
    /// would, decomposed cleanly per leg, regardless of call order.
    ///
    /// every one of its 5 call sites (deposit, depositToken,
    /// increasePosition, increasePositionWithToken ×2, and
    /// _rebalanceCore's reinject block) is already inside a state-mutating,
    /// non-view function.
    function _creationFeeFor(uint256 baseAmount) internal returns (uint256 fee) {
        if (baseAmount == 0) return 0;

        (uint256 thresholdUsd, uint256 flatUsd, uint256 bps) = IPlatformConfig(platformConfig).creationFeeParams();

        uint256 priorTotal = cumulativeFeeableUsd;

        if (priorTotal == 0 && flatUsd > 0) fee = flatUsd;

        // unchecked: cumulativeFeeableUsd only ever grows by real deposit
        // amounts (USD-cents scale, nowhere near 2^256), and every
        // subtraction below is guarded by the ternary/order it sits next to
        // (newTotal >= priorTotal always) — first use of `unchecked` in this
        // anything else; see this file's own class docstring for the
        // bytecode-budget history.
        uint256 newTotal;
        uint256 tier2;
        unchecked {
            newTotal = priorTotal + baseAmount;
            uint256 excessAfter = newTotal > thresholdUsd ? newTotal - thresholdUsd : 0;
            uint256 excessBefore = priorTotal > thresholdUsd ? priorTotal - thresholdUsd : 0;
            tier2 = excessAfter - excessBefore;
        }
        cumulativeFeeableUsd = newTotal;
        if (tier2 > 0 && bps > 0) fee += (tier2 * bps) / 10_000;
    }

    function _payCreationFee(uint256 fee) internal {
        if (fee > 0) {
            IERC20(_stableAddr()).safeTransfer(IPlatformConfig(platformConfig).treasury(), fee);
            emit CreationFeeCharged(fee);
        }
    }

    /// @notice Shared by depositToken()/increasePositionWithToken() — sells
    /// 100% of a non-stable, non-volatile third-party token into the vault's
    /// own stable token via the generic swapRouter. Factored out purely to
    /// keep bytecode down (identical block in both), no behavior change.
    function _swapThirdPartyToStable(
        address tokenIn,
        uint256 amountIn,
        uint24 fee,
        uint256 amountOutMinimum,
        address stableAddr
    ) internal {
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        _doExactInputSingle(tokenIn, stableAddr, fee, amountIn, amountOutMinimum);
    }

    function _stableAddr() internal view returns (address) {
        return stableIsToken0 ? token0 : token1;
    }

    function _volatileAddr() internal view returns (address) {
        return stableIsToken0 ? token1 : token0;
    }

    function _toToken01(uint256 stableAmt, uint256 volatileAmt) internal view returns (uint256, uint256) {
        return stableIsToken0 ? (stableAmt, volatileAmt) : (volatileAmt, stableAmt);
    }

    function _stableOf(uint256 amount0, uint256 amount1) internal view returns (uint256) {
        return stableIsToken0 ? amount0 : amount1;
    }

    /// swapIx sell the volatile leg for the stable leg" was duplicated
    /// identically in depositToken() and _convertPayoutToStable(); a third,
    /// new use in _finishIncreasePosition() (this version's own fix) made
    /// extracting it worth it, same discipline as every other 1-line helper
    /// already in this file. No behavior change at either existing call site.
    function _sellsVolatileForStable(SwapInstruction calldata swapIx) internal view returns (bool) {
        return stableIsToken0 ? !swapIx.token0ToToken1 : swapIx.token0ToToken1;
    }

    /// is genuinely available right now" measurement that used to be
    /// duplicated, with minor variations, across 6 call sites (initPosition,
    /// _rebalanceCore, reinjectIntoPosition, sweepIdleDust, _reinjectFees,
    /// _increaseLiquidityAndAccount). Needed to claw back the bytecode room
    /// refactor, no behavior change: `extraStableExclude`/
    /// `extraVolatileExclude` are the same additional exclusions each
    /// original call site already subtracted inline (0 where there was none).
    function _measureAvailable(uint256 extraStableExclude, uint256 extraVolatileExclude)
        internal
        view
        returns (uint256 stableBal, uint256 volatileBal)
    {
        stableBal =
            IERC20(_stableAddr()).balanceOf(address(this)) - reserveBalance - gasReserveBalance - extraStableExclude;
        volatileBal = IERC20(_volatileAddr()).balanceOf(address(this)) - extraVolatileExclude;
    }

    function _nativeWeiToStableRaw(uint256 volatileWei) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (stableIsToken0) {
            uint256 step1 = (volatileWei << 96) / sqrtPriceX96;
            return (step1 << 96) / sqrtPriceX96;
        } else {
            uint256 step1 = (volatileWei * sqrtPriceX96) >> 96;
            return (step1 * sqrtPriceX96) >> 96;
        }
    }

    /// @dev Values a pair of real token0/token1 amounts entirely in the
    /// stable leg's raw units, at the pool's CURRENT spot price — the stable
    /// leg passes through unchanged, the volatile leg goes through
    /// _nativeWeiToStableRaw. Shared by every B1 accounting event this
    /// contract emits (FeesReinjected.netFeeUsd, Withdrawn/
    /// EmergencyWithdraw.principalUsd) so both directions — capital entering
    /// the position (reinjection) and capital leaving it (withdrawal) — are
    /// valued the exact same way, at the exact moment each happens.
    function _toStableUsd(uint256 amount0, uint256 amount1) internal view returns (uint256) {
        uint256 stableRaw = _stableOf(amount0, amount1);
        uint256 volatileRaw = stableIsToken0 ? amount1 : amount0;
        return stableRaw + _nativeWeiToStableRaw(volatileRaw);
    }

    function _executeSwap(SwapInstruction calldata swapIx) internal {
        if (swapIx.amountIn == 0) return;
        if (swapIx.fee == 0) revert InvalidSwapInstruction();
        address tokenIn = swapIx.token0ToToken1 ? token0 : token1;
        address tokenOut = swapIx.token0ToToken1 ? token1 : token0;
        _doExactInputSingle(tokenIn, tokenOut, swapIx.fee, swapIx.amountIn, swapIx.amountOutMinimum);
    }

    /// (sqrtPriceLimitX96 always 0, recipient always this vault) was
    /// duplicated identically in _swapThirdPartyToStable() and
    /// _executeSwap() — factored out purely to keep bytecode down.
    /// Deliberately does NOT also own the forceApprove step, which differs
    /// genuinely between the two callers (see this contract's own class
    /// docstring, item 2, on why mixing the exact-approval and
    /// persistent-approval paths is a real bug class, not just a style
    /// choice) — no behavior change at either call site.
    function _doExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum)
        internal
    {
        swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _checkRangeNearMarket(int24 tickLower, int24 tickUpper) internal view {
        (, int24 currentTick,,,,,) = pool.slot0();
        int256 slack = int256(maxRangeDeviationBps);
        int256 lowerBound = int256(tickLower) - slack;
        int256 upperBound = int256(tickUpper) + slack;
        int256 current = int256(currentTick);
        if (current < lowerBound || current > upperBound) revert RangeTooFarFromMarket();
    }

    function _isOutOfRange() internal view returns (bool) {
        (,,,,, int24 posTickLower, int24 posTickUpper, uint128 liquidity,,,,) =
            positionManager.positions(positionTokenId);
        if (liquidity == 0) return true;
        (, int24 currentTick,,,,,) = pool.slot0();
        return currentTick < posTickLower || currentTick > posTickUpper;
    }

    /// @notice Hard ceiling + hard floor, merged into one slot0() read (kept
    /// as 2 separate functions would cost more bytecode) — factored together
    /// purely to keep bytecode down, same discipline as the other shared
    /// helpers in this file. Direction-aware: a higher tick means a HIGHER
    /// price when stableIsToken0 is false (Arbitrum: token0=volatile,
    /// token1=stable — raw price token1/token0 rises with tick, and that raw
    /// price IS the stable-per-volatile price). A higher tick means a LOWER
    /// price when stableIsToken0 is true (Celo: token0=stable — the
    /// stable-per-volatile price is the INVERSE of the raw token1/token0
    /// price, so it falls as tick rises). Same direction logic this
    /// codebase's own off-chain keeper already uses for `floorTick` (see
    /// rebalancer.ts) — mirrored here on-chain rather than trusted from any
    /// caller, since this gate exists specifically so a misbehaving/
    /// compromised operator can't rebalance past the owner's configured
    /// ceiling/floor regardless of what it claims off-chain. The floor's
    /// comparison is the OPPOSITE of the ceiling's — do not copy operators
    /// unchanged between the two. Ceiling takes priority if both somehow
    /// read true in the same block (should be impossible in practice, and
    /// now additionally guarded at config time by _hardStopOrderValid()).
    function _hardStopTriggered() internal view returns (bool aboveCeiling, bool belowFloor) {
        if (!hardCeilingEnabled && !hardFloorEnabled) return (false, false);
        (, int24 currentTick,,,,,) = pool.slot0();
        aboveCeiling =
            hardCeilingEnabled && (stableIsToken0 ? currentTick <= hardCeilingTick : currentTick >= hardCeilingTick);
        belowFloor = !aboveCeiling && hardFloorEnabled
            && (stableIsToken0 ? currentTick >= hardFloorTick : currentTick <= hardFloorTick);
    }

    // ---------------------------------------------------------------------
    // ---------------------------------------------------------------------

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return this.onERC721Received.selector;
    }
}

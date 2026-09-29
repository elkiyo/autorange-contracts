// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AutoRangePlatformConfigV1
/// @notice Platform-wide configuration for AutoRange compound vaults — the
/// default operator wallet, the deposit cap, the performance fee cut, the
/// tiered creation fee, and the platform's own pool of backup operator
/// wallets. Read by AutoRangeVaultFactoryV1 at vault-creation time and by each
/// AutoRangeVaultV1 instance thereafter.
contract AutoRangePlatformConfigV1 is Ownable2Step {
    /// @notice Token `maxDepositUsd` is denominated in.
    address public feeToken;

    /// @notice Default (primary) operator a new vault starts with. See
    /// operatorPool below for the backup-wallet redundancy layer alongside
    /// it.
    address public defaultOperator;

    /// @notice Global cap on total USD a single vault may hold. Zero means "no cap".
    uint256 public maxDepositUsd;

    /// @notice Cut of every LP trading fee the platform takes. Basis points.
    uint256 public performanceFeeBps;

    /// @notice Legacy flat creation fee field, kept for interface parity —
    /// AutoRangeVaultV1 never reads this (it uses the tiered
    /// creationFeeTierThresholdUsd/creationFeeFlatUsd/creationFeeBps
    /// combination via creationFeeParams() instead).
    uint256 public creationFeeUsdt;

    /// @notice Where the creation fee and reinjection-time fee cut land.
    address public treasury;

    /// @notice The tiered creation fee's bracket-2 rate — % charged on
    /// whatever a vault's cumulative fee-eligible capital exceeds
    /// creationFeeTierThresholdUsd. Basis points, e.g. 50 = 0.5%. Zero means
    /// no bracket-2 charge.
    uint256 public creationFeeBps;

    /// @notice The dedicated cooldown AutoRangeVaultV1's
    /// operatorForceRebalance() enforces on itself, independent of each
    /// vault's own minRebalanceInterval.
    uint256 public forceRebalanceCooldownSeconds;

    /// @notice The tiered creation fee's bracket boundary. A vault's
    /// cumulative fee-eligible capital (raw 6-decimal stable units) up to
    /// this amount is charged only the one-time creationFeeFlatUsd; anything
    /// above it is charged creationFeeBps on the excess. Zero degrades the
    /// whole scheme to flat-bps-on-everything.
    uint256 public creationFeeTierThresholdUsd;

    /// @notice The one-time flat fee (raw 6-decimal stable units) charged
    /// exactly once per vault, the first time it ever takes a fee-eligible
    /// deposit, covering its first creationFeeTierThresholdUsd of cumulative
    /// capital. Zero means no flat fee (bracket 1 is free).
    uint256 public creationFeeFlatUsd;

    /// Every wallet in here is authorized (AutoRangeVaultV1's
    /// isOperator mapping) on EVERY new vault at creation time, in addition
    /// to that vault's own single `operator` (still resolved from
    /// defaultOperator above, unchanged). Scope deliberately narrow — this
    /// is redundancy WITHIN the platform's own keeper infrastructure (so a
    /// vault isn't stuck if its assigned wallet is temporarily out of gas or
    /// rate-limited), never third-party agent authorization; explicit
    /// product decision. Existing vaults created before this pool was
    /// populated (or before a wallet was added to it) are unaffected — the
    /// pool is only read once, at AutoRangeVaultV1's own initialize() time,
    /// never re-synced into an already-created vault.
    address[] private _operatorPool;

    event FeeTokenUpdated(address newToken);
    event DefaultOperatorUpdated(address newOperator);
    event MaxDepositUsdUpdated(uint256 newMax);
    event PerformanceFeeBpsUpdated(uint256 newFeeBps);
    event CreationFeeUsdtUpdated(uint256 newFee);
    event CreationFeeBpsUpdated(uint256 newFeeBps);
    event TreasuryUpdated(address newTreasury);
    event ForceRebalanceCooldownSecondsUpdated(uint256 newCooldown);
    event CreationFeeTierThresholdUsdUpdated(uint256 newThresholdUsd);
    event CreationFeeFlatUsdUpdated(uint256 newFlatUsd);
    event OperatorPoolUpdated(address[] newPool);

    /// @notice operatorPool starts empty here — set afterward, if a backup
    /// operator wallet is ever provisioned, via setOperatorPool() below.
    constructor(
        address initialOwner,
        address _feeToken,
        address _defaultOperator,
        uint256 _maxDepositUsd,
        uint256 _performanceFeeBps,
        uint256 _creationFeeUsdt,
        address _treasury
    ) Ownable(initialOwner) {
        require(_feeToken != address(0), "feeToken=0");
        require(_defaultOperator != address(0), "defaultOperator=0");
        require(_performanceFeeBps <= 10_000, "performanceFeeBps>100%");
        require(_treasury != address(0), "treasury=0");
        feeToken = _feeToken;
        defaultOperator = _defaultOperator;
        maxDepositUsd = _maxDepositUsd;
        performanceFeeBps = _performanceFeeBps;
        creationFeeUsdt = _creationFeeUsdt;
        treasury = _treasury;
    }

    function setPerformanceFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 10_000, "performanceFeeBps>100%");
        performanceFeeBps = newFeeBps;
        emit PerformanceFeeBpsUpdated(newFeeBps);
    }

    function setFeeToken(address newToken) external onlyOwner {
        require(newToken != address(0), "feeToken=0");
        feeToken = newToken;
        emit FeeTokenUpdated(newToken);
    }

    function setDefaultOperator(address newOperator) external onlyOwner {
        require(newOperator != address(0), "operator=0");
        defaultOperator = newOperator;
        emit DefaultOperatorUpdated(newOperator);
    }

    function setMaxDepositUsd(uint256 newMax) external onlyOwner {
        maxDepositUsd = newMax;
        emit MaxDepositUsdUpdated(newMax);
    }

    function setCreationFeeUsdt(uint256 newFee) external onlyOwner {
        creationFeeUsdt = newFee;
        emit CreationFeeUsdtUpdated(newFee);
    }

    function setCreationFeeBps(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 10_000, "creationFeeBps>100%");
        creationFeeBps = newFeeBps;
        emit CreationFeeBpsUpdated(newFeeBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "treasury=0");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setForceRebalanceCooldownSeconds(uint256 newCooldown) external onlyOwner {
        forceRebalanceCooldownSeconds = newCooldown;
        emit ForceRebalanceCooldownSecondsUpdated(newCooldown);
    }

    function setCreationFeeTierThresholdUsd(uint256 newThresholdUsd) external onlyOwner {
        creationFeeTierThresholdUsd = newThresholdUsd;
        emit CreationFeeTierThresholdUsdUpdated(newThresholdUsd);
    }

    function setCreationFeeFlatUsd(uint256 newFlatUsd) external onlyOwner {
        creationFeeFlatUsd = newFlatUsd;
        emit CreationFeeFlatUsdUpdated(newFlatUsd);
    }

    /// @notice Replaces the whole pool in one call (not an add/remove pair)
    /// — the platform owner manages its own keeper wallet roster as a set,
    /// re-submitting the full desired list each time. No zero-address check
    /// on individual entries: an accidental address(0) here just wastes one
    /// isOperator[address(0)]=true slot at vault-creation time (address(0)
    /// can never be msg.sender anyway), never a security issue.
    function setOperatorPool(address[] calldata newPool) external onlyOwner {
        _operatorPool = newPool;
        emit OperatorPoolUpdated(newPool);
    }

    function operatorPool() external view returns (address[] memory) {
        return _operatorPool;
    }

    /// @notice Packs the 3 tiered-fee reads AutoRangeVaultV1's
    /// _creationFeeFor() needs into ONE external call instead of 3.
    function creationFeeParams() external view returns (uint256 thresholdUsd, uint256 flatUsd, uint256 bps) {
        return (creationFeeTierThresholdUsd, creationFeeFlatUsd, creationFeeBps);
    }
}

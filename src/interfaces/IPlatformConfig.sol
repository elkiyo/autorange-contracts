// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Read-only view a RangeVault needs from PlatformConfig. Kept as a narrow
/// interface (instead of importing the concrete contract) so RangeVault only depends
/// on the three values it actually reads live on every rebalance.
interface IPlatformConfig {
    function feeToken() external view returns (address);
    function defaultOperator() external view returns (address);
    function maxDepositUsd() external view returns (uint256);
    function performanceFeeBps() external view returns (uint256);
    function creationFeeUsdt() external view returns (uint256);
    /// @notice V4 only — the already-deployed shared PlatformConfig (V1-V3)
    /// predates this field and doesn't have it; V4 vaults point at their own
    /// PlatformConfig instance instead. See RangeVaultArbCompoundV4.sol's
    /// own docstring for why.
    function creationFeeBps() external view returns (uint256);
    function treasury() external view returns (address);
    /// @notice V6 only — same reasoning as creationFeeBps above: the
    /// already-deployed shared PlatformConfig (V1-V5) predates this field;
    /// V6 vaults point at their own fresh PlatformConfig instance instead.
    /// See RangeVaultArbCompoundV6.sol's operatorForceRebalance().
    function forceRebalanceCooldownSeconds() external view returns (uint256);
    /// @notice V7 only — packs the 3 reads RangeVaultArbCompoundV7's
    /// _creationFeeFor() needs (tier threshold, one-time flat fee, bracket-2
    /// bps) into a single external call, for bytecode/gas reasons (V7
    /// needed real structural trimming to fit under EIP-170). Only
    /// PlatformConfigV7 (and later) implements this — same "own fresh
    /// instance" reasoning as creationFeeBps/forceRebalanceCooldownSeconds
    /// above.
    function creationFeeParams() external view returns (uint256 thresholdUsd, uint256 flatUsd, uint256 bps);
    /// @notice V9 only — the platform's own pool of backup operator wallets,
    /// seeded into every new vault's isOperator mapping at creation time
    /// (see RangeVaultArbCompoundV9.sol's initialize()). Only
    /// PlatformConfigV9 (and later) implements this — same "own fresh
    /// instance" reasoning as every other version-gated field above.
    function operatorPool() external view returns (address[] memory);
}

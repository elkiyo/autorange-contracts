# AutoRange Contracts — Official V1 (Arbitrum One)

Smart contracts for [AutoRange](https://autorange.xyz): non-custodial, auto-rebalancing Uniswap V3 vaults.

Anyone can deploy their own isolated vault (an EIP-1167 clone) from the factory. An off-chain keeper rebalances the vault's Uniswap V3 position automatically, but only within guardrails the vault owner sets on-chain. The owner keeps custody the whole time.

## Deployed addresses (Arbitrum One)

| Contract | Address |
|---|---|
| `AutoRangePlatformConfigV1` | [`0xa618111f9627cDc00B0F2329509B0E1EBfAda0c5`](https://arbiscan.io/address/0xa618111f9627cDc00B0F2329509B0E1EBfAda0c5) |
| `AutoRangeVaultFactoryV1` | [`0x288B7d7cD81620977062aa6eEdA2a64D93386502`](https://arbiscan.io/address/0x288B7d7cD81620977062aa6eEdA2a64D93386502) |
| `AutoRangeVaultV1` (implementation) | [`0xB2294bcC9841Ec8E412ef15e2243dBF37c3099BA`](https://arbiscan.io/address/0xB2294bcC9841Ec8E412ef15e2243dBF37c3099BA) |

All three contracts are verified on Arbiscan and immutable. There is no proxy or upgrade path: vaults are minimal clones of a fixed implementation.

## Contracts

- **`src/official/AutoRangeVaultV1.sol`**: one vault holds one Uniswap V3 position.
  - **Roles:** `owner` deposits, withdraws and configures. `operator` (the keeper, or a wallet from the platform's operator pool) can only rebalance, compound fees and sweep dust within the owner's limits.
  - **Guardrails:** max number of rebalances, cooldowns, absolute price ceiling/floor, and re-entry margins.
  - **Money flows:** fees are auto-compounded; deposits can be made with either token of the pair; withdrawals come from multiple buckets.
  - **Owner exits:** emergency exits (`emergencyWithdrawPosition`, `rescuePosition`, `withdrawAll`) never depend on the operator or on the paused state.
  - **Recipients:** no function takes an arbitrary recipient. Tokens can only go to the owner, the operator (gas reimbursement and fees), the treasury, or the pool.
- **`src/official/AutoRangeVaultFactoryV1.sol`**: creates and initializes clones atomically, validates the pool against the canonical Uniswap V3 factory, and charges a tiered creation fee.
- **`src/official/AutoRangePlatformConfigV1.sol`**: platform parameters (default operator, operator pool, fees, treasury, deposit cap), `Ownable2Step`.
- **`src/interfaces/`**: minimal interfaces for Uniswap V3 (NonfungiblePositionManager, SwapRouter02, Factory), Chainlink, and the platform config.

Approximate size: ~1,430 SLOC (`AutoRangeVaultV1.sol`: 1,132).

## Build

Requires [Foundry](https://book.getfoundry.sh/). The dependencies are vendored in `lib/` at the exact versions used for the deployment.

```bash
forge build
```

The compiler settings in `foundry.toml` (solc 0.8.24, `via_ir`, `optimizer_runs = 1`, IPFS metadata hash) are the ones used for the Arbitrum deployment. With them, `forge build` reproduces the deployed runtime bytecode of all three contracts byte for byte, including the metadata hash (the factory differs only in its `immutable` slots, which are set at deployment). That shows this source is exactly the code running on-chain.

## Test

The tests run against a fork of Arbitrum One mainnet, using the real Uniswap V3 pools and contracts with no mocks.

```bash
cp .env.example .env
source .env
forge test -vv
```

- `AutoRangeVaultV1.t.sol` and `AutoRangeVaultV1Audit.t.sol` are fork tests on Arbitrum One. They cover lifecycle, rebalancing, withdrawals, the threat model, invariants, oracle resilience and MEV scenarios.
- `AutoRangeVaultV1StableToken0.t.sol` is a fork test on Ethereum mainnet that exercises the `stableIsToken0 == true` pair orientation with the same contract.
- `AutoRangePlatformConfigV1.t.sol` contains unit tests for the platform config.
- `AutoRangeInterfaceFidelity.t.sol` checks the local interfaces against the real deployed contracts.
- `AutoRangeSymbolic.t.sol` contains symbolic checks for [halmos](https://github.com/a16z/halmos).

## Security

- An internal white-box audit is in [`audit/INTERNAL_AUDIT_V1.md`](audit/INTERNAL_AUDIT_V1.md), written in Spanish. It found 0 critical, high or medium issues and 9 low or informational ones, all documented with their status.
- There is no independent third-party audit yet.
- Any fix to these contracts would ship as a new, separately deployed version, because the V1 contracts cannot be upgraded.

## License

[Business Source License 1.1](LICENSE). The Change Date is 2029-08-02, after which the code is licensed under GPL-2.0-or-later.

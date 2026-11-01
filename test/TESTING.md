# HMR independent tests

Run the complete suite with the verifier's seed:

```sh
FOUNDRY_FUZZ_SEED=0x649597f73accebfcf2f234260f484ceb4fd16d2d5b097a0da410f30dd47889f3 forge build
FOUNDRY_FUZZ_SEED=0x649597f73accebfcf2f234260f484ceb4fd16d2d5b097a0da410f30dd47889f3 forge test
```

During a test-only assignment, `FOUNDRY_OUT=test/scratch/out` and
`FOUNDRY_CACHE_PATH=test/scratch/cache` keep generated artifacts within the allowed paths.
No additional dependencies, FFI, configuration changes, network installation, or broadcasts
are needed. The existing vendored Foundry and OpenZeppelin libraries are used.

## Coverage

| Suite | Checks |
| --- | --- |
| Existing `HamsterMiningReserve.t.sol` and `Deploy.t.sol` | Baseline behavior, deployment, authorization, rewards and fuzz tests retained. |
| `ReserveEdges.t.sol` | Maximum batches, partial-batch rollback, duplicate and already-staked IDs, single-token approval, zero/self/full share transfers, allowances, failed transfer rollback, claim recovery, reward previews, idempotence, cooldown boundaries, ownership handover, absent withdrawal/sweep interfaces. |
| `ReserveDependencies.t.sol` | Failed stake, withdrawal, restake and payout; donor-burn rollback; strict power increase including equal-power rejection; positive-power/zero-share rounding; callback attempts against all eight guarded entry points; arbitrary synthetic higher-level powers and NAV rounding bounds. |
| `invariant/ReserveInvariant.t.sol` | Four actors, 256 sequences of 64 randomized calls; explicit target selectors; fail on unexpected reverts; custody, power, share and reward conservation; recovery and eventual claims after every sequence. |
| `fork/SepoliaFork.t.sol` | Pinned RPC bytecode and NFT ownership reads, GRAPH C facts, real deposit/merge/claim cycle, real L1/L2 power, post-merge NAV, permanent staking custody, unauthorized calls, missing approvals, duplicate batches, level mismatch, same token and immediate repeated-merge failure. |

The additional stateless fuzz properties run 1,000 cases each. Their bounds are generated
directly; they do not discard inputs through `vm.assume`.

## Stateful property design

The five discovery passes use the supplied Pashov fizz and Trail of Bits references as
background. The implementation is original Foundry test code.

| Discovery pass | Grounded property and source | Test oracle |
| --- | --- | --- |
| Conservation | Shares only enter through deposit; payouts only through claim (`src/HamsterMiningReserve.sol:150`, `:382`). | Actor balances equal ghost share balances; supply equals their sum; SQK in staking, vault and recipients equals injected funds; liabilities are backed. |
| State transitions | Merge burns one donor, preserves supply and strictly increases power (`:213`); reserve is permanent. | Track every deposited ID and burned donor independently; inspect actual ERC-721 ownership and staking attribution; assert failed operations roll back. |
| Round trips and rounding | Deposit NAV must not dilute existing shares (`:174`); transfers and repeated claims must not create rewards (`:345`, `:382`). | Cross-product bounds for newly issued shares; zero/self/full transfer cases; idempotent claims; bounded aggregate rounding dust after final claims. NFT redemption is intentionally absent. |
| Adversarial sequences | Authorized strategist only, guarded entry points, settle before balance changes (`:137`, `:345`, `:361`). | Unauthorized and reentrant calls are rejected; failures are injected at each dependency boundary. The broken delayed-reward ownership property is reported separately. |
| Vault and staking properties | NAV grows through merges and deposits; share ownership carries future rewards. | L1 deposits and L1-to-L2 merges give an independently computable power total; healthy-settlement tests retain old rewards with the prior holder. |

The handler mixes deposits, direct/delegated transfers, both claim overloads, reward funding,
direct donations, one-wei accruals, harvest/poke, owner/strategist merges, rejected merges,
unauthorized calls and dependency outages. Ghosts track injected and paid SQK, recipient
receipts, share issuance and transfers, and deposited/burned NFT IDs. All actors start with
shares; a deterministic handler exercise also proves that every action is executable.

The normal invariant campaign includes claim outages and checks conservation and solvency
through them. These are weaker guarantees than correct ownership of delayed rewards.
They do **not** establish that the reported reward reallocation defect is safe.

## Fork reproducibility and limits

The fork suite reads `vm.envOr("SEPOLIA_RPC_URL", string(""))` and passes that value unchanged
to `vm.createSelectFork` at **Sepolia block 12038088**. It accepts Foundry's URL or socket
transport. An empty variable is the only skip condition; connection errors fail. No endpoint
is embedded and there is no latest-block fallback or environment mutation.

`test_fork_pinnedRpcReadsAgreeWithEvm` also sends standard `eth_getCode` and `eth_call`
requests through the active fork's endpoint at that exact block. It compares the bytecode
of all five live graph contracts and the observed NFT owner with the EVM fork. These direct
reads still reach the endpoint when Forge already has cached account or storage data.

NFTs are selected from actual ownership and level reads at the pinned block. Tests impersonate
the real owner only within the local fork, then use the real approvals, transfers, staking,
merging and SQK claim functions. No NFT storage, code or power is replaced on the fork.
The suite checks that claim return values match observed balance changes without assuming a
positive live emission amount. The empty-vault case checks the zero-return path explicitly.

Offline reward amount assertions use exact amounts funded by the test mocks. Higher-level
power tests use arbitrary synthetic powers to test delta-based NAV; they do not claim to
discover or extrapolate live L3-L10 values. The randomized custody campaign uses only L1/L2.

### Diagnosing the reported RPC check failure

The supplied check reported one unsupported `eth_getAccountInfo` call and inferred missing
archive state. Forge's fork backend probes this nonstandard optimization and falls back to
`eth_getBalance`, `eth_getTransactionCount` and `eth_getCode`. The exact dependency used by
Forge 1.8.5 implements that fallback in
[foundry-fork-db](https://github.com/foundry-rs/foundry-core/blob/39c03a49ade2f74a6e97e2af308283a42d78d302/crates/fork-db/src/backend.rs#L397).
An unsupported probe alone does not establish missing archive state.

To independently verify the archive reads and full NFT cycle without Forge's disk state cache:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
FOUNDRY_FUZZ_SEED=0x649597f73accebfcf2f234260f484ceb4fd16d2d5b097a0da410f30dd47889f3 \
forge test --no-storage-caching --match-path test/fork/SepoliaFork.t.sol -vv
```

If the external checker still rejects an otherwise successful run solely for this optional
probe, its RPC compatibility handling needs correction. Tests do not intercept that probe,
replace chain state, or suppress provider failures. The pinned fork and direct RPC checks
must both pass.

## Reported defect

`.imd-findings.json` contains one high-severity finding and its complete self-contained,
offline Foundry reproduction. When staking claims temporarily fail, deposits and transfers
still change share balances, and later recovery indexes previously earned rewards against
those new balances. An equal-power late depositor takes half of a prior holder's 100 SQK;
a full transfer moves all 100 SQK of old rewards to the recipient. Both expected-entitlement
tests were run and failed on the unchanged implementation.

The deliberately failing source is embedded in the report, not in the passing suite. It
permits a fix either to reject the balance mutation during failed settlement or to preserve
the old holder's entitlement while allowing the mutation. No production contract is changed.

# Hamster Mining Reserve (HMR)

A merge-pooling mining **vault** for Squeekchain's v9 Squeek mining NFTs on Sepolia
(chain id 11155111). Depositors hand Squeek NFTs to the vault permanently; the vault stakes
them under its own account, a strategist merges equal-level pairs to raise the vault's mining
power, and every share holder receives SQK rewards pro rata.

`hmSQUEEK` is the vault's **internal share ledger**. It uses the standard transferable-share
(ERC-20) interface purely as bookkeeping so a depositor can exit by transferring shares. The
vault never pre-creates, pools or sells shares; shares exist only against NFTs that were
deposited. This project creates no tradeable asset, pool, pair or supply of its own.

## Layout

| Path | What |
| --- | --- |
| `src/HamsterMiningReserve.sol` | The vault (one deployable contract). |
| `src/interfaces/ISqueekchain.sol` | Minimal Squeekchain v9 interfaces with the selectors used. |
| `script/SepoliaAddresses.sol` | GRAPH C addresses and the launch owner, as constants. |
| `script/Deploy.s.sol` | Reviewable deploy script; `deploy(Config)` is what tests call. |
| `test/HamsterMiningReserve.t.sol` | Offline unit, failure-path, reentrancy and fuzz tests on mocks. |
| `test/fork/SepoliaFork.t.sol` | Integration tests on a Sepolia fork against the live graph. |
| `test/mocks/MockSqueekchain.sol` | Local stand-ins for the graph with failure knobs. |
| `lib/` | Vendored `forge-std` 1.9.7 and OpenZeppelin Contracts 5.1.0 as plain files. |

## Squeekchain GRAPH C (live v9 graph), Sepolia

All five contracts were read directly from the chain on 2026-11-01 (block 12038084). The
vault never calls `api.squeekchain.com`; everything is `eth_call` / transactions on these:

| Role | Address | Checked |
| --- | --- | --- |
| SqueekNFT (Genesis), ERC-721 "Squeek" | `0xCB98349c134aB983dA5BfD80527dfe2552bDB70F` | `MAXIMUM_LEVEL()==10`, `mining()`, `sqkCore()` match |
| Staking / rewards (per-account power) | `0x4b67b739dFd832f4EAC67a7Aa3bc244fB74cea4F` | `genesis()`, `mining()`, `token()` match |
| Emission engine | `0xcd46990f8349057335289Ef282c276204B6CDC62` | `implementationCodeVersion()==9` |
| SqueekCore | `0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44` | `implementationCodeVersion()==3` |
| SQK reward asset (external, read-only) | `0x5501E1Fa81Be1c3F49225fa7668DA0245d07Db60` | 18 decimals, symbol `SQK` |

The staking, emission and core contracts are proxies (EIP-1967 implementation slots are set),
so Squeekchain can upgrade them. The vault therefore reads versions through `graphHealth()` for
monitoring but never gates a call on a version number.

Observed on the fork: staking one L1 adds exactly `1000e18` to `accountPower`; a merged L2 reads
`2200e18`; merging two staked L1s nets `+200e18` and frees one staking slot; `claim` returns 0
when the testnet emission clock is idle; `checkpoint()` is callable by anyone.

## How the vault works

### Deposit

`deposit(uint256[] tokenIds)` (1 to 50 ids per call):

1. Settles rewards (see below) so earlier holders keep everything accrued so far.
2. Pulls each NFT from the caller with `transferFrom` (caller must own them and have called
   `setApprovalForAll(vault, true)` on the NFT).
3. Stakes them under the vault's own account in the staking contract.
4. Reads the vault's `accountPower` before and after. Mints shares at NAV:
   - first deposit: `shares = deltaPower`
   - later: `shares = deltaPower * totalShares / powerBefore` (rounded down, in favour of existing holders)

Because `deltaPower` is measured, not hard-coded, L2+ NFTs and future curve levels are priced
correctly without any table in the contract. A deposit that adds no power reverts.

Unsolicited `safeTransferFrom` of a Squeek to the vault is rejected by `onERC721Received`; the
only way in is `deposit`.

### Merge

`mergeStep(survivor, donor)` (strategist or owner): both tokens must be held and the same level.
The vault withdraws the pair from staking, calls `SqueekNFT.merge(survivor, donor)` (donor burned,
survivor +1 level), re-stakes the survivor and **reverts unless total power strictly increased**.
Share supply is untouched, so the gain accrues to every holder through a higher power-per-share.
The NFT's per-token merge cooldown (about 3000 core-blocks) is enforced by the NFT itself; a
blocked merge reverts atomically and leaves both tokens staked.

### Rewards

`harvest()` (alias `poke()`), callable by anyone and never reverting on the Squeekchain side:

1. `emission.checkpoint()` in a `try`; failure is logged as `CheckpointFailed`.
2. `staking.claim(vault)` in a `try`; failure is logged as `ClaimFailed`.
3. Any SQK in the vault above `accountedBalance` is added to `rewardIndex` per share.

The same settle runs **before every balance change**: every `deposit`, `transfer`,
`transferFrom` and `claimRewards` settles first and syncs both parties, so nobody can buy or
mint shares and pick up SQK that accrued before them. `claimRewards()` / `claimRewards(to)` pays
a holder's pro-rata SQK and returns 0 cleanly when nothing accrued. `pendingRewards(holder)`
previews a claim including SQK the staking contract still reports as claimable.

Reward amounts are deliberately **not** asserted anywhere: Sepolia emission may pay 0 per round.

### Permanent reserve

There is no NFT withdrawal for anyone, depositor or owner. Exit is by transferring shares, which
carry the future reward stream with them. There is no rescue or sweep function either.

## Roles and trust assumptions

| Role | Powers | Default |
| --- | --- | --- |
| Owner (`Ownable2Step`) | `setStrategist`, two-step ownership transfer, may call `mergeStep` | launch owner `0x2BBAD01F50EAE735F95050b62E3a7d0c4Cf8f6Ca` |
| Strategist | `mergeStep` only; cannot move NFTs or SQK out | the owner, until `setStrategist` is called |
| Anyone | `deposit`, `harvest`/`poke`, `claimRewards`, share transfers | |

The strategist cannot lose funds: a merge either strictly raises power or reverts, and nothing
ever leaves the vault except SQK to its rightful claimant. A malicious or idle strategist can
only fail to merge. The owner has no access to NFTs or SQK.

Outside dependencies the vault trusts: the Squeekchain NFT, staking, emission and core proxies
(upgradeable by Squeekchain, unverified on Sepolia), and SQK as a plain 18-decimal ERC-20. If the
staking contract ever paid a fee-on-transfer or rebasing asset the balance-delta accounting still
holds. If Squeekchain pauses or breaks `checkpoint`/`claim`, deposits, transfers and claims of
already-received SQK keep working.

## Constants chosen here

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_DEPOSIT_BATCH` | 50 | Bounds staking gas per deposit. |
| `INDEX_PRECISION` | 1e27 | Per-share index precision; no overflow for any realistic SQK supply. |
| Share name / symbol / decimals | "Hamster Mining Reserve Share" / `hmSQUEEK` / 18 | Internal ledger metadata, fixed in the constructor. |

## Deployment parameters

`HamsterMiningReserve(owner, nft, staking, emission, core, rewardToken)`:

| Argument | Sepolia value |
| --- | --- |
| `owner_` | `$owner` = `0x2BBAD01F50EAE735F95050b62E3a7d0c4Cf8f6Ca` |
| `nft_` | `0xCB98349c134aB983dA5BfD80527dfe2552bDB70F` |
| `staking_` | `0x4b67b739dFd832f4EAC67a7Aa3bc244fB74cea4F` |
| `emission_` | `0xcd46990f8349057335289Ef282c276204B6CDC62` |
| `core_` | `0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44` |
| `rewardToken_` | `0x5501E1Fa81Be1c3F49225fa7668DA0245d07Db60` |

The constructor makes no external calls (it is rehearsed on an empty chain); every outside
contract is checked on first use. `forge script script/Deploy.s.sol --rpc-url <sepolia> --broadcast`
with the operator's own signer reproduces the same deployment; the script reads no environment
variables and `run()` refuses any chain other than Sepolia.

## After launch (operational responsibilities)

1. **Verify the wiring**: call `graphHealth()`; expect `(10, 9, 3, true, true, true, true, true)`.
2. **Optionally appoint a strategist**: owner calls `setStrategist(address)`. Until then the
   owner is the strategist. The strategist is expected to run `mergeStep` whenever two held
   Squeeks share a level and are past cooldown; `isHeld(id)` and `SqueekNFT.level(id)` tell
   which pairs qualify.
3. **Keep rewards flowing**: anyone can call `harvest()`; a keeper should call it at least once
   per emission round so `rewardIndex` tracks emission. Depositors and transfers settle on
   their own, so a missed harvest delays but never misallocates rewards.
4. **Depositors**: `SqueekNFT.setApprovalForAll(vault, true)` then `deposit([ids])`.
   `claimRewards()` for SQK, or transfer `hmSQUEEK` to exit.
5. **Monitoring**: `emissionStatus()` mirrors `checkpointStatus()`; `CheckpointFailed` /
   `ClaimFailed` events flag a paused or broken graph.
6. **Explorer verification** of the deployed source and a separate adversarial review are the
   deployer's, not this task's. Tests passing are not an audit.

## Building and testing

```
forge build
forge test
forge fmt --check
```

Compiler is pinned to `solc = "0.8.26"` with `bytecode_hash = "none"`; `ffi` is off and no
`fs_permissions` are granted. Dependencies are vendored under `lib/`, so the build needs no
network.

Fuzz tests were run with the verifier's seed
`FOUNDRY_FUZZ_SEED=0x649597f73accebfcf2f234260f484ceb4fd16d2d5b097a0da410f30dd47889f3`.

### Fork tests

`test/fork/SepoliaFork.t.sol` forks `https://ethereum-sepolia-rpc.publicnode.com` at block
12038095 (falling back to the latest block if the pinned one is not served) and runs the full
deposit → merge → claim cycle with real Squeeks owned by `0x598958Abf7d8DB8Dd468cb53DD6BA705581bFf54`
(tokens 1-10 at level 1 at that block). When no RPC is reachable the ten on-chain tests are
reported as **skipped**, not failed; the offline suite carries the behavioural coverage. If the
holder later merges or moves those tokens, update `HOLDER` in the test.

Last local run: 44 offline tests, 2 deploy tests and 11 fork tests passed.

## What is not included

- No website. The optional static site was left out; a future one must read live stats from
  the deployed vault (`totalPower`, `totalSupply`, `heldCount`, `powerPerShare`,
  `pendingRewards`) and the v9 graph, with no backend key and no fabricated data.
- No deployment or broadcast was performed by this task; the launch deploys from the built
  bytecode with the parameters above.

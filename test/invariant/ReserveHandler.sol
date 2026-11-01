// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {MockSQK, MockSqueekNFT, MockEmission, MockStaking} from "../mocks/MockSqueekchain.sol";

/// @dev Closed actor universe, explicit ghost custody and cash flows. No storage writes to the vault.
/// Deposits and successful merges use only the observed L1/L2 curve. Higher synthetic levels
/// are covered separately in ReserveDependenciesTest. Failed claims are deliberately reachable:
/// while SQK is claimable for the vault and the claim fails, every share balance change must be
/// refused (`RewardsUnsettled`), and an independent per-holder entitlement oracle checks that
/// delayed rewards still go to the holders of record when they accrued.
contract ReserveHandler is Test {
    HamsterMiningReserve public immutable vault;
    MockSQK public immutable sqk;
    MockSqueekNFT public immutable nft;
    MockStaking public immutable staking;
    MockEmission public immutable emission;
    address public immutable strategist;
    address[4] public actors;

    uint256[] public depositedIds;
    uint256[] internal unmergedL1;
    mapping(uint256 => bool) public burned;
    mapping(address => uint256) public expectedShares;
    mapping(address => uint256) public expectedReceipts;
    uint256 public depositedCount;
    uint256 public mergedCount;
    uint256 public sharesMinted;
    uint256 public rewardsInjected;
    uint256 public rewardsPaid;
    uint256 public actions;
    uint256 public lastIndex;
    uint256 public successfulDeposits;
    uint256 public successfulTransfers;
    uint256 public successfulClaims;
    uint256 public successfulMerges;
    uint256 public rejectedMerges;
    uint256 public rejectedUnauthorized;
    uint256 public frozenRejections;
    uint256 public strandedStakes;
    /// @dev SQK each holder is owed, computed from balances at the moment the SQK reached the
    ///      staking contract or the vault. Independent of the vault's index arithmetic.
    mapping(address => uint256) public entitled;
    /// @dev SQK each holder has claimed (to any recipient).
    mapping(address => uint256) public claimedBy;

    constructor(
        HamsterMiningReserve v,
        MockSQK t,
        MockSqueekNFT n,
        MockStaking s,
        MockEmission e,
        address strategist_
    ) {
        vault = v;
        sqk = t;
        nft = n;
        staking = s;
        emission = e;
        strategist = strategist_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("invariant actor ", vm.toString(i)));
        }
    }

    /// @dev True exactly when `_settle` would return false in the mock graph: the claim reverts
    ///      while SQK is still claimable for the vault.
    function frozen() public view returns (bool) {
        return staking.revertOnClaim() && staking.claimable(address(vault)) != 0;
    }

    function _credit(uint256 amount) internal {
        uint256 supply = vault.totalSupply();
        if (supply == 0 || amount == 0) return;
        for (uint256 i; i < 4; ++i) {
            entitled[actors[i]] += (amount * vault.balanceOf(actors[i])) / supply;
        }
    }

    modifier observed() {
        _;
        ++actions;
        uint256 index = vault.rewardIndex();
        assertGe(index, lastIndex, "reward index must never decrease");
        lastIndex = index;
    }

    function deposit(uint256 actorSeed, uint256 countSeed) public observed {
        address actor = actors[actorSeed % 4];
        uint256 count = bound(countSeed, 1, 4);
        uint256 first = nft.mint(actor, count);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = first + i;
        }
        uint256 powerBefore = vault.totalPower();
        uint256 supplyBefore = vault.totalSupply();
        vm.startPrank(actor);
        nft.setApprovalForAll(address(vault), true);
        if (frozen()) {
            vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
            vault.deposit(ids);
            vm.stopPrank();
            assertEq(vault.totalSupply(), supplyBefore);
            assertEq(vault.totalPower(), powerBefore);
            for (uint256 i; i < count; ++i) {
                assertEq(nft.ownerOf(ids[i]), actor, "frozen deposit must not take the NFT");
            }
            ++frozenRejections;
            return;
        }
        uint256 shares = vault.deposit(ids);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(vault.totalPower() - powerBefore, count * 1000e18);
        assertEq(vault.totalSupply() - supplyBefore, shares);
        if (supplyBefore == 0) {
            assertEq(shares, count * 1000e18);
        } else {
            assertGe(vault.totalPower() * supplyBefore, powerBefore * vault.totalSupply(), "deposit diluted NAV");
            assertLe(shares * powerBefore, count * 1000e18 * supplyBefore);
            assertGt((shares + 1) * powerBefore, count * 1000e18 * supplyBefore);
        }
        for (uint256 i; i < count; ++i) {
            depositedIds.push(ids[i]);
            unmergedL1.push(ids[i]);
        }
        depositedCount += count;
        sharesMinted += shares;
        expectedShares[actor] += shares;
        ++successfulDeposits;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool delegated, bool infinite)
        public
        observed
    {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 balance = vault.balanceOf(from);
        // Explicitly sample 0, 1 wei, full balance as well as the interior of the domain.
        uint256 amount;
        if (amountSeed % 4 == 1) amount = balance == 0 ? 0 : 1;
        else if (amountSeed % 4 == 2) amount = balance;
        else if (amountSeed % 4 == 3) amount = bound(amountSeed, 0, balance);
        uint256 supplyBefore = vault.totalSupply();
        if (frozen()) {
            uint256 toBefore = vault.balanceOf(to);
            vm.prank(from);
            vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
            vault.transfer(to, amount);
            assertEq(vault.balanceOf(from), balance);
            assertEq(vault.balanceOf(to), toBefore);
            ++frozenRejections;
            return;
        }
        if (delegated) {
            address spender = actors[(fromSeed % 4 + 1) % 4];
            vm.prank(from);
            vault.approve(spender, infinite ? type(uint256).max : amount);
            vm.prank(spender);
            assertTrue(vault.transferFrom(from, to, amount));
            assertEq(vault.allowance(from, spender), infinite ? type(uint256).max : 0);
        } else {
            vm.prank(from);
            assertTrue(vault.transfer(to, amount));
        }
        expectedShares[from] -= amount;
        expectedShares[to] += amount;
        assertEq(vault.totalSupply(), supplyBefore);
        ++successfulTransfers;
    }

    function accrue(uint256 rewardSeed, bool donation) public observed {
        uint256 amount = bound(rewardSeed, 0, 1e24);
        if (donation) sqk.mint(address(vault), amount);
        else staking.fund(address(vault), amount);
        rewardsInjected += amount;
        _credit(amount);
    }

    function tinyAccrual(uint8 rewardSeed) external observed {
        uint256 amount = bound(rewardSeed, 1, 10);
        staking.fund(address(vault), amount);
        rewardsInjected += amount;
        _credit(amount);
    }

    function harvest(bool usePoke) public observed {
        uint256 supplyBefore = vault.totalSupply();
        uint256 powerBefore = vault.totalPower();
        if (usePoke) vault.poke();
        else vault.harvest();
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.totalPower(), powerBefore);
    }

    function claim(uint256 holderSeed, uint256 recipientSeed, bool redirect) public observed {
        address holder = actors[holderSeed % 4];
        address to = redirect ? actors[recipientSeed % 4] : holder;
        uint256 before = sqk.balanceOf(to);
        vm.prank(holder);
        uint256 paid = redirect ? vault.claimRewards(to) : vault.claimRewards();
        assertEq(sqk.balanceOf(to) - before, paid);
        assertEq(vault.unclaimedRewards(holder), 0);
        rewardsPaid += paid;
        expectedReceipts[to] += paid;
        claimedBy[holder] += paid;
        ++successfulClaims;
    }

    function merge(uint256 survivorSeed, uint256 donorSeed, bool ownerCall) public observed {
        if (unmergedL1.length < 2) return;
        uint256 survivorIndex = survivorSeed % unmergedL1.length;
        uint256 survivor = unmergedL1[survivorIndex];
        _removeL1(survivorIndex);
        uint256 donorIndex = donorSeed % unmergedL1.length;
        uint256 donor = unmergedL1[donorIndex];
        _removeL1(donorIndex);
        uint256 supplyBefore = vault.totalSupply();
        uint256 powerBefore = vault.totalPower();
        uint256 countBefore = vault.heldCount();
        address caller = ownerCall ? vault.owner() : strategist;
        vm.prank(caller);
        vault.mergeStep(survivor, donor);
        assertEq(vault.totalPower(), powerBefore + 200e18);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.heldCount(), countBefore - 1);
        assertEq(nft.level(survivor), 2);
        burned[donor] = true;
        ++mergedCount;
        ++successfulMerges;
    }

    /// @dev A Squeek pushed with a plain `transferFrom` (no receiver hook) is staked for the
    ///      reserve by an arbitrary caller. Power rises, no shares are minted, it becomes mergeable.
    function stranded(uint256 actorSeed, uint256 callerSeed, bool retry) public observed {
        address actor = actors[actorSeed % 4];
        address caller = actors[callerSeed % 4];
        uint256 id = nft.mint(actor, 1);
        vm.prank(actor);
        nft.transferFrom(actor, address(vault), id);
        uint256 supplyBefore = vault.totalSupply();
        uint256 powerBefore = vault.totalPower();
        uint256 countBefore = vault.heldCount();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(caller);
        vault.stakeStranded(ids);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.totalPower(), powerBefore + 1000e18);
        assertEq(vault.heldCount(), countBefore + 1);
        if (retry) {
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStranded.selector, id));
            vault.stakeStranded(ids);
        }
        depositedIds.push(id);
        unmergedL1.push(id);
        ++depositedCount;
        ++strandedStakes;
    }

    function _removeL1(uint256 index) internal {
        unmergedL1[index] = unmergedL1[unmergedL1.length - 1];
        unmergedL1.pop();
    }

    function failedMerge() public observed {
        if (unmergedL1.length < 2) return;
        uint256 a = unmergedL1[0];
        uint256 b = unmergedL1[1];
        uint256 powerBefore = vault.totalPower();
        uint256 indexBefore = vault.rewardIndex();
        uint256 claimableBefore = staking.claimable(address(vault));
        staking.setZeroPowerMode(true);
        vm.prank(strategist);
        vm.expectRevert(
            abi.encodeWithSelector(
                HamsterMiningReserve.PowerDidNotIncrease.selector, powerBefore, powerBefore - 2000e18
            )
        );
        vault.mergeStep(a, b);
        staking.setZeroPowerMode(false);
        assertEq(vault.totalPower(), powerBefore);
        assertEq(vault.rewardIndex(), indexBefore);
        assertEq(staking.claimable(address(vault)), claimableBefore);
        assertEq(nft.level(a), 1);
        assertEq(nft.ownerOf(b), address(staking));
        ++rejectedMerges;
    }

    function unauthorizedMerge(uint256 actorSeed) public observed {
        address actor = actors[actorSeed % 4];
        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, actor));
        vault.mergeStep(1, 2);
        ++rejectedUnauthorized;
    }

    function outage(bool checkpointFails, bool claimFails) public observed {
        emission.setRevertOnCheckpoint(checkpointFails);
        staking.setRevertOnClaim(claimFails);
        vault.harvest();
    }

    function recoverAndClaimAll() external {
        emission.setRevertOnCheckpoint(false);
        staking.setRevertOnClaim(false);
        vault.harvest();
        for (uint256 i; i < 4; ++i) {
            claim(i, i, false);
        }
    }
}

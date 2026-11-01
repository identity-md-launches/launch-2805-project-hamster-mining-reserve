// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveFixture} from "../helpers/ReserveFixture.sol";
import {ReserveHandler} from "./ReserveHandler.sol";

/// @notice Stateful campaigns: conservation, physical custody, NAV and reward solvency.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ReserveInvariantTest is ReserveFixture {
    ReserveHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ReserveHandler(vault, sqk, nft, staking, emission, strategist);
        // Start funded with several real mock NFTs, so no sequence checks only an empty vault.
        for (uint256 i; i < 4; ++i) {
            handler.deposit(i, 2);
        }
        handler.accrue(17e18, false);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.transferShares.selector;
        selectors[2] = handler.accrue.selector;
        selectors[3] = handler.tinyAccrual.selector;
        selectors[4] = handler.harvest.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.merge.selector;
        selectors[7] = handler.failedMerge.selector;
        selectors[8] = handler.unauthorizedMerge.selector;
        selectors[9] = handler.outage.selector;
        selectors[10] = handler.stranded.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_sharesAreConservedAndBackedByDepositedPower() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 shares = vault.balanceOf(actor);
            assertEq(shares, handler.expectedShares(actor));
            assertLe(vault.holderIndex(actor), vault.rewardIndex());
            sum += shares;
        }
        assertEq(sum, vault.totalSupply());
        assertEq(sum, handler.sharesMinted());
        // Every share was minted against power; stranded stakes and merges only add power.
        assertLe(sum, vault.totalPower());
        assertEq(vault.totalPower(), handler.depositedCount() * 1000e18 + handler.mergedCount() * 200e18);
        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.balanceOf(address(0)), 0);
    }

    function invariant_reserveCountAndCustodyMatchEveryNft() public view {
        uint256 held;
        for (uint256 i; i < handler.depositedCount(); ++i) {
            uint256 id = handler.depositedIds(i);
            bool burned = handler.burned(id);
            assertEq(vault.isHeld(id), !burned);
            if (burned) {
                assertEq(staking.stakerOf(id), address(0));
                (bool exists,) = address(nft).staticcall(abi.encodeCall(nft.ownerOf, (id)));
                assertFalse(exists, "donor must actually be burned");
            } else {
                ++held;
                assertEq(nft.ownerOf(id), address(staking));
                assertEq(staking.stakerOf(id), address(vault));
            }
        }
        assertEq(held, vault.heldCount());
        assertEq(held + handler.mergedCount(), handler.depositedCount());
        assertEq(nft.balanceOf(address(staking)), held);
        assertEq(nft.balanceOf(address(vault)), 0);
    }

    function invariant_allRewardCashIsConservedAndLiabilitiesAreCovered() public view {
        uint256 receipts;
        uint256 pending;
        uint256 synchronizedDebt;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = sqk.balanceOf(actor);
            assertEq(balance, handler.expectedReceipts(actor));
            receipts += balance;
            pending += vault.pendingRewards(actor);
            synchronizedDebt += vault.unclaimedRewards(actor);
        }
        uint256 vaultBalance = sqk.balanceOf(address(vault));
        uint256 accrued = staking.claimable(address(vault));
        assertEq(receipts, vault.totalRewardsPaid());
        assertEq(receipts, handler.rewardsPaid());
        assertEq(sqk.balanceOf(address(staking)), accrued);
        assertEq(receipts + vaultBalance + accrued, handler.rewardsInjected());
        assertEq(sqk.totalSupply(), handler.rewardsInjected());
        assertLe(vault.accountedBalance(), vaultBalance);
        assertLe(synchronizedDebt, vault.accountedBalance());
        assertLe(pending, vaultBalance + accrued);
    }

    /// @dev Nobody, in any state, is owed less than they have already been paid (beyond dust):
    ///      a holder can never claim SQK that accrued to someone else's balance.
    function invariant_noHolderClaimsMoreThanTheirEntitlement() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertLe(handler.claimedBy(actor), handler.entitled(actor) + handler.actions() * 2 + 2);
        }
    }

    function afterInvariant() public {
        handler.recoverAndClaimAll();
        invariant_sharesAreConservedAndBackedByDepositedPower();
        invariant_reserveCountAndCustodyMatchEveryNft();
        invariant_allRewardCashIsConservedAndLiabilitiesAreCovered();
        assertEq(staking.claimable(address(vault)), 0);
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(vault.pendingRewards(actor), 0);
            // After recovery every holder has received what accrued to their balance at the time,
            // including SQK that was delayed by a claim outage. Tolerance: floor rounding only.
            assertApproxEqAbs(
                handler.claimedBy(actor),
                handler.entitled(actor),
                handler.actions() * 2 + 2,
                "delayed reward misallocated"
            );
        }
        // With < 1e27 shares each global-index truncation loses < 1 wei, and each
        // holder synchronization loses < 1 wei. A transfer synchronizes at most two holders.
        // Six wei per action conservatively covers every settlement and final claim here.
        assertLe(sqk.balanceOf(address(vault)), (handler.actions() + 1) * 6, "unclaimable value exceeds rounding dust");
    }

    function test_handlerExercisesEveryActionAndBothOutageStates() public {
        handler.transferShares(0, 1, 2, true, false);
        handler.transferShares(1, 2, 1, true, true);
        handler.transferShares(2, 2, 0, false, false);
        handler.accrue(3e18, true);
        handler.tinyAccrual(1);
        handler.harvest(true);
        handler.claim(0, 3, true);
        handler.failedMerge();
        handler.unauthorizedMerge(2);
        handler.merge(0, 0, true);
        handler.merge(0, 0, false);
        handler.stranded(1, 2, true);
        handler.merge(0, 0, false);
        handler.outage(true, true);
        handler.deposit(3, 1); // nothing claimable yet: proceeds despite the outage
        handler.accrue(5e18, false);
        assertTrue(handler.frozen());
        handler.deposit(3, 1); // SQK stuck in staking: refused
        handler.transferShares(3, 0, 2, false, false); // refused
        handler.claim(1, 1, false);
        handler.harvest(false);
        handler.outage(false, false);
        assertFalse(handler.frozen());
        assertGt(handler.successfulDeposits(), 4);
        assertGt(handler.successfulTransfers(), 0);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.successfulMerges(), 0);
        assertGt(handler.rejectedMerges(), 0);
        assertGt(handler.rejectedUnauthorized(), 0);
        assertEq(handler.frozenRejections(), 2);
        assertGt(handler.strandedStakes(), 0);
        afterInvariant();
    }
}

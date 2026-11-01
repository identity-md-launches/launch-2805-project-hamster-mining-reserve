// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveFixture} from "./helpers/ReserveFixture.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {MockSqueekNFT} from "./mocks/MockSqueekchain.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Exact boundaries and rollback checks complement the original happy-path suite.
/// forge-config: default.fuzz.runs = 1000
contract ReserveEdgesTest is ReserveFixture {
    function test_maximumBatchSucceedsAndEveryNftIsInCustody() public {
        uint256 first = _deposit(alice, 50);
        assertEq(vault.totalSupply(), 50 * L1);
        assertEq(vault.heldCount(), 50);
        assertEq(vault.totalPower(), 50 * L1);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.balanceOf(address(vault)), 0);
        for (uint256 i; i < 50; ++i) {
            _assertStaked(first + i);
        }
    }

    function test_duplicateAtEndOfMaximumBatchRollsBackTransfersAndSettlement() public {
        _deposit(bob, 1);
        staking.fund(address(vault), 17e18);
        uint256 first = _give(alice, 50);
        uint256[] memory ids = _ids(first, 50);
        ids[49] = first;
        uint256 checkpointsBefore = emission.checkpoints();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, alice, first, address(vault))
        );
        vault.deposit(ids);
        for (uint256 i; i < 50; ++i) {
            assertEq(nft.ownerOf(first + i), alice);
            assertFalse(vault.isHeld(first + i));
            assertEq(staking.stakerOf(first + i), address(0));
        }
        assertEq(vault.totalSupply(), L1);
        assertEq(vault.totalPower(), L1);
        assertEq(vault.heldCount(), 1);
        assertEq(vault.rewardIndex(), 0);
        assertEq(staking.claimable(address(vault)), 17e18);
        assertEq(sqk.balanceOf(address(vault)), 0);
        assertEq(emission.checkpoints(), checkpointsBefore);
    }

    function test_partialBatchWithForeignLastTokenRollsBack() public {
        uint256 first = _give(alice, 2);
        uint256 foreign = _give(bob, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, alice, foreign, bob));
        vault.deposit(_ids(first, 3));
        assertEq(nft.ownerOf(first), alice);
        assertEq(nft.ownerOf(first + 1), alice);
        assertEq(nft.ownerOf(foreign), bob);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.heldCount(), 0);
        assertFalse(vault.isHeld(first));
        assertFalse(nft.isApprovedForAll(address(vault), address(staking)));
    }

    function test_depositAlreadyStakedTokenCannotMintAgain() public {
        uint256 id = _deposit(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(vault), id));
        vault.deposit(_ids(id, 1));
        _assertStaked(id);
        assertEq(vault.totalSupply(), L1);
        assertEq(vault.heldCount(), 1);
    }

    function test_singleTokenApprovalSuffices() public {
        uint256 id = nft.mint(alice, 1);
        vm.prank(alice);
        nft.approve(address(vault), id);
        vm.prank(alice);
        vault.deposit(_ids(id, 1));
        _assertStaked(id);
        assertEq(vault.balanceOf(alice), L1);
    }

    function test_zeroAndSelfTransfersSettleWithoutChangingSupply() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 7e18);
        vm.prank(carol);
        assertTrue(vault.transfer(alice, 0));
        assertEq(vault.unclaimedRewards(alice), 7e18);
        staking.fund(address(vault), 3e18);
        vm.prank(alice);
        assertTrue(vault.transfer(alice, L1));
        assertEq(vault.balanceOf(alice), L1);
        assertEq(vault.totalSupply(), L1);
        assertEq(vault.pendingRewards(alice), 10e18);
        assertEq(vault.balanceOf(carol), 0);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 10e18);
    }

    function test_failedTransferRollsBackRewardSettlement() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 13e18);
        uint256 before = emission.checkpoints();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, L1, L1 + 1));
        vault.transfer(bob, L1 + 1);
        assertEq(staking.claimable(address(vault)), 13e18);
        assertEq(vault.rewardIndex(), 0);
        assertEq(vault.holderIndex(alice), 0);
        assertEq(vault.totalRewardsPaid(), 0);
        assertEq(sqk.balanceOf(address(vault)), 0);
        assertEq(emission.checkpoints(), before);
    }

    function test_transferToZeroAndInsufficientAllowanceCannotBurnOrMoveShares() public {
        _deposit(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vault.transfer(address(0), L1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vault.transferFrom(alice, bob, 1);
        assertEq(vault.balanceOf(alice), L1);
        assertEq(vault.totalSupply(), L1);
    }

    function test_finiteAndInfiniteAllowanceRespectFullExitAndRewardOwnership() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 10e18);
        vm.prank(alice);
        vault.approve(carol, 1);
        vm.prank(carol);
        vault.transferFrom(alice, bob, 1);
        assertEq(vault.allowance(alice, carol), 0);
        assertEq(vault.pendingRewards(bob), 0);
        vm.prank(alice);
        vault.approve(carol, type(uint256).max);
        vm.prank(carol);
        vault.transferFrom(alice, bob, L1 - 1);
        assertEq(vault.allowance(alice, carol), type(uint256).max);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), L1);
        staking.fund(address(vault), 5e18);
        vm.prank(alice);
        assertEq(vault.claimRewards(carol), 10e18);
        vm.prank(bob);
        assertEq(vault.claimRewards(), 5e18);
        assertEq(sqk.balanceOf(carol), 10e18);
    }

    function test_claimFailureDoesNotLoseEntitlementWhenBalancesAreUnchanged() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 11e18);
        staking.setRevertOnClaim(true);
        vault.poke();
        vault.harvest();
        vm.prank(alice);
        assertEq(vault.claimRewards(), 0);
        assertEq(staking.claimable(address(vault)), 11e18);
        staking.setRevertOnClaim(false);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 11e18);
        assertEq(vault.totalRewardsPaid(), 11e18);
    }

    function test_checkpointFailureStillAllowsClaimOfAlreadyAccruedRewards() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 11e18);
        emission.setRevertOnCheckpoint(true);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 11e18);
        assertEq(sqk.balanceOf(alice), 11e18);
    }

    function test_previewIsReadOnlyAndIncludesUnharvestedAndDonatedRewards() public {
        _deposit(alice, 1);
        _deposit(bob, 1);
        staking.fund(address(vault), 30e18);
        sqk.mint(address(vault), 10e18);
        uint256 before = emission.checkpoints();
        assertEq(vault.pendingRewards(alice), 20e18);
        assertEq(vault.pendingRewards(bob), 20e18);
        assertEq(vault.pendingRewards(carol), 0);
        assertEq(vault.rewardIndex(), 0);
        assertEq(vault.accountedBalance(), 0);
        assertEq(emission.checkpoints(), before);
        vault.harvest();
        assertEq(vault.pendingRewards(alice), 20e18);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 20e18);
    }

    function test_harvestAndClaimsAreIdempotentWithoutNewRewards() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 1);
        vault.harvest();
        uint256 index = vault.rewardIndex();
        for (uint256 i; i < 3; ++i) {
            vault.poke();
            vault.harvest();
            assertEq(vault.rewardIndex(), index);
            assertEq(vault.accountedBalance(), 1);
        }
        vm.prank(alice);
        assertEq(vault.claimRewards(), 1);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 0);
        assertEq(vault.totalRewardsPaid(), 1);
    }

    function test_maximumLevelMergeRevertsAtomically() public {
        uint256 first = nft.mintAtLevel(alice, 10);
        nft.mintAtLevel(alice, 10);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(vault), true);
        vault.deposit(_ids(first, 2));
        vm.stopPrank();
        uint256 power = vault.totalPower();
        vm.prank(strategist);
        vm.expectRevert(MockSqueekNFT.MaxLevel.selector);
        vault.mergeStep(first, first + 1);
        _assertStaked(first);
        _assertStaked(first + 1);
        assertEq(vault.totalPower(), power);
        assertEq(vault.heldCount(), 2);
    }

    function test_cooldownJustBeforeAndAtBoundary() public {
        nft.setCooldownBlocks(3000);
        uint256 first = _deposit(alice, 4);
        vm.startPrank(strategist);
        vault.mergeStep(first, first + 1);
        vault.mergeStep(first + 2, first + 3);
        vm.stopPrank();
        uint256 mergedAt = block.number;
        vm.roll(mergedAt + 2999);
        vm.prank(strategist);
        vm.expectRevert(MockSqueekNFT.Cooldown.selector);
        vault.mergeStep(first, first + 2);
        _assertStaked(first);
        _assertStaked(first + 2);
        assertEq(vault.heldCount(), 2);
        vm.roll(mergedAt + 3000);
        vm.prank(strategist);
        vault.mergeStep(first, first + 2);
        assertEq(vault.heldCount(), 1);
        assertEq(nft.level(first), 3);
    }

    function test_burnedDonorCannotBeMergedAgain() public {
        uint256 first = _deposit(alice, 3);
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotHeld.selector, first + 1));
        vault.mergeStep(first + 2, first + 1);
        assertEq(vault.heldCount(), 2);
        assertEq(vault.totalPower(), 3200e18);
        assertEq(vault.totalSupply(), 3000e18);
    }

    function test_receiverWindowClosesAfterSuccessfulAndFailedMerge() public {
        uint256 first = _deposit(alice, 4);
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        staking.setZeroPowerMode(true);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.PowerDidNotIncrease.selector, 4200e18, 2200e18));
        vault.mergeStep(first + 2, first + 3);
        uint256 unsolicited = _give(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.UnexpectedNft.selector, bob, unsolicited));
        nft.safeTransferFrom(bob, address(vault), unsolicited);
        assertEq(nft.ownerOf(unsolicited), bob);
        staking.setZeroPowerMode(false);
        vm.prank(strategist);
        vault.mergeStep(first + 2, first + 3);
        assertEq(vault.heldCount(), 2);
    }

    function test_pendingOwnerHasNoAuthorityAndPreviousOwnerLosesItOnAcceptance() public {
        uint256 first = _deposit(alice, 2);
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vault.setStrategist(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, bob));
        vault.mergeStep(first, first + 1);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, owner));
        vault.mergeStep(first, first + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setStrategist(owner);
        vm.prank(bob);
        vault.mergeStep(first, first + 1);
        assertEq(vault.owner(), bob);
    }

    function test_unexposedWithdrawalAndSweepSelectorsCannotReleaseReserve() public {
        uint256 id = _deposit(alice, 1);
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeWithSignature("withdraw(uint256[])", _ids(id, 1));
        calls[1] = abi.encodeWithSignature("withdraw(address,uint256[])", address(nft), _ids(id, 1));
        calls[2] = abi.encodeWithSignature("redeem(uint256,address,address)", L1, alice, alice);
        calls[3] = abi.encodeWithSignature("sweep(address,address,uint256)", address(nft), alice, id);
        calls[4] = abi.encodeWithSignature("rescueERC721(address,uint256,address)", address(nft), id, alice);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ownerOk,) = address(vault).call(calls[i]);
            assertFalse(ownerOk);
            vm.prank(alice);
            (bool depositorOk,) = address(vault).call(calls[i]);
            assertFalse(depositorOk);
        }
        _assertStaked(id);
        assertEq(vault.balanceOf(alice), L1);
    }

    function testFuzz_rewardSplitUsesSharesAfterMergeAndLaterDeposit(uint96 rewardSeed, uint16 transferSeed) public {
        uint256 first = _deposit(alice, 2);
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        // Equal shares remain equal claims even though the NFT backing those shares has merged.
        uint256 moved = bound(transferSeed, 0, 10_000) * (2 * L1) / 10_000;
        vm.prank(alice);
        vault.transfer(bob, moved);
        uint256 reward = bound(rewardSeed, 0, 1e26);
        staking.fund(address(vault), reward);
        _deposit(carol, 1);
        assertEq(vault.pendingRewards(carol), 0, "late depositor must not share the prior accrual");
        vm.prank(alice);
        uint256 a = vault.claimRewards();
        vm.prank(bob);
        uint256 b = vault.claimRewards();
        assertApproxEqAbs(b, reward * moved / (2 * L1), 1);
        assertLe(a + b, reward);
        assertLe(reward - a - b, 2);
        assertEq(sqk.balanceOf(address(vault)) + a + b, reward);
    }
}

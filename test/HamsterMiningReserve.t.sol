// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {MockSQK, MockCore, MockEmission, MockSqueekNFT, MockStaking} from "./mocks/MockSqueekchain.sol";

/// @notice Offline unit tests against local stand-ins of the Squeekchain v9 graph.
contract HamsterMiningReserveTest is Test {
    uint256 constant L1_POWER = 1000e18;
    uint256 constant L2_POWER = 2200e18;

    address owner = makeAddr("owner");
    address strategist = makeAddr("strategist");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    MockSQK sqk;
    MockCore core;
    MockEmission emission;
    MockSqueekNFT nft;
    MockStaking staking;
    HamsterMiningReserve vault;

    function setUp() public {
        sqk = new MockSQK();
        core = new MockCore();
        emission = new MockEmission(address(core));
        nft = new MockSqueekNFT(address(emission), address(core));
        staking = new MockStaking(nft, sqk, address(emission));
        vault = new HamsterMiningReserve(
            owner, address(nft), address(staking), address(emission), address(core), address(sqk)
        );
        vm.prank(owner);
        vault.setStrategist(strategist);

        _give(alice, 4);
        _give(bob, 4);
        _give(carol, 2);
    }

    // ---------------------------------------------------------------- helpers

    function _give(address who, uint256 count) internal returns (uint256 first) {
        first = nft.mint(who, count);
        vm.prank(who);
        nft.setApprovalForAll(address(vault), true);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _depositL1(address who, uint256 a) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(_ids(a));
    }

    // ---------------------------------------------------------------- construction

    function test_constructor_setsWiringAndStrategistDefaultsToOwner() public {
        HamsterMiningReserve fresh = new HamsterMiningReserve(
            owner, address(nft), address(staking), address(emission), address(core), address(sqk)
        );
        assertEq(fresh.owner(), owner);
        assertEq(fresh.strategist(), owner);
        assertEq(address(fresh.nft()), address(nft));
        assertEq(address(fresh.staking()), address(staking));
        assertEq(address(fresh.emission()), address(emission));
        assertEq(address(fresh.core()), address(core));
        assertEq(address(fresh.rewardToken()), address(sqk));
        assertEq(fresh.name(), "Hamster Mining Reserve Share");
        assertEq(fresh.symbol(), "hmSQUEEK");
        assertEq(fresh.decimals(), 18);
        assertEq(fresh.totalSupply(), 0);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HamsterMiningReserve(
            address(0), address(nft), address(staking), address(emission), address(core), address(sqk)
        );
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        new HamsterMiningReserve(owner, address(0), address(staking), address(emission), address(core), address(sqk));
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        new HamsterMiningReserve(owner, address(nft), address(0), address(emission), address(core), address(sqk));
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        new HamsterMiningReserve(owner, address(nft), address(staking), address(0), address(core), address(sqk));
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        new HamsterMiningReserve(owner, address(nft), address(staking), address(emission), address(0), address(sqk));
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        new HamsterMiningReserve(owner, address(nft), address(staking), address(emission), address(core), address(0));
    }

    function test_constructor_makesNoExternalCalls() public {
        // Deploying against addresses with no code must succeed (launch rehearses on an empty chain).
        HamsterMiningReserve bare = new HamsterMiningReserve(
            owner, address(0x1111), address(0x2222), address(0x3333), address(0x4444), address(0x5555)
        );
        assertEq(bare.owner(), owner);
    }

    function test_graphHealth_readsGraphConstants() public view {
        (uint256 maxLevel, uint256 emissionVersion, uint256 coreVersion, bool g, bool m, bool t, bool nm, bool nc) =
            vault.graphHealth();
        assertEq(maxLevel, 10);
        assertEq(emissionVersion, 9);
        assertEq(coreVersion, 3);
        assertTrue(g && m && t && nm && nc);
        (bool paused, uint64 nextRound, bool settled) = vault.emissionStatus();
        assertFalse(paused);
        assertEq(nextRound, 798);
        assertFalse(settled);
    }

    // ---------------------------------------------------------------- deposit

    function test_deposit_firstDepositMintsSharesEqualToPower() public {
        uint256 shares = _depositL1(alice, 1);
        assertEq(shares, L1_POWER);
        assertEq(vault.balanceOf(alice), L1_POWER);
        assertEq(vault.totalSupply(), L1_POWER);
        assertEq(vault.totalPower(), L1_POWER);
        assertEq(vault.heldCount(), 1);
        assertTrue(vault.isHeld(1));
        assertEq(nft.ownerOf(1), address(staking));
        assertEq(staking.stakerOf(1), address(vault));
        assertEq(vault.powerPerShare(), 1e18);
    }

    function test_deposit_batchStakesAll() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(_ids(1, 2));
        assertEq(shares, 2 * L1_POWER);
        assertEq(vault.heldCount(), 2);
        assertEq(vault.totalPower(), 2 * L1_POWER);
    }

    function test_deposit_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit HamsterMiningReserve.Deposited(alice, _ids(1), L1_POWER, L1_POWER);
        _depositL1(alice, 1);
    }

    function test_deposit_secondDepositorPricedAtNav() public {
        _depositL1(alice, 1);
        // Merge raises power without minting: NAV per share rises.
        _depositL1(alice, 2);
        vm.prank(strategist);
        vault.mergeStep(1, 2);
        assertEq(vault.totalPower(), L2_POWER);
        assertEq(vault.totalSupply(), 2 * L1_POWER);

        // Bob deposits one L1 (1000e18 power) when 2000e18 shares back 2200e18 power.
        uint256 shares = _depositL1(bob, 5);
        assertEq(shares, (L1_POWER * 2 * L1_POWER) / L2_POWER);
        // Bob owns exactly his power fraction of the vault.
        assertApproxEqAbs(vault.balanceOf(bob) * vault.totalPower() / vault.totalSupply(), L1_POWER, 2);
    }

    function test_deposit_higherLevelNftGetsProportionallyMoreShares() public {
        _depositL1(alice, 1);
        uint256 l2 = nft.mintAtLevel(bob, 2);
        vm.prank(bob);
        uint256 shares = vault.deposit(_ids(l2));
        assertEq(shares, L2_POWER);
    }

    function test_deposit_revertsOnEmptyBatch() public {
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.EmptyBatch.selector);
        vault.deposit(new uint256[](0));
    }

    function test_deposit_revertsOnOversizedBatch() public {
        uint256[] memory ids = new uint256[](51);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.BatchTooLarge.selector, 51, 50));
        vault.deposit(ids);
    }

    function test_deposit_revertsWhenCallerDoesNotOwnToken() public {
        // Token 5 belongs to bob.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, alice, 5, bob));
        vault.deposit(_ids(5));
    }

    function test_deposit_revertsWithoutApproval() public {
        vm.prank(alice);
        nft.setApprovalForAll(address(vault), false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(vault), 1));
        vault.deposit(_ids(1));
    }

    function test_deposit_revertsOnDuplicateIds() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(_ids(1, 1));
    }

    function test_deposit_revertsWhenStakeAddsNoPower() public {
        staking.setZeroPowerMode(true);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.NoPowerAdded.selector);
        vault.deposit(_ids(1));
        // Nothing moved.
        assertEq(nft.ownerOf(1), alice);
        assertEq(vault.heldCount(), 0);
    }

    function test_unsolicitedSafeTransferIsRejected() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.UnexpectedNft.selector, alice, 1));
        nft.safeTransferFrom(alice, address(vault), 1);
    }

    function test_onERC721Received_rejectsForeignCollection() public {
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.UnexpectedNft.selector, alice, 7));
        vault.onERC721Received(alice, alice, 7, "");
    }

    // ---------------------------------------------------------------- mergeStep

    function test_mergeStep_netsPlus200AndFreesOneSlot() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        uint256 powerBefore = vault.totalPower();
        uint256 supplyBefore = vault.totalSupply();

        vm.expectEmit(true, true, false, true, address(vault));
        emit HamsterMiningReserve.MergeStep(1, 2, 2, powerBefore, powerBefore + 200e18);
        vm.prank(strategist);
        vault.mergeStep(1, 2);

        assertEq(vault.totalPower(), powerBefore + 200e18);
        assertEq(vault.totalSupply(), supplyBefore, "merge never changes share supply");
        assertEq(vault.heldCount(), 1);
        assertTrue(vault.isHeld(1));
        assertFalse(vault.isHeld(2));
        assertEq(nft.level(1), 2);
        assertEq(nft.ownerOf(1), address(staking));
        assertEq(staking.stakerOf(1), address(vault));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        nft.ownerOf(2);
    }

    function test_mergeStep_ownerMayMerge() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        vm.prank(owner);
        vault.mergeStep(1, 2);
        assertEq(nft.level(1), 2);
    }

    function test_mergeStep_chainsToHigherLevels() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        vm.prank(bob);
        vault.deposit(_ids(5, 6));
        vm.startPrank(strategist);
        vault.mergeStep(1, 2);
        vault.mergeStep(5, 6);
        uint256 p = vault.totalPower();
        vault.mergeStep(1, 5);
        vm.stopPrank();
        assertEq(nft.level(1), 3);
        assertGt(vault.totalPower(), p);
        assertEq(vault.heldCount(), 1);
    }

    function test_mergeStep_revertsForNonStrategist() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, alice));
        vault.mergeStep(1, 2);
    }

    function test_mergeStep_revertsOnSameToken() public {
        _depositL1(alice, 1);
        vm.prank(strategist);
        vm.expectRevert(HamsterMiningReserve.SameToken.selector);
        vault.mergeStep(1, 1);
    }

    function test_mergeStep_revertsWhenTokenNotHeld() public {
        _depositL1(alice, 1);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotHeld.selector, 5));
        vault.mergeStep(1, 5);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotHeld.selector, 5));
        vault.mergeStep(5, 1);
    }

    function test_mergeStep_revertsOnLevelMismatch() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        _depositL1(alice, 3);
        vm.prank(strategist);
        vault.mergeStep(1, 2);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.LevelMismatch.selector, 2, 1));
        vault.mergeStep(1, 3);
    }

    function test_mergeStep_revertsWhenNftCooldownBlocks() public {
        nft.setCooldownBlocks(3000);
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        vm.prank(bob);
        vault.deposit(_ids(5, 6));
        vm.startPrank(strategist);
        vault.mergeStep(1, 2);
        vault.mergeStep(5, 6);
        vm.expectRevert(MockSqueekNFT.Cooldown.selector);
        vault.mergeStep(1, 5);
        vm.stopPrank();
        // State is unchanged by the failed step.
        assertEq(vault.heldCount(), 2);
        assertEq(staking.stakerOf(1), address(vault));
        assertEq(staking.stakerOf(5), address(vault));

        vm.roll(block.number + 3000);
        vm.prank(strategist);
        vault.mergeStep(1, 5);
        assertEq(nft.level(1), 3);
    }

    function test_mergeStep_revertsUnlessPowerStrictlyIncreases() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        // Re-staking the survivor credits nothing: power would fall from 2000 to 0.
        staking.setZeroPowerMode(true);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.PowerDidNotIncrease.selector, 2000e18, 0));
        vault.mergeStep(1, 2);
        // Atomic: the donor still exists and both remain staked.
        assertEq(nft.ownerOf(2), address(staking));
        assertEq(vault.heldCount(), 2);
    }

    // ---------------------------------------------------------------- rewards

    function test_harvest_atZeroIsCleanAndClaimReturnsZero() public {
        _depositL1(alice, 1);
        vault.harvest();
        vault.poke();
        assertEq(vault.rewardIndex(), 0);
        assertEq(vault.pendingRewards(alice), 0);
        vm.prank(alice);
        uint256 got = vault.claimRewards();
        assertEq(got, 0);
        assertEq(sqk.balanceOf(alice), 0);
        // Claim with no shares at all is also clean.
        vm.prank(carol);
        assertEq(vault.claimRewards(), 0);
    }

    function test_harvest_checkpointsEmission() public {
        uint256 before = emission.checkpoints();
        vault.harvest();
        assertEq(emission.checkpoints(), before + 1);
    }

    function test_harvest_neverRevertsWhenEmissionOrClaimRevert() public {
        _depositL1(alice, 1);
        emission.setRevertOnCheckpoint(true);
        staking.setRevertOnClaim(true);
        vm.expectEmit(false, false, false, false, address(vault));
        emit HamsterMiningReserve.CheckpointFailed("");
        vm.expectEmit(false, false, false, false, address(vault));
        emit HamsterMiningReserve.ClaimFailed("");
        vault.harvest();
        // Deposits, transfers and claims keep working while the graph is unhappy.
        _depositL1(bob, 5);
        vm.prank(alice);
        vault.transfer(bob, 1);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 0);
    }

    function test_settle_claimOutageWithClaimableSqkFreezesDepositsAndTransfers() public {
        _depositL1(alice, 1);
        staking.fund(address(vault), 100e18);
        staking.setRevertOnClaim(true);

        // Balance changes are refused while the 100 SQK cannot be pulled in.
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.deposit(_ids(5));
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.transfer(bob, L1_POWER);
        vm.prank(alice);
        vault.approve(bob, L1_POWER);
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.transferFrom(alice, bob, L1_POWER);
        assertEq(nft.ownerOf(5), bob);
        assertEq(vault.balanceOf(alice), L1_POWER);

        // Keeper and claim paths still never revert; merge is unaffected (no balance change).
        vault.harvest();
        vault.poke();
        vm.prank(alice);
        assertEq(vault.claimRewards(), 0);
        // Even the existing holder cannot add shares while the outage lasts.
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.deposit(_ids(2));

        // Recovery: the deferred SQK goes to the holders of record at accrual time only.
        staking.setRevertOnClaim(false);
        _depositL1(bob, 5);
        assertEq(vault.pendingRewards(alice), 100e18);
        assertEq(vault.pendingRewards(bob), 0);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 100e18);
    }

    function test_settle_claimOutageWithNothingClaimableDoesNotFreeze() public {
        _depositL1(alice, 1);
        staking.setRevertOnClaim(true);
        // claimable == 0: nothing is at risk, so deposits and transfers go through.
        _depositL1(bob, 5);
        vm.prank(alice);
        vault.transfer(bob, 1);
        assertEq(vault.balanceOf(bob), L1_POWER + 1);
    }

    function test_settle_mergeStepStillWorksDuringClaimOutage() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        staking.fund(address(vault), 10e18);
        staking.setRevertOnClaim(true);
        vm.prank(strategist);
        vault.mergeStep(1, 2);
        assertEq(nft.level(1), 2);
        staking.setRevertOnClaim(false);
        assertEq(vault.pendingRewards(alice), 10e18);
    }

    function test_settle_voidReturningClaimDoesNotBlockVault() public {
        staking.setVoidClaimReturn(true);
        _depositL1(alice, 1);
        staking.fund(address(vault), 10e18);
        vault.harvest();
        vm.prank(alice);
        assertEq(vault.claimRewards(), 10e18);
        vm.prank(alice);
        vault.transfer(bob, L1_POWER);
        assertEq(vault.balanceOf(bob), L1_POWER);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotHeld.selector, 2));
        vault.mergeStep(1, 2);
    }

    function test_rewards_vaultCannotBeShareOrRewardRecipient() public {
        _depositL1(alice, 1);
        _depositL1(bob, 5);
        staking.fund(address(vault), 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidRecipient.selector, address(vault)));
        vault.claimRewards(address(vault));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidRecipient.selector, address(vault)));
        vault.transfer(address(vault), L1_POWER);

        vm.prank(bob);
        vault.approve(carol, L1_POWER);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidRecipient.selector, address(vault)));
        vault.transferFrom(bob, address(vault), L1_POWER);

        assertEq(vault.balanceOf(address(vault)), 0);
        assertEq(vault.pendingRewards(alice), 50e18);
        assertEq(vault.pendingRewards(bob), 50e18);
    }

    function test_deposit_revertsWhenPowerWasZeroedUpstreamWhileSharesExist() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        // Upstream resets the vault's account power while 2000e18 shares are outstanding.
        staking.setAccountPower(address(vault), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.ZeroPowerWithShares.selector, 2 * L1_POWER));
        vault.deposit(_ids(5));
        assertEq(nft.ownerOf(5), bob);
        assertEq(vault.totalSupply(), 2 * L1_POWER);
    }

    function test_stakeStranded_putsPlainPushedNftToWorkWithoutShares() public {
        _depositL1(alice, 1);
        // Plain transferFrom invokes no receiver hook, so the vault cannot refuse it.
        vm.prank(bob);
        nft.transferFrom(bob, address(vault), 5);
        assertEq(nft.ownerOf(5), address(vault));
        assertFalse(vault.isHeld(5));
        assertEq(vault.totalPower(), L1_POWER);
        // The former owner can no longer deposit it, and it cannot be merged yet.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, bob, 5, address(vault)));
        vault.deposit(_ids(5));
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotHeld.selector, 5));
        vault.mergeStep(1, 5);

        // Anyone stakes it for the reserve; no shares are minted.
        uint256 supply = vault.totalSupply();
        vm.expectEmit(true, false, false, true, address(vault));
        emit HamsterMiningReserve.StrandedStaked(carol, _ids(5), L1_POWER);
        vm.prank(carol);
        vault.stakeStranded(_ids(5));
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.totalPower(), 2 * L1_POWER);
        assertEq(vault.heldCount(), 2);
        assertTrue(vault.isHeld(5));
        assertEq(nft.ownerOf(5), address(staking));
        assertEq(staking.stakerOf(5), address(vault));
        assertEq(vault.powerPerShare(), 2e18, "stranded power accrues to existing holders");
        // Now it merges like any held token.
        vm.prank(strategist);
        vault.mergeStep(1, 5);
        assertEq(nft.level(1), 2);
    }

    function test_stakeStranded_rejectsHeldOrForeignTokens() public {
        _depositL1(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStranded.selector, 1));
        vault.stakeStranded(_ids(1));
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStranded.selector, 5));
        vault.stakeStranded(_ids(5));
        vm.expectRevert(HamsterMiningReserve.EmptyBatch.selector);
        vault.stakeStranded(new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.BatchTooLarge.selector, 51, 50));
        vault.stakeStranded(new uint256[](51));
        // A stranded token that adds no power is not absorbed.
        vm.prank(bob);
        nft.transferFrom(bob, address(vault), 5);
        staking.setZeroPowerMode(true);
        vm.expectRevert(HamsterMiningReserve.NoPowerAdded.selector);
        vault.stakeStranded(_ids(5));
        assertFalse(vault.isHeld(5));
    }

    function test_rewards_proRataByShares() public {
        _depositL1(alice, 1);
        _depositL1(bob, 5);
        _depositL1(bob, 6);
        // alice 1/3, bob 2/3
        staking.fund(address(vault), 300e18);

        assertEq(vault.pendingRewards(alice), 100e18);
        assertEq(vault.pendingRewards(bob), 200e18);

        vm.prank(alice);
        assertEq(vault.claimRewards(), 100e18);
        vm.prank(bob);
        assertEq(vault.claimRewards(), 200e18);
        assertEq(sqk.balanceOf(alice), 100e18);
        assertEq(sqk.balanceOf(bob), 200e18);
        assertEq(vault.totalRewardsPaid(), 300e18);
        assertEq(vault.accountedBalance(), 0);
        // Second claim yields nothing.
        vm.prank(alice);
        assertEq(vault.claimRewards(), 0);
    }

    function test_rewards_claimToRecipient() public {
        _depositL1(alice, 1);
        staking.fund(address(vault), 10e18);
        vm.prank(alice);
        uint256 got = vault.claimRewards(carol);
        assertEq(got, 10e18);
        assertEq(sqk.balanceOf(carol), 10e18);
        assertEq(sqk.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        vault.claimRewards(address(0));
    }

    function test_rewards_lateDepositorCannotSnipeUnsettledRewards() public {
        _depositL1(alice, 1);
        // Rewards accrue at the staking layer but nobody has harvested yet.
        staking.fund(address(vault), 90e18);
        // Bob deposits twice alice's power.
        vm.prank(bob);
        vault.deposit(_ids(5, 6));
        // deposit settled first: everything before it belongs to alice.
        assertEq(vault.pendingRewards(alice), 90e18);
        assertEq(vault.pendingRewards(bob), 0);
        // New rewards split 1:2.
        staking.fund(address(vault), 30e18);
        assertEq(vault.pendingRewards(alice), 100e18);
        assertEq(vault.pendingRewards(bob), 20e18);
    }

    function test_rewards_transferSettlesBothSides() public {
        _depositL1(alice, 1);
        staking.fund(address(vault), 50e18);
        // Alice hands half her shares to carol while 50 SQK is unsettled.
        vm.prank(alice);
        vault.transfer(carol, L1_POWER / 2);
        assertEq(vault.unclaimedRewards(alice), 50e18, "sender keeps what accrued before the transfer");
        assertEq(vault.pendingRewards(carol), 0);
        staking.fund(address(vault), 40e18);
        assertEq(vault.pendingRewards(alice), 70e18);
        assertEq(vault.pendingRewards(carol), 20e18);
        vm.prank(carol);
        assertEq(vault.claimRewards(), 20e18);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 70e18);
    }

    function test_rewards_transferFromSettlesToo() public {
        _depositL1(alice, 1);
        staking.fund(address(vault), 10e18);
        vm.prank(alice);
        vault.approve(bob, L1_POWER);
        vm.prank(bob);
        vault.transferFrom(alice, bob, L1_POWER);
        assertEq(vault.pendingRewards(alice), 10e18);
        assertEq(vault.pendingRewards(bob), 0);
        assertEq(vault.balanceOf(bob), L1_POWER);
    }

    function test_rewards_exitByTransferMovesFutureStream() public {
        _depositL1(alice, 1);
        vm.prank(alice);
        vault.transfer(bob, L1_POWER);
        staking.fund(address(vault), 10e18);
        assertEq(vault.pendingRewards(alice), 0);
        assertEq(vault.pendingRewards(bob), 10e18);
    }

    function test_rewards_directDonationIsSharedAtNextSettle() public {
        _depositL1(alice, 1);
        sqk.mint(address(vault), 5e18);
        assertEq(vault.pendingRewards(alice), 5e18);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 5e18);
    }

    function test_rewards_noSharesNoIndexBump() public {
        // SQK arriving before any share exists stays in the vault until the first holders settle.
        sqk.mint(address(vault), 7e18);
        vault.harvest();
        assertEq(vault.rewardIndex(), 0);
        _depositL1(alice, 1);
        // Deposit settled before minting (supply 0 then) so it is picked up by the next settle.
        assertEq(vault.pendingRewards(alice), 7e18);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 7e18);
    }

    function test_rewards_mergeDoesNotDisturbAccounting() public {
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        _depositL1(bob, 5);
        staking.fund(address(vault), 30e18);
        vm.prank(strategist);
        vault.mergeStep(1, 2);
        assertEq(vault.pendingRewards(alice), 20e18);
        assertEq(vault.pendingRewards(bob), 10e18);
    }

    // ---------------------------------------------------------------- permanent reserve

    function test_noNftWithdrawalSurfaceExists() public {
        _depositL1(alice, 1);
        // Neither owner nor depositor can get the NFT back through the vault: there is no such
        // function. Pulling through staking directly also fails: the staker of record is the vault.
        vm.prank(owner);
        vm.expectRevert("staking: not staker");
        staking.withdraw(address(nft), _ids(1));
        vm.prank(alice);
        vm.expectRevert("staking: not staker");
        staking.withdraw(address(nft), _ids(1));
        assertEq(nft.ownerOf(1), address(staking));
    }

    // ---------------------------------------------------------------- admin

    function test_setStrategist_onlyOwnerAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setStrategist(alice);

        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.ZeroAddress.selector);
        vault.setStrategist(address(0));

        vm.expectEmit(true, true, false, false, address(vault));
        emit HamsterMiningReserve.StrategistUpdated(strategist, carol);
        vm.prank(owner);
        vault.setStrategist(carol);
        assertEq(vault.strategist(), carol);

        // Old strategist loses the role.
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, strategist));
        vault.mergeStep(1, 2);
        vm.prank(carol);
        vault.mergeStep(1, 2);
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.acceptOwnership();
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
    }

    function test_ownershipTransfer_movesDefaultStrategistWithOwner() public {
        // Fresh vault: strategist defaults to the owner.
        HamsterMiningReserve fresh = new HamsterMiningReserve(
            owner, address(nft), address(staking), address(emission), address(core), address(sqk)
        );
        assertEq(fresh.strategist(), owner);
        vm.prank(owner);
        fresh.transferOwnership(bob);
        assertEq(fresh.strategist(), owner, "pending transfer changes nothing");
        vm.expectEmit(true, true, false, false, address(fresh));
        emit HamsterMiningReserve.StrategistUpdated(owner, bob);
        vm.prank(bob);
        fresh.acceptOwnership();
        assertEq(fresh.owner(), bob);
        assertEq(fresh.strategist(), bob);

        // The former owner has no privilege left.
        vm.prank(alice);
        nft.setApprovalForAll(address(fresh), true);
        vm.prank(alice);
        fresh.deposit(_ids(1, 2));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, owner));
        fresh.mergeStep(1, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        fresh.setStrategist(owner);
        vm.prank(bob);
        fresh.mergeStep(1, 2);
        assertEq(nft.level(1), 2);
    }

    function test_ownershipTransfer_keepsExplicitStrategist() public {
        // `vault` has an explicitly appointed strategist; a handover leaves it in place.
        vm.prank(owner);
        vault.transferOwnership(bob);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.strategist(), strategist);
        vm.prank(alice);
        vault.deposit(_ids(1, 2));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, owner));
        vault.mergeStep(1, 2);
        vm.prank(strategist);
        vault.mergeStep(1, 2);
    }

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.RenounceDisabled.selector);
        vault.renounceOwnership();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);
    }

    // ---------------------------------------------------------------- reentrancy

    function test_reentrancy_transferDuringSettleIsBlocked() public {
        ReenteringEmission evil = new ReenteringEmission();
        HamsterMiningReserve v =
            new HamsterMiningReserve(owner, address(nft), address(staking), address(evil), address(core), address(sqk));
        evil.setTarget(v);
        vm.prank(alice);
        nft.setApprovalForAll(address(v), true);
        vm.prank(alice);
        v.deposit(_ids(1));
        // The emission mock tries to call v.harvest() re-entrantly from checkpoint(); the guard
        // makes that inner call revert, the try/catch swallows it and the outer call completes.
        vm.prank(alice);
        v.transfer(bob, 1);
        assertTrue(evil.sawReentrancyRevert());
    }

    // ---------------------------------------------------------------- fuzz / invariants

    function testFuzz_sharesTrackPowerFraction(uint8 aliceCount, uint8 bobCount) public {
        aliceCount = uint8(bound(aliceCount, 1, 6));
        bobCount = uint8(bound(bobCount, 1, 6));
        address a = makeAddr("fa");
        address b = makeAddr("fb");
        uint256 af = _give(a, aliceCount);
        uint256 bf = _give(b, bobCount);
        uint256[] memory aIds = new uint256[](aliceCount);
        for (uint256 i; i < aliceCount; ++i) {
            aIds[i] = af + i;
        }
        uint256[] memory bIds = new uint256[](bobCount);
        for (uint256 i; i < bobCount; ++i) {
            bIds[i] = bf + i;
        }
        vm.prank(a);
        vault.deposit(aIds);
        // Merge the first alice pair if possible: NAV rises before bob enters.
        if (aliceCount >= 2) {
            vm.prank(strategist);
            vault.mergeStep(aIds[0], aIds[1]);
        }
        uint256 powerBefore = vault.totalPower();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(b);
        uint256 shares = vault.deposit(bIds);
        uint256 added = vault.totalPower() - powerBefore;
        assertEq(added, uint256(bobCount) * L1_POWER);
        assertEq(shares, (added * supplyBefore) / powerBefore);
        // Bob's power fraction equals his share fraction (down to round-down dust).
        uint256 byShares = (vault.balanceOf(b) * vault.totalPower()) / vault.totalSupply();
        assertLe(byShares, added);
        assertGe(byShares + 2, added);
    }

    function testFuzz_rewardConservation(uint96 r1, uint96 r2, uint96 moveBps) public {
        r1 = uint96(bound(r1, 0, 1e24));
        r2 = uint96(bound(r2, 0, 1e24));
        uint256 move = bound(moveBps, 0, 10_000);
        _depositL1(alice, 1);
        vm.prank(bob);
        vault.deposit(_ids(5, 6));
        staking.fund(address(vault), r1);
        vm.prank(alice);
        vault.transfer(carol, (L1_POWER * move) / 10_000);
        staking.fund(address(vault), r2);
        uint256 paid;
        vm.prank(alice);
        paid += vault.claimRewards();
        vm.prank(bob);
        paid += vault.claimRewards();
        vm.prank(carol);
        paid += vault.claimRewards();
        uint256 total = uint256(r1) + uint256(r2);
        assertLe(paid, total, "never pays more than received");
        assertLe(total - paid, 3, "dust only");
        assertEq(paid, vault.totalRewardsPaid());
        assertEq(sqk.balanceOf(address(vault)), total - paid);
        // Nobody can claim again.
        vm.prank(alice);
        assertEq(vault.claimRewards(), 0);
        vm.prank(bob);
        assertEq(vault.claimRewards(), 0);
        vm.prank(carol);
        assertEq(vault.claimRewards(), 0);
    }
}

/// @dev Emission stand-in whose checkpoint() re-enters the vault.
contract ReenteringEmission {
    HamsterMiningReserve public target;
    bool public sawReentrancyRevert;

    function setTarget(HamsterMiningReserve t) external {
        target = t;
    }

    function implementationCodeVersion() external pure returns (uint256) {
        return 9;
    }

    function checkpointStatus() external pure returns (bool, uint64, bool) {
        return (false, 0, false);
    }

    function checkpoint() external {
        if (address(target) == address(0)) return;
        try target.harvest() {}
        catch (bytes memory reason) {
            if (bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector) sawReentrancyRevert = true;
        }
    }
}

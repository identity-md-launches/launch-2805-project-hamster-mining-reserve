// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveFixture} from "./helpers/ReserveFixture.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {ProgrammableStaking, AdversarialSQK} from "./mocks/AdversarialGraph.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Synthetic graph faults and powers test the vault, not undocumented live power levels.
/// forge-config: default.fuzz.runs = 1000
contract ReserveDependenciesTest is ReserveFixture {
    ProgrammableStaking internal program;

    function setUp() public override {
        super.setUp();
        _replaceStaking();
    }

    function _replaceStaking() internal {
        program = new ProgrammableStaking(nft, sqk, address(emission));
        vault = new HamsterMiningReserve(
            owner, address(nft), address(program), address(emission), address(core), address(sqk)
        );
        vm.prank(owner);
        vault.setStrategist(strategist);
    }

    function _assertPairUntouched(uint256 first) internal view {
        for (uint256 i; i < 2; ++i) {
            assertEq(nft.ownerOf(first + i), address(program));
            assertEq(program.stakerOf(first + i), address(vault));
            assertEq(nft.level(first + i), 1);
            assertTrue(vault.isHeld(first + i));
        }
        assertEq(vault.heldCount(), 2);
        assertEq(vault.totalPower(), 2 * L1);
        assertEq(vault.totalSupply(), 2 * L1);
        assertEq(vault.balanceOf(alice), 2 * L1);
        assertEq(program.withdrawals(), 0);
        assertEq(program.deposits(), 1);
    }

    function test_failedStakingDepositRestoresCustodyRewardsAndApprovalThenCanRetry() public {
        uint256 first = _give(alice, 2);
        program.setFailures(true, false, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProgrammableStaking.DependencyFailure.selector, 1));
        vault.deposit(_ids(first, 2));
        assertEq(nft.ownerOf(first), alice);
        assertEq(nft.ownerOf(first + 1), alice);
        assertEq(vault.heldCount(), 0);
        assertFalse(vault.isHeld(first));
        assertFalse(vault.isHeld(first + 1));
        assertEq(vault.totalSupply(), 0);
        assertFalse(nft.isApprovedForAll(address(vault), address(program)));
        program.setFailures(false, false, false);
        vm.prank(alice);
        vault.deposit(_ids(first, 2));
        _assertPairUntouched(first);
    }

    function test_failedWithdrawRestoresPreMergeSettlement() public {
        uint256 first = _deposit(alice, 2);
        program.fund(address(vault), 9e18);
        program.setFailures(false, true, false);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(ProgrammableStaking.DependencyFailure.selector, 2));
        vault.mergeStep(first, first + 1);
        _assertPairUntouched(first);
        assertEq(program.claimable(address(vault)), 9e18);
        assertEq(vault.rewardIndex(), 0);
        assertEq(vault.accountedBalance(), 0);
    }

    function test_failedRestakeRestoresBurnedDonorAndSurvivorLevel() public {
        uint256 first = _deposit(alice, 2);
        program.setFailures(true, false, false);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(ProgrammableStaking.DependencyFailure.selector, 1));
        vault.mergeStep(first, first + 1);
        _assertPairUntouched(first);
        program.setFailures(false, false, false);
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        assertEq(vault.totalPower(), 2200e18);
        assertEq(vault.heldCount(), 1);
    }

    function test_equalPowerMergeIsRejectedNotJustDecreasingPower() public {
        uint256 first = _deposit(alice, 2);
        program.setPower(2, 2000e18);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.PowerDidNotIncrease.selector, 2000e18, 2000e18));
        vault.mergeStep(first, first + 1);
        _assertPairUntouched(first);
    }

    function test_positivePowerButZeroRoundedSharesRevertsWithoutTakingNft() public {
        // Small synthetic powers isolate the integer rounding boundary without storage edits.
        program.setPower(1, 1);
        program.setPower(2, 3);
        uint256 first = _deposit(alice, 2);
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        uint256 id = _give(bob, 1);
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.NoPowerAdded.selector);
        vault.deposit(_ids(id, 1));
        assertEq(nft.ownerOf(id), bob);
        assertFalse(vault.isHeld(id));
        assertEq(vault.totalPower(), 3);
        assertEq(vault.totalSupply(), 2);
        assertEq(vault.heldCount(), 1);
    }

    function test_depositSettlesExactlyOnceBeforeMinting() public {
        _deposit(alice, 1);
        program.fund(address(vault), 25e18);
        uint256 claimsBefore = program.claims();
        uint256 checkpointsBefore = emission.checkpoints();
        _deposit(bob, 1);
        assertEq(program.claims(), claimsBefore + 1);
        assertEq(emission.checkpoints(), checkpointsBefore + 1);
        assertEq(vault.pendingRewards(alice), 25e18);
        assertEq(vault.pendingRewards(bob), 0);
        assertEq(vault.holderIndex(bob), vault.rewardIndex());
    }

    function testFuzz_unknownHigherLevelCurveIsMeasuredAtNav(uint8 levelSeed, uint96 powerSeed, uint96 gainSeed)
        public
    {
        uint256 level = bound(levelSeed, 2, 9);
        uint256 power = bound(powerSeed, 1e18, 1e26);
        uint256 gain = bound(gainSeed, 1, power * 2);
        program.setPower(level, power);
        program.setPower(level + 1, power * 2 + gain);
        uint256 first = nft.mintAtLevel(alice, level);
        nft.mintAtLevel(alice, level);
        uint256 newId = nft.mintAtLevel(bob, level);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(vault), true);
        vault.deposit(_ids(first, 2));
        vm.stopPrank();
        uint256 originalShares = vault.totalSupply();
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        assertEq(vault.totalSupply(), originalShares);
        assertEq(vault.totalPower(), 2 * power + gain);
        assertEq(nft.level(first), level + 1);
        uint256 powerBefore = vault.totalPower();
        vm.startPrank(bob);
        nft.setApprovalForAll(address(vault), true);
        uint256 minted = vault.deposit(_ids(newId, 1));
        vm.stopPrank();
        uint256 delta = vault.totalPower() - powerBefore;
        assertEq(delta, power);
        // Cross-products specify rounding bounds and prevent dilution without copying the division.
        assertGt(minted, 0);
        assertLe(minted * powerBefore, delta * originalShares);
        assertGt((minted + 1) * powerBefore, delta * originalShares);
        assertGe(vault.totalPower() * originalShares, powerBefore * vault.totalSupply());
        assertEq(vault.balanceOf(alice), originalShares);
        assertEq(vault.heldCount(), 2);
    }

    function _guardedCall(uint256 choice) internal view returns (bytes memory) {
        choice %= 8;
        if (choice == 0) return abi.encodeCall(vault.deposit, (new uint256[](0)));
        if (choice == 1) return abi.encodeCall(vault.mergeStep, (1, 2));
        if (choice == 2) return abi.encodeCall(vault.harvest, ());
        if (choice == 3) return abi.encodeCall(vault.poke, ());
        if (choice == 4) return abi.encodeWithSignature("claimRewards()");
        if (choice == 5) return abi.encodeWithSignature("claimRewards(address)", bob);
        if (choice == 6) return abi.encodeCall(vault.transfer, (bob, 0));
        return abi.encodeCall(vault.transferFrom, (alice, bob, 0));
    }

    function test_allGuardedEntrypointsRejectCallbacksFromDepositWithdrawAndClaim() public {
        for (uint256 phase = 1; phase <= 3; ++phase) {
            for (uint256 action; action < 8; ++action) {
                uint256 first = _deposit(alice, 2);
                program.setCallback(address(vault), _guardedCall(action), uint8(phase));
                if (phase == 1) {
                    _deposit(bob, 1);
                } else if (phase == 2) {
                    vm.prank(strategist);
                    vault.mergeStep(first, first + 1);
                } else {
                    vault.harvest();
                }
                assertTrue(program.blockedReentry(), "callback must hit the reentrancy guard");
                program.setCallback(address(0), "", 0);
            }
        }
    }

    function test_falseReturningRewardTransferRestoresDebtAndCanBeRetried() public {
        _payoutFailure(1);
    }

    function test_revertingRewardTransferRestoresDebtAndCanBeRetried() public {
        _payoutFailure(2);
    }

    function _payoutFailure(uint8 mode) internal {
        AdversarialSQK bad = new AdversarialSQK();
        sqk = bad;
        _replaceStaking();
        _deposit(alice, 1);
        // Transfer fault concerns vault payouts only; the reward has already been harvested.
        program.fund(address(vault), 12e18);
        vault.harvest();
        bad.configure(mode, address(0), "");
        if (mode == 1) {
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        } else {
            vm.expectRevert("SQK transfer unavailable");
        }
        vm.prank(alice);
        vault.claimRewards();
        assertEq(vault.pendingRewards(alice), 12e18);
        assertEq(vault.accountedBalance(), 12e18);
        assertEq(vault.totalRewardsPaid(), 0);
        assertEq(sqk.balanceOf(address(vault)), 12e18);
        assertEq(sqk.balanceOf(alice), 0);
        bad.configure(0, address(0), "");
        vm.prank(alice);
        assertEq(vault.claimRewards(), 12e18);
        assertEq(vault.pendingRewards(alice), 0);
    }

    function test_allGuardedEntrypointsRejectRewardPayoutCallbacks() public {
        AdversarialSQK bad = new AdversarialSQK();
        sqk = bad;
        _replaceStaking();
        _deposit(alice, 1);
        for (uint256 action; action < 8; ++action) {
            bad.configure(0, address(0), "");
            program.fund(address(vault), 1e18);
            vault.harvest();
            bad.configure(3, address(vault), _guardedCall(action));
            vm.prank(alice);
            assertEq(vault.claimRewards(bob), 1e18);
            assertTrue(bad.blockedReentry());
            assertEq(vault.pendingRewards(alice), 0);
        }
        assertEq(sqk.balanceOf(bob), 8e18);
        assertEq(vault.totalRewardsPaid(), 8e18);
        assertEq(vault.balanceOf(alice), L1);
    }
}

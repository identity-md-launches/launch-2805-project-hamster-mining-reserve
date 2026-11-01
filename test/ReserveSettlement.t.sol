// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveFixture} from "./helpers/ReserveFixture.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {MockSQK, MockSqueekNFT} from "./mocks/MockSqueekchain.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Staking stand-in whose `claim` and `claimable` answers are scripted, to probe how the
///      vault decides whether settlement succeeded. L1 = 1000e18 like the observed v9 curve.
contract ScriptedStaking is IERC721Receiver {
    MockSqueekNFT public immutable nft;
    MockSQK public immutable sqk;
    mapping(address => uint256) public accountPower;
    mapping(address => uint256) internal owed;
    /// 0 pays, 1 reverts, 2 reverts only when nothing is owed, 3 succeeds without paying.
    uint8 public claimMode;
    /// 0 answers, 1 reverts, 2 returns no data.
    uint8 public viewMode;

    constructor(MockSqueekNFT n, MockSQK t) {
        nft = n;
        sqk = t;
    }

    function script(uint8 c, uint8 v) external {
        claimMode = c;
        viewMode = v;
    }

    function fund(address account, uint256 amount) external {
        sqk.mint(address(this), amount);
        owed[account] += amount;
    }

    function deposit(address, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            nft.transferFrom(msg.sender, address(this), ids[i]);
            accountPower[msg.sender] += 1000e18;
        }
    }

    function withdraw(address, uint256[] calldata) external pure {
        revert("unused");
    }

    function claim(address account) external returns (uint256 amount) {
        if (claimMode == 1) revert("claim down");
        amount = owed[account];
        if (claimMode == 2 && amount == 0) revert("nothing to claim");
        if (claimMode == 3) return 0;
        owed[account] = 0;
        if (amount != 0) sqk.transfer(account, amount);
    }

    function claimable(address account) external view returns (uint256) {
        if (viewMode == 1) revert("view down");
        if (viewMode == 2) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return owed[account];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract ReserveSettlementTest is ReserveFixture {
    ScriptedStaking internal scripted;
    HamsterMiningReserve internal sv;

    function setUp() public override {
        super.setUp();
        scripted = new ScriptedStaking(nft, sqk);
        sv = new HamsterMiningReserve(
            owner, address(nft), address(scripted), address(emission), address(core), address(sqk)
        );
    }

    function _scriptedDeposit(address actor) internal returns (uint256 id) {
        id = nft.mint(actor, 1);
        vm.startPrank(actor);
        nft.setApprovalForAll(address(sv), true);
        sv.deposit(_ids(id, 1));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- settlement decision

    function test_claimDownAndClaimableViewRevertingFreezesEvenWithNothingOwed() public {
        _scriptedDeposit(alice);
        uint256 id = nft.mint(bob, 1);
        vm.prank(bob);
        nft.setApprovalForAll(address(sv), true);
        scripted.script(1, 1);
        // "Unknown" is treated as unsettled: balance changes stop, keeper/claim paths do not.
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        sv.deposit(_ids(id, 1));
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        sv.transfer(bob, 1);
        sv.harvest();
        vm.prank(alice);
        assertEq(sv.claimRewards(), 0);
        // Recovery of either answer unfreezes.
        scripted.script(1, 0);
        vm.prank(bob);
        sv.deposit(_ids(id, 1));
        assertEq(sv.balanceOf(bob), L1);
    }

    function test_claimDownAndClaimableViewReturningNoDataFreezes() public {
        _scriptedDeposit(alice);
        scripted.script(1, 2);
        vm.prank(alice);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        sv.transfer(bob, L1);
        assertEq(sv.balanceOf(alice), L1);
    }

    function test_claimThatRevertsOnlyWhenNothingIsOwedDoesNotFreeze() public {
        // Some reward contracts revert "nothing to claim"; that must not block exits.
        scripted.script(2, 0);
        _scriptedDeposit(alice);
        _scriptedDeposit(bob);
        vm.prank(alice);
        assertTrue(sv.transfer(carol, L1));
        assertEq(sv.balanceOf(carol), L1);
        // When something is owed the same claim pays and splits by the holders of record.
        scripted.fund(address(sv), 30e18);
        vm.prank(bob);
        sv.transfer(carol, L1);
        assertEq(sv.pendingRewards(carol), 15e18);
        assertEq(sv.unclaimedRewards(bob), 15e18);
        assertEq(sv.unclaimedRewards(carol), 15e18);
    }

    // ---------------------------------------------------------------- frozen ledger, transfer side

    function test_frozenLedgerRefusesZeroSelfAndDelegatedTransfersAndKeepsOldOwnerReward() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 100e18);
        staking.setRevertOnClaim(true);

        vm.startPrank(alice);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.transfer(bob, 0);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.transfer(alice, L1);
        // Approval does not touch balances or rewards, so it stays available.
        vault.approve(bob, type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.transferFrom(alice, bob, L1);
        assertEq(vault.allowance(alice, bob), type(uint256).max);

        // Recovery: the full exit happens after settlement, so the 100 SQK stays with alice.
        staking.setRevertOnClaim(false);
        vm.prank(bob);
        vault.transferFrom(alice, bob, L1);
        assertEq(vault.balanceOf(bob), L1);
        assertEq(vault.pendingRewards(alice), 100e18);
        assertEq(vault.pendingRewards(bob), 0);
        vm.prank(alice);
        assertEq(vault.claimRewards(carol), 100e18);
        assertEq(sqk.balanceOf(carol), 100e18);
        vm.prank(bob);
        assertEq(vault.claimRewards(), 0);
    }

    function test_frozenLedgerStillPaysAlreadyIndexedRewards() public {
        _deposit(alice, 1);
        staking.fund(address(vault), 40e18);
        vault.harvest(); // 40 indexed
        staking.fund(address(vault), 60e18); // 60 stuck once the claim breaks
        staking.setRevertOnClaim(true);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 40e18);
        assertEq(staking.claimable(address(vault)), 60e18);
        staking.setRevertOnClaim(false);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 60e18);
        assertEq(sqk.balanceOf(address(vault)), 0);
    }

    /// @dev Equal-power late depositor across an outage, all reward sizes: the newcomer gets
    ///      nothing of what accrued before they joined; the earlier holder gets all of it.
    function testFuzz_outageNeverHandsEarlierRewardsToLaterDepositor(uint96 rewardSeed, uint96 laterSeed) public {
        uint256 reward = bound(rewardSeed, 1, 1e27);
        uint256 later = bound(laterSeed, 0, 1e27);
        _deposit(alice, 1);
        uint256 bobId = _give(bob, 1);
        staking.fund(address(vault), reward);
        staking.setRevertOnClaim(true);
        vm.prank(bob);
        vm.expectRevert(HamsterMiningReserve.RewardsUnsettled.selector);
        vault.deposit(_ids(bobId, 1));
        staking.setRevertOnClaim(false);
        vm.prank(bob);
        vault.deposit(_ids(bobId, 1));
        staking.fund(address(vault), later);
        vm.prank(alice);
        uint256 a = vault.claimRewards();
        vm.prank(bob);
        uint256 b = vault.claimRewards();
        assertApproxEqAbs(a, reward + later / 2, 2);
        assertApproxEqAbs(b, later / 2, 2);
        assertLe(a + b, reward + later);
    }

    // ---------------------------------------------------------------- stakeStranded edges

    function test_stakeStrandedDuplicateInBatchRollsBackWholeBatch() public {
        _deposit(alice, 1);
        uint256 id = nft.mint(bob, 1);
        vm.prank(bob);
        nft.transferFrom(bob, address(vault), id);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStranded.selector, id));
        vault.stakeStranded(ids);
        assertFalse(vault.isHeld(id));
        assertEq(vault.heldCount(), 1);
        assertEq(nft.ownerOf(id), address(vault));
    }

    function test_stakeStrandedRejectsBurnedDonorAndStakedTokens() public {
        uint256 first = _deposit(alice, 2);
        vm.prank(strategist);
        vault.mergeStep(first, first + 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, first + 1));
        vault.stakeStranded(_ids(first + 1, 1));
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStranded.selector, first));
        vault.stakeStranded(_ids(first, 1));
        assertEq(vault.heldCount(), 1);
    }

    function test_stakeStrandedBeforeAnyDepositIsAGiftToTheFirstDepositorAndNavPricesLaterOnes() public {
        uint256 gift = nft.mint(carol, 1);
        vm.prank(carol);
        nft.transferFrom(carol, address(vault), gift);
        vault.stakeStranded(_ids(gift, 1));
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalPower(), L1);

        uint256 first = _give(alice, 1);
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(_ids(first, 1));
        // Brief formula: first deposit mints deltaPower, so alice also owns the gifted power.
        assertEq(aliceShares, L1);
        assertEq(vault.powerPerShare(), 2e18);

        uint256 second = _give(bob, 1);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(_ids(second, 1));
        assertEq(bobShares, L1 / 2, "later depositor priced at NAV, no dilution");
        assertEq(vault.totalPower(), 3 * L1);
    }

    function test_stakeStrandedDuringFrozenOutageAddsPowerWithoutMovingRewards() public {
        _deposit(alice, 1);
        uint256 id = nft.mint(bob, 1);
        vm.prank(bob);
        nft.transferFrom(bob, address(vault), id);
        staking.fund(address(vault), 10e18);
        staking.setRevertOnClaim(true);
        vm.prank(bob);
        vault.stakeStranded(_ids(id, 1));
        assertEq(vault.totalPower(), 2 * L1);
        assertEq(vault.balanceOf(bob), 0);
        staking.setRevertOnClaim(false);
        vm.prank(alice);
        assertEq(vault.claimRewards(), 10e18);
        vm.prank(bob);
        assertEq(vault.claimRewards(), 0);
    }

    // ---------------------------------------------------------------- ownership edges

    function test_renounceByNonOwnerIsUnauthorizedAndOwnerKeepsControl() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.renounceOwnership();
        vm.prank(owner);
        vm.expectRevert(HamsterMiningReserve.RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner);
    }

    function test_cancelledHandoverLeavesDefaultStrategistWithOwner() public {
        // Fresh vault: strategist defaults to the owner.
        assertEq(sv.strategist(), owner);
        vm.startPrank(owner);
        sv.transferOwnership(alice);
        assertEq(sv.strategist(), owner, "pending transfer moves nothing");
        sv.transferOwnership(address(0)); // Ownable2Step cancel
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        sv.acceptOwnership();
        assertEq(sv.strategist(), owner);
        assertEq(sv.owner(), owner);
    }

    function test_completedHandoverStripsOldOwnerOfMergeAndStrategistRights() public {
        vm.prank(owner);
        sv.transferOwnership(alice);
        vm.prank(alice);
        sv.acceptOwnership();
        assertEq(sv.strategist(), alice);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, owner));
        sv.mergeStep(1, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        sv.setStrategist(owner);
    }
}

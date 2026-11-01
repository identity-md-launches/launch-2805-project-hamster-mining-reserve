// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HamsterMiningReserve} from "../../src/HamsterMiningReserve.sol";
import {ISqueekNFT, ISqueekStaking, ISqueekEmission, ISqueekCore} from "../../src/interfaces/ISqueekchain.sol";
import {SepoliaAddresses} from "../../script/SepoliaAddresses.sol";

/// @notice Integration tests against the live Squeekchain v9 graph (GRAPH C) on a Sepolia fork.
///
/// The fork is created from a public RPC pinned to a block where holder 0x5989...Ff54 owns Squeek
/// tokens 1-10 at level 1 (checked on 2026-11-01). When no RPC is reachable (the independent verifier
/// runs with no network) every test here is marked skipped instead of failing; the offline suite in
/// test/HamsterMiningReserve.t.sol carries the behavioural coverage in that case.
contract SepoliaForkTest is Test {
    string constant RPC = "https://ethereum-sepolia-rpc.publicnode.com";
    uint256 constant PINNED_BLOCK = 12_038_095;

    /// @dev EOA observed holding Squeek tokens 1..10 at level 1 at PINNED_BLOCK.
    address constant HOLDER = 0x598958Abf7d8DB8Dd468cb53DD6BA705581bFf54;

    uint256 constant L1_POWER = 1000e18;
    uint256 constant MERGE_GAIN_L1_TO_L2 = 200e18;

    ISqueekNFT nft = ISqueekNFT(SepoliaAddresses.SQUEEK_NFT);
    ISqueekStaking staking = ISqueekStaking(SepoliaAddresses.SQUEEK_STAKING);
    ISqueekEmission emission = ISqueekEmission(SepoliaAddresses.SQUEEK_EMISSION);
    ISqueekCore core = ISqueekCore(SepoliaAddresses.SQUEEK_CORE);
    IERC20 sqk = IERC20(SepoliaAddresses.SQK);

    address owner = makeAddr("owner");
    address strategist = makeAddr("strategist");
    address buyer = makeAddr("buyer");

    HamsterMiningReserve vault;
    bool forkReady;

    function setUp() public {
        try vm.createSelectFork(RPC, PINNED_BLOCK) {
            forkReady = true;
        } catch {
            // Pinned block not served (pruned node): fall back to latest.
            try vm.createSelectFork(RPC) {
                forkReady = true;
            } catch {
                forkReady = false;
            }
        }
        if (!forkReady) return;

        vault = new HamsterMiningReserve(
            owner,
            SepoliaAddresses.SQUEEK_NFT,
            SepoliaAddresses.SQUEEK_STAKING,
            SepoliaAddresses.SQUEEK_EMISSION,
            SepoliaAddresses.SQUEEK_CORE,
            SepoliaAddresses.SQK
        );
        vm.prank(owner);
        vault.setStrategist(strategist);
        vm.prank(HOLDER);
        nft.setApprovalForAll(address(vault), true);
    }

    modifier onFork() {
        if (!forkReady) {
            vm.skip(true);
            return;
        }
        _;
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

    /// @dev Picks two level-1 tokens the holder still owns (robust to the fork moving to a later block).
    function _twoL1() internal view returns (uint256 a, uint256 b) {
        uint256 found;
        for (uint256 id = 1; id <= 40 && found < 2; ++id) {
            (bool ok, bytes memory data) = address(nft).staticcall(abi.encodeWithSelector(nft.ownerOf.selector, id));
            if (!ok || data.length < 32 || abi.decode(data, (address)) != HOLDER) continue;
            if (nft.level(id) != 1) continue;
            if (found == 0) a = id;
            else b = id;
            ++found;
        }
        require(found == 2, "fork: holder no longer has two L1 Squeeks; update HOLDER");
    }

    // ---------------------------------------------------------------- graph facts

    function test_fork_graphConstantsMatchBrief() public onFork {
        assertEq(block.chainid, 11155111);
        assertEq(nft.MAXIMUM_LEVEL(), 10);
        assertEq(emission.implementationCodeVersion(), 9);
        assertEq(core.implementationCodeVersion(), 3);
        assertEq(staking.genesis(), SepoliaAddresses.SQUEEK_NFT);
        assertEq(staking.mining(), SepoliaAddresses.SQUEEK_EMISSION);
        assertEq(staking.token(), SepoliaAddresses.SQK);
        assertEq(nft.mining(), SepoliaAddresses.SQUEEK_EMISSION);
        assertEq(nft.sqkCore(), SepoliaAddresses.SQUEEK_CORE);
        (bool ok, bytes memory dec) = SepoliaAddresses.SQK.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(abi.decode(dec, (uint8)), 18);
    }

    function test_fork_vaultGraphHealthView() public onFork {
        (uint256 maxLevel, uint256 emissionVersion, uint256 coreVersion, bool g, bool m, bool t, bool nm, bool nc) =
            vault.graphHealth();
        assertEq(maxLevel, 10);
        assertEq(emissionVersion, 9);
        assertEq(coreVersion, 3);
        assertTrue(g && m && t && nm && nc);
        (bool paused,,) = vault.emissionStatus();
        assertFalse(paused);
    }

    function test_fork_selectorsMatchBrief() public pure {
        assertEq(ISqueekNFT.level.selector, bytes4(0x05c58df2));
        assertEq(ISqueekNFT.merge.selector, bytes4(0xd1c2babb));
        assertEq(ISqueekStaking.deposit.selector, bytes4(0xa71604e8));
        assertEq(ISqueekStaking.withdraw.selector, bytes4(0x8293744b));
        assertEq(ISqueekStaking.claim.selector, bytes4(0x1e83409a));
        assertEq(ISqueekStaking.claimable.selector, bytes4(0x402914f5));
        assertEq(ISqueekStaking.accountPower.selector, bytes4(0x9624178f));
        assertEq(ISqueekEmission.checkpoint.selector, bytes4(0xc2c4c5c1));
    }

    // ---------------------------------------------------------------- power invariants

    function test_fork_stakingOneL1AddsExactly1000e18() public onFork {
        (uint256 a,) = _twoL1();
        uint256 before = staking.accountPower(address(vault));
        assertEq(before, 0);
        vm.prank(HOLDER);
        uint256 shares = vault.deposit(_ids(a));
        assertEq(staking.accountPower(address(vault)) - before, L1_POWER);
        assertEq(shares, L1_POWER);
        assertEq(vault.heldCount(), 1);
        assertEq(nft.ownerOf(a), address(staking));
    }

    function test_fork_mergeTwoL1NetsPlus200e18AndFreesOneNft() public onFork {
        (uint256 a, uint256 b) = _twoL1();
        vm.prank(HOLDER);
        vault.deposit(_ids(a, b));
        uint256 powerBefore = vault.totalPower();
        assertEq(powerBefore, 2 * L1_POWER);
        uint256 heldBefore = vault.heldCount();
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(strategist);
        vault.mergeStep(a, b);

        assertEq(vault.totalPower(), powerBefore + MERGE_GAIN_L1_TO_L2);
        assertEq(vault.heldCount(), heldBefore - 1);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(nft.level(a), 2);
        assertEq(nft.ownerOf(a), address(staking));
        assertFalse(vault.isHeld(b));
        assertTrue(vault.isHeld(a));
        // Donor is burned on the real contract.
        (bool ok,) = address(nft).staticcall(abi.encodeWithSelector(nft.ownerOf.selector, b));
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- full cycle

    function test_fork_depositMergeClaimCycle() public onFork {
        (uint256 a, uint256 b) = _twoL1();

        // deposit
        vm.prank(HOLDER);
        uint256 shares = vault.deposit(_ids(a, b));
        assertEq(shares, 2 * L1_POWER);
        assertEq(vault.balanceOf(HOLDER), shares);

        // anyone pokes: checkpoint + claim; must not revert whatever the emission clock does
        vault.poke();
        vault.harvest();

        // merge
        vm.prank(strategist);
        vault.mergeStep(a, b);
        assertEq(vault.totalPower(), 2 * L1_POWER + MERGE_GAIN_L1_TO_L2);
        assertEq(vault.powerPerShare(), (vault.totalPower() * 1e18) / shares);

        // claim: amount is NOT asserted (testnet emission may be idle); the path must return cleanly
        uint256 sqkBefore = sqk.balanceOf(HOLDER);
        vm.prank(HOLDER);
        uint256 paid = vault.claimRewards();
        assertEq(sqk.balanceOf(HOLDER) - sqkBefore, paid);
        assertEq(vault.pendingRewards(HOLDER), 0);
        assertEq(vault.unclaimedRewards(HOLDER), 0);

        // exit by transferring shares: the future stream moves to the buyer
        vm.prank(HOLDER);
        vault.transfer(buyer, shares);
        assertEq(vault.balanceOf(buyer), shares);
        assertEq(vault.balanceOf(HOLDER), 0);
        vm.prank(buyer);
        uint256 buyerPaid = vault.claimRewards();
        assertEq(buyerPaid, 0, "nothing accrued between transfer and claim in the same block");

        // the NFT stays staked under the vault: permanent reserve
        assertEq(nft.ownerOf(a), address(staking));
        assertEq(vault.heldCount(), 1);
    }

    function test_fork_claimPlumbingAtZero() public onFork {
        // No shares, no power: claim and harvest are clean no-ops on the live graph.
        vault.harvest();
        vm.prank(buyer);
        assertEq(vault.claimRewards(), 0);
        assertEq(staking.claimable(address(vault)), 0);
        assertEq(vault.rewardIndex(), 0);
    }

    // ---------------------------------------------------------------- failure paths on the real graph

    function test_fork_mergeStepRevertsOnLevelMismatchAgainstRealNft() public onFork {
        (uint256 a, uint256 b) = _twoL1();
        // Find a third L1.
        uint256 c;
        for (uint256 id = b + 1; id <= 40; ++id) {
            if (nft.ownerOf(id) == HOLDER && nft.level(id) == 1) {
                c = id;
                break;
            }
        }
        require(c != 0, "fork: need a third L1");
        uint256[] memory three = new uint256[](3);
        three[0] = a;
        three[1] = b;
        three[2] = c;
        vm.prank(HOLDER);
        vault.deposit(three);
        vm.prank(strategist);
        vault.mergeStep(a, b);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.LevelMismatch.selector, 2, 1));
        vault.mergeStep(a, c);
        assertEq(vault.heldCount(), 2);
    }

    function test_fork_depositRevertsForNonOwner() public onFork {
        (uint256 a,) = _twoL1();
        vm.prank(buyer);
        vm.expectRevert();
        vault.deposit(_ids(a));
    }

    function test_fork_mergeStepRevertsForNonStrategist() public onFork {
        (uint256 a, uint256 b) = _twoL1();
        vm.prank(HOLDER);
        vault.deposit(_ids(a, b));
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.NotStrategist.selector, HOLDER));
        vault.mergeStep(a, b);
    }

    function test_fork_plainPushedSqueekCanBeStakedForTheReserve() public onFork {
        (uint256 a, uint256 b) = _twoL1();
        vm.prank(HOLDER);
        vault.deposit(_ids(a));
        // The live NFT accepts a plain transferFrom to the vault (no receiver hook).
        vm.prank(HOLDER);
        nft.transferFrom(HOLDER, address(vault), b);
        assertEq(nft.ownerOf(b), address(vault));
        assertFalse(vault.isHeld(b));
        assertEq(vault.totalPower(), L1_POWER);

        uint256 supply = vault.totalSupply();
        vm.prank(buyer);
        vault.stakeStranded(_ids(b));
        assertEq(vault.totalPower(), 2 * L1_POWER);
        assertEq(vault.totalSupply(), supply);
        assertTrue(vault.isHeld(b));
        assertEq(nft.ownerOf(b), address(staking));
        // It merges like any other held token.
        vm.prank(strategist);
        vault.mergeStep(a, b);
        assertEq(vault.totalPower(), 2 * L1_POWER + MERGE_GAIN_L1_TO_L2);
    }

    function test_fork_vaultRejectsItselfAsRecipient() public onFork {
        (uint256 a,) = _twoL1();
        vm.prank(HOLDER);
        uint256 shares = vault.deposit(_ids(a));
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidRecipient.selector, address(vault)));
        vault.transfer(address(vault), shares);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(HamsterMiningReserve.InvalidRecipient.selector, address(vault)));
        vault.claimRewards(address(vault));
    }

    function test_fork_unsolicitedSafeTransferRejected() public onFork {
        (uint256 a,) = _twoL1();
        vm.prank(HOLDER);
        vm.expectRevert();
        ISqueekNFTSafe(address(nft)).safeTransferFrom(HOLDER, address(vault), a);
        assertEq(nft.ownerOf(a), HOLDER);
    }
}

interface ISqueekNFTSafe {
    function safeTransferFrom(address, address, uint256) external;
}

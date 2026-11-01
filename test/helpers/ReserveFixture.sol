// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterMiningReserve} from "src/HamsterMiningReserve.sol";
import {MockSQK, MockCore, MockEmission, MockSqueekNFT, MockStaking} from "../mocks/MockSqueekchain.sol";

abstract contract ReserveFixture is Test {
    uint256 internal constant L1 = 1000e18;
    address internal owner;
    address internal strategist;
    address internal alice;
    address internal bob;
    address internal carol;
    MockSQK internal sqk;
    MockCore internal core;
    MockEmission internal emission;
    MockSqueekNFT internal nft;
    MockStaking internal staking;
    HamsterMiningReserve internal vault;

    function setUp() public virtual {
        owner = makeAddr("owner");
        strategist = makeAddr("strategist");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
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
    }

    function _ids(uint256 first, uint256 count) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    function _give(address actor, uint256 count) internal returns (uint256 first) {
        first = nft.mint(actor, count);
        vm.prank(actor);
        nft.setApprovalForAll(address(vault), true);
    }

    function _deposit(address actor, uint256 count) internal returns (uint256 first) {
        first = _give(actor, count);
        vm.prank(actor);
        vault.deposit(_ids(first, count));
    }

    function _assertStaked(uint256 id) internal view {
        assertTrue(vault.isHeld(id));
        assertEq(nft.ownerOf(id), address(staking));
        assertEq(staking.stakerOf(id), address(vault));
    }
}

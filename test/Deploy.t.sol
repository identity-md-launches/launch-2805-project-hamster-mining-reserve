// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {DeployHamsterMiningReserve} from "../script/Deploy.s.sol";
import {SepoliaAddresses} from "../script/SepoliaAddresses.sol";

contract DeployTest is Test {
    function test_deploy_sepoliaConfigWiresOwnerAndGraph() public {
        DeployHamsterMiningReserve d = new DeployHamsterMiningReserve();
        // Runs on an empty local chain: the constructor makes no external calls.
        HamsterMiningReserve vault = d.deploy(d.sepoliaConfig());
        assertEq(vault.owner(), SepoliaAddresses.OWNER);
        assertEq(vault.strategist(), SepoliaAddresses.OWNER);
        assertEq(address(vault.nft()), SepoliaAddresses.SQUEEK_NFT);
        assertEq(address(vault.staking()), SepoliaAddresses.SQUEEK_STAKING);
        assertEq(address(vault.emission()), SepoliaAddresses.SQUEEK_EMISSION);
        assertEq(address(vault.core()), SepoliaAddresses.SQUEEK_CORE);
        assertEq(address(vault.rewardToken()), SepoliaAddresses.SQK);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.heldCount(), 0);
        // The deployer / factory never ends up with any role.
        assertTrue(vault.owner() != address(this) && vault.owner() != address(d));
    }

    function test_deploy_runtimeFitsEip170() public {
        DeployHamsterMiningReserve d = new DeployHamsterMiningReserve();
        HamsterMiningReserve vault = d.deploy(d.sepoliaConfig());
        assertLe(address(vault).code.length, 24_576);
    }
}

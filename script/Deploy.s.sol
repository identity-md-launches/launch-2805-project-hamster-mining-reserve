// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {HamsterMiningReserve} from "../src/HamsterMiningReserve.sol";
import {SepoliaAddresses} from "./SepoliaAddresses.sol";

/// @notice Reviewable deployment of HamsterMiningReserve on Sepolia.
/// @dev `run()` only broadcasts with whatever signer the operator passes on the command line
///      (`forge script ... --broadcast --sender ... --ledger` or similar); it reads no environment
///      variables. `deploy(Config)` is the pure deployment step that tests call directly.
contract DeployHamsterMiningReserve is Script {
    struct Config {
        address owner;
        address nft;
        address staking;
        address emission;
        address core;
        address rewardToken;
    }

    function sepoliaConfig() public pure returns (Config memory) {
        return Config({
            owner: SepoliaAddresses.OWNER,
            nft: SepoliaAddresses.SQUEEK_NFT,
            staking: SepoliaAddresses.SQUEEK_STAKING,
            emission: SepoliaAddresses.SQUEEK_EMISSION,
            core: SepoliaAddresses.SQUEEK_CORE,
            rewardToken: SepoliaAddresses.SQK
        });
    }

    function deploy(Config memory cfg) public returns (HamsterMiningReserve vault) {
        vault = new HamsterMiningReserve(cfg.owner, cfg.nft, cfg.staking, cfg.emission, cfg.core, cfg.rewardToken);
    }

    function run() external returns (HamsterMiningReserve vault) {
        require(block.chainid == SepoliaAddresses.CHAIN_ID, "deploy: not Sepolia");
        vm.startBroadcast();
        vault = deploy(sepoliaConfig());
        vm.stopBroadcast();
    }
}

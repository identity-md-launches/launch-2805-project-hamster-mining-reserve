// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Local stand-ins for the Squeekchain v9 graph. They reproduce the mechanics the vault
///         relies on (per-account power, merge burns the donor and raises the survivor, claim pays
///         SQK, permissionless checkpoint) with knobs to force failure paths. They demonstrate
///         local behaviour only; the fork tests exercise the real Sepolia contracts.
contract MockSQK is ERC20 {
    constructor() ERC20("Squeek Token", "SQK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCore {
    uint256 public implementationCodeVersion = 3;
}

contract MockEmission {
    uint256 public implementationCodeVersion = 9;
    bool public corePaused;
    uint64 public nextRound = 798;
    bool public roundSettled;
    bool public revertOnCheckpoint;
    uint256 public checkpoints;
    address public core;

    constructor(address core_) {
        core = core_;
    }

    function setRevertOnCheckpoint(bool v) external {
        revertOnCheckpoint = v;
    }

    function checkpoint() external {
        require(!revertOnCheckpoint, "emission: paused");
        checkpoints += 1;
        nextRound += 1;
        roundSettled = true;
    }

    function checkpointStatus() external view returns (bool, uint64, bool) {
        return (corePaused, nextRound, roundSettled);
    }
}

contract MockSqueekNFT is ERC721 {
    uint256 public constant MAXIMUM_LEVEL = 10;
    address public mining;
    address public sqkCore;
    uint256 public nextId = 1;
    /// @dev Core-block cooldown between merges of the same NFT, in blocks.
    uint256 public cooldownBlocks;
    mapping(uint256 => uint256) public level;
    mapping(uint256 => uint256) public lastMergeBlock;

    error NotOwnerOfBoth();
    error LevelMismatch();
    error Cooldown();
    error MaxLevel();

    constructor(address mining_, address core_) ERC721("Squeek", "SQUEEK") {
        mining = mining_;
        sqkCore = core_;
    }

    function setCooldownBlocks(uint256 b) external {
        cooldownBlocks = b;
    }

    function mint(address to, uint256 count) external returns (uint256 first) {
        first = nextId;
        for (uint256 i; i < count; ++i) {
            uint256 id = nextId++;
            level[id] = 1;
            _mint(to, id);
        }
    }

    function mintAtLevel(address to, uint256 lvl) external returns (uint256 id) {
        id = nextId++;
        level[id] = lvl;
        _mint(to, id);
    }

    function merge(uint256 survivor, uint256 donor) external {
        if (ownerOf(survivor) != msg.sender || ownerOf(donor) != msg.sender) revert NotOwnerOfBoth();
        if (level[survivor] != level[donor]) revert LevelMismatch();
        if (level[survivor] >= MAXIMUM_LEVEL) revert MaxLevel();
        if (cooldownBlocks != 0) {
            if (
                (lastMergeBlock[survivor] != 0 && block.number < lastMergeBlock[survivor] + cooldownBlocks)
                    || (lastMergeBlock[donor] != 0 && block.number < lastMergeBlock[donor] + cooldownBlocks)
            ) revert Cooldown();
        }
        _burn(donor);
        delete level[donor];
        level[survivor] += 1;
        lastMergeBlock[survivor] = block.number;
    }
}

contract MockStaking is IERC721Receiver {
    uint256 public constant POWER_UNIT = 1e18;

    MockSqueekNFT public immutable genesisNft;
    MockSQK public immutable sqk;
    address public mining;

    mapping(address => uint256) public accountPower;
    mapping(address => uint256) public claimable;
    mapping(uint256 => address) public stakerOf;
    /// @dev When set, `deposit` credits zero power: used to prove the vault's NoPowerAdded /
    ///      PowerDidNotIncrease guards.
    bool public zeroPowerMode;
    /// @dev When set, `claim` reverts: proves `harvest()` never reverts.
    bool public revertOnClaim;

    constructor(MockSqueekNFT nft_, MockSQK sqk_, address mining_) {
        genesisNft = nft_;
        sqk = sqk_;
        mining = mining_;
    }

    function genesis() external view returns (address) {
        return address(genesisNft);
    }

    function token() external view returns (address) {
        return address(sqk);
    }

    function setZeroPowerMode(bool v) external {
        zeroPowerMode = v;
    }

    function setRevertOnClaim(bool v) external {
        revertOnClaim = v;
    }

    /// @notice Super-linear power curve observed on v9: L1 = 1000, L2 = 2200 (x1e18).
    ///         Levels above 2 are not observable on Sepolia yet; this mock extrapolates the
    ///         observed x2.2 ratio geometrically (power(L) = 1000 * 2.2^(L-1)) so that merging two
    ///         equal NFTs always strictly gains, as the brief says the curve must.
    function powerOf(uint256 lvl) public pure returns (uint256) {
        uint256 p = 1000 * POWER_UNIT;
        for (uint256 i = 1; i < lvl; ++i) {
            p = (p * 11) / 5;
        }
        return p;
    }

    /// @notice Credits `account` with SQK as if emission paid it. Test harness only.
    function fund(address account, uint256 amount) external {
        sqk.mint(address(this), amount);
        claimable[account] += amount;
    }

    function deposit(address collection, uint256[] calldata ids) external {
        require(collection == address(genesisNft), "staking: collection");
        for (uint256 i; i < ids.length; ++i) {
            genesisNft.transferFrom(msg.sender, address(this), ids[i]);
            stakerOf[ids[i]] = msg.sender;
            if (!zeroPowerMode) accountPower[msg.sender] += powerOf(genesisNft.level(ids[i]));
        }
    }

    function withdraw(address collection, uint256[] calldata ids) external {
        require(collection == address(genesisNft), "staking: collection");
        for (uint256 i; i < ids.length; ++i) {
            require(stakerOf[ids[i]] == msg.sender, "staking: not staker");
            delete stakerOf[ids[i]];
            uint256 p = powerOf(genesisNft.level(ids[i]));
            // Power was credited at deposit time; in zeroPowerMode it was not.
            if (accountPower[msg.sender] >= p) accountPower[msg.sender] -= p;
            else accountPower[msg.sender] = 0;
            genesisNft.safeTransferFrom(address(this), msg.sender, ids[i]);
        }
    }

    function claim(address account) external returns (uint256 amount) {
        require(!revertOnClaim, "staking: claim disabled");
        amount = claimable[account];
        if (amount == 0) return 0;
        claimable[account] = 0;
        sqk.transfer(account, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

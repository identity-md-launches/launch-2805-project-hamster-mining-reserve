// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockSqueekNFT, MockSQK} from "./MockSqueekchain.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Synthetic powers are controlled by the test. No assertion about live L3-L10 is implied.
contract ProgrammableStaking is IERC721Receiver {
    MockSqueekNFT public immutable nft;
    MockSQK public immutable sqk;
    address public immutable mining;
    mapping(uint256 => uint256) public powerAtLevel;
    mapping(uint256 => uint256) public creditedPower;
    mapping(uint256 => address) public stakerOf;
    mapping(address => uint256) public accountPower;
    mapping(address => uint256) public claimable;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public claims;
    bool public failDeposit;
    bool public failWithdraw;
    bool public failClaim;
    address public callbackTarget;
    bytes public callbackData;
    uint8 public callbackPhase;
    bool public blockedReentry;

    error DependencyFailure(uint8 phase);

    constructor(MockSqueekNFT n, MockSQK t, address e) {
        nft = n;
        sqk = t;
        mining = e;
        powerAtLevel[1] = 1000e18;
        powerAtLevel[2] = 2200e18;
    }

    function genesis() external view returns (address) {
        return address(nft);
    }

    function token() external view returns (address) {
        return address(sqk);
    }

    function setPower(uint256 level, uint256 power) external {
        powerAtLevel[level] = power;
    }

    function setFailures(bool d, bool w, bool c) external {
        failDeposit = d;
        failWithdraw = w;
        failClaim = c;
    }

    function setCallback(address target, bytes calldata data, uint8 phase) external {
        callbackTarget = target;
        callbackData = data;
        callbackPhase = phase;
        blockedReentry = false;
    }

    function _callback(uint8 phase) internal {
        if (callbackTarget == address(0) || callbackPhase != phase) return;
        (bool ok, bytes memory reason) = callbackTarget.call(callbackData);
        require(!ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "unguarded callback");
        blockedReentry = true;
    }

    function fund(address account, uint256 amount) external {
        sqk.mint(address(this), amount);
        claimable[account] += amount;
    }

    function deposit(address collection, uint256[] calldata ids) external {
        if (failDeposit) revert DependencyFailure(1);
        require(collection == address(nft), "collection");
        ++deposits;
        _callback(1);
        for (uint256 i; i < ids.length; ++i) {
            nft.transferFrom(msg.sender, address(this), ids[i]);
            stakerOf[ids[i]] = msg.sender;
            uint256 p = powerAtLevel[nft.level(ids[i])];
            creditedPower[ids[i]] = p;
            accountPower[msg.sender] += p;
        }
    }

    function withdraw(address collection, uint256[] calldata ids) external {
        if (failWithdraw) revert DependencyFailure(2);
        require(collection == address(nft), "collection");
        ++withdrawals;
        _callback(2);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            require(stakerOf[id] == msg.sender, "staker");
            accountPower[msg.sender] -= creditedPower[id];
            delete stakerOf[id];
            delete creditedPower[id];
            nft.safeTransferFrom(address(this), msg.sender, id);
        }
    }

    function claim(address account) external returns (uint256 amount) {
        if (failClaim) revert DependencyFailure(3);
        ++claims;
        _callback(3);
        amount = claimable[account];
        claimable[account] = 0;
        if (amount != 0) require(sqk.transfer(account, amount));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AdversarialSQK is MockSQK {
    uint8 public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public blockedReentry;

    function configure(uint8 m, address target, bytes calldata data) external {
        mode = m;
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) revert("SQK transfer unavailable");
        if (mode == 3) {
            (bool ok, bytes memory reason) = callbackTarget.call(callbackData);
            require(!ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "unguarded payout");
            blockedReentry = true;
        }
        return super.transfer(to, amount);
    }
}

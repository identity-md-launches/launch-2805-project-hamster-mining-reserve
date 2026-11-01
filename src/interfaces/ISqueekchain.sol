// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Squeekchain v9 (GRAPH C) interfaces
/// @notice Minimal surfaces of the live Sepolia contracts the vault talks to.
///         The contracts are unverified on Sepolia; the selectors below were given by the
///         integration brief and confirmed by `eth_call` on a Sepolia fork (see test/fork).
/// @dev Selectors:
///      - level(uint256)                      0x05c58df2
///      - merge(uint256,uint256)              0xd1c2babb
///      - deposit(address,uint256[])          0xa71604e8
///      - withdraw(address,uint256[])         0x8293744b
///      - claim(address)                      0x1e83409a
///      - claimable(address)                  0x402914f5
///      - accountPower(address)               0x9624178f
///      - checkpoint()                        0xc2c4c5c1
interface ISqueekNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    /// @notice Current level of a Squeek. Level 1 is the mint level.
    function level(uint256 tokenId) external view returns (uint256);
    /// @notice Burns `donor` and raises `survivor` by one level. Caller must own both,
    ///         both must be the same level and both must be past their per-NFT cooldown.
    function merge(uint256 survivor, uint256 donor) external;
    function MAXIMUM_LEVEL() external view returns (uint256);
    function mining() external view returns (address);
    function sqkCore() external view returns (address);
}

interface ISqueekStaking {
    /// @notice Pulls `ids` of `collection` from msg.sender and credits msg.sender's power.
    function deposit(address collection, uint256[] calldata ids) external;
    /// @notice Returns `ids` of `collection` to msg.sender and debits power. Free.
    function withdraw(address collection, uint256[] calldata ids) external;
    /// @notice Pays accrued SQK to `account`. The live implementation returns one word; the vault
    ///         calls it through a raw `call` and ignores the return data, so a `void` upgrade is fine.
    function claim(address account) external returns (uint256);
    function claimable(address account) external view returns (uint256);
    /// @notice Account mining power, x POWER_UNIT (1e18). L1 = 1000e18, L2 = 2200e18.
    function accountPower(address account) external view returns (uint256);
    function genesis() external view returns (address);
    function mining() external view returns (address);
    function token() external view returns (address);
}

interface ISqueekEmission {
    /// @notice Permissionless round settlement.
    function checkpoint() external;
    function checkpointStatus() external view returns (bool corePaused, uint64 nextRound, bool roundSettled);
    function implementationCodeVersion() external view returns (uint256);
}

interface ISqueekCore {
    function implementationCodeVersion() external view returns (uint256);
}

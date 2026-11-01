// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Squeekchain GRAPH C (live v9 graph) on Sepolia, chain id 11155111.
///         Read directly from the chain on 2026-11-01 (block 12038084):
///         SqueekNFT.MAXIMUM_LEVEL()==10, emission.implementationCodeVersion()==9,
///         core.implementationCodeVersion()==3, staking.genesis()/mining()/token() match.
library SepoliaAddresses {
    uint256 internal constant CHAIN_ID = 11155111;

    /// @notice SqueekNFT (Genesis), ERC-721 "Squeek" / "SQUEEK".
    address internal constant SQUEEK_NFT = 0xCB98349c134aB983dA5BfD80527dfe2552bDB70F;
    /// @notice Staking / rewards surface (per-account power).
    address internal constant SQUEEK_STAKING = 0x4b67b739dFd832f4EAC67a7Aa3bc244fB74cea4F;
    /// @notice Emission engine, implementationCodeVersion()==9.
    address internal constant SQUEEK_EMISSION = 0xcd46990f8349057335289Ef282c276204B6CDC62;
    /// @notice SqueekCore, implementationCodeVersion()==3.
    address internal constant SQUEEK_CORE = 0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44;
    /// @notice SQK reward asset, 18 decimals. External and read-only for this project.
    address internal constant SQK = 0x5501E1Fa81Be1c3F49225fa7668DA0245d07Db60;

    /// @notice Launch owner given for this deployment.
    address internal constant OWNER = 0x2BBAD01F50EAE735F95050b62E3a7d0c4Cf8f6Ca;
}

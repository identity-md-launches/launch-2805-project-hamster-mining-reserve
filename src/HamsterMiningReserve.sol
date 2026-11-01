// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISqueekNFT, ISqueekStaking, ISqueekEmission, ISqueekCore} from "./interfaces/ISqueekchain.sol";

/// @title Hamster Mining Reserve (HMR)
/// @notice Merge-pooling mining vault for Squeekchain v9 Squeek NFTs.
///
///  - Depositors hand Squeek NFTs to the vault for good (permanent reserve: no NFT withdrawal
///    exists for anyone, depositor or owner).
///  - The vault stakes every NFT under its own account in the Squeekchain staking contract and
///    credits the depositor with hmSQUEEK shares in proportion to the mining power the stake
///    adds to the vault's account.
///  - A strategist merges pairs of equal-level NFTs the vault holds. Each merge must strictly
///    increase the vault's total mining power; the gain accrues to every share holder because
///    share supply does not change on merge.
///  - Anyone can `harvest()`: settle the emission round, claim SQK into the vault and bump the
///    per-share reward index. Depositors claim their pro-rata SQK with `claimRewards()`, or exit
///    by transferring their shares (which carry the future reward stream with them).
///
/// hmSQUEEK is the vault's internal share ledger. It uses the standard transferable-share
/// (ERC-20) interface purely as bookkeeping so holders can exit by transfer. Shares are only
/// ever minted against NFTs that are deposited and are never pre-created, pooled or sold by
/// this contract.
contract HamsterMiningReserve is ERC20, Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants

    /// @notice Fixed point used by the per-share reward index.
    uint256 public constant INDEX_PRECISION = 1e27;
    /// @notice Largest number of NFTs one `deposit` call may stake (bounds staking gas).
    uint256 public constant MAX_DEPOSIT_BATCH = 50;

    // ------------------------------------------------------------------ immutables

    /// @notice Squeek Genesis ERC-721 collection.
    ISqueekNFT public immutable nft;
    /// @notice Squeekchain staking / reward surface (per-account power).
    ISqueekStaking public immutable staking;
    /// @notice Squeekchain emission engine (v9).
    ISqueekEmission public immutable emission;
    /// @notice SqueekCore (v3).
    ISqueekCore public immutable core;
    /// @notice SQK reward asset paid out by the staking contract.
    IERC20 public immutable rewardToken;

    // ------------------------------------------------------------------ storage

    /// @notice Account allowed to run `mergeStep`. The owner may always run it too.
    address public strategist;

    /// @notice Number of Squeek NFTs the vault currently holds (staked under its account).
    uint256 public heldCount;
    /// @notice Whether `tokenId` is part of the reserve.
    mapping(uint256 tokenId => bool) public isHeld;

    /// @notice Cumulative SQK distributed per share, x INDEX_PRECISION.
    uint256 public rewardIndex;
    /// @notice Share of the vault's SQK balance already attributed through `rewardIndex`.
    uint256 public accountedBalance;
    /// @notice Lifetime SQK paid out to share holders.
    uint256 public totalRewardsPaid;
    /// @notice Last `rewardIndex` a holder's balance was synced at.
    mapping(address holder => uint256) public holderIndex;
    /// @notice SQK already attributed to a holder and not yet claimed.
    mapping(address holder => uint256) public unclaimedRewards;

    /// @dev True while the NFT contract is expected to push tokens to the vault (staking withdraw).
    bool private _acceptingNfts;
    /// @dev True while `deposit` has already settled for this call, so `_update` skips settling.
    bool private _settledInCall;
    /// @dev True once `setApprovalForAll(staking, true)` has been issued.
    bool private _stakingApproved;

    // ------------------------------------------------------------------ events

    event Deposited(address indexed depositor, uint256[] tokenIds, uint256 powerAdded, uint256 sharesMinted);
    event StrandedStaked(address indexed caller, uint256[] tokenIds, uint256 powerAdded);
    event MergeStep(
        uint256 indexed survivor, uint256 indexed donor, uint256 newLevel, uint256 powerBefore, uint256 powerAfter
    );
    event Harvested(uint256 rewardsReceived, uint256 newRewardIndex);
    event RewardsClaimed(address indexed holder, address indexed to, uint256 amount);
    event StrategistUpdated(address indexed previousStrategist, address indexed newStrategist);
    event CheckpointFailed(bytes reason);
    event ClaimFailed(bytes reason);

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error EmptyBatch();
    error BatchTooLarge(uint256 size, uint256 max);
    error NotStrategist(address caller);
    error NotHeld(uint256 tokenId);
    error SameToken();
    error LevelMismatch(uint256 survivorLevel, uint256 donorLevel);
    error PowerDidNotIncrease(uint256 powerBefore, uint256 powerAfter);
    error NoPowerAdded();
    error UnexpectedNft(address operator, uint256 tokenId);
    /// @dev SQK is claimable for the vault but `staking.claim` failed: share balances are frozen
    ///      until the claim path recovers so the unsettled SQK cannot be re-split.
    error RewardsUnsettled();
    /// @dev The vault itself may not hold its own shares or be a reward recipient.
    error InvalidRecipient(address to);
    /// @dev Shares exist but the staking contract reports zero power for the vault; the NAV
    ///      formula has no defined price, so deposits stop instead of diluting anyone.
    error ZeroPowerWithShares(uint256 supply);
    /// @dev `tokenId` is not owned by the vault, or is already part of the reserve.
    error NotStranded(uint256 tokenId);
    error RenounceDisabled();

    // ------------------------------------------------------------------ constructor

    /// @param owner_ Vault owner (Ownable2Step). Also the initial strategist (see `_transferOwnership`).
    /// @param nft_ Squeek Genesis NFT collection.
    /// @param staking_ Squeekchain staking / reward contract.
    /// @param emission_ Squeekchain emission engine.
    /// @param core_ SqueekCore.
    /// @param rewardToken_ SQK reward asset (must equal `staking.token()`; checked by `graphHealth()`).
    /// @dev The constructor performs no external calls so it can be rehearsed on an empty chain.
    ///      Every outside contract is checked on first use.
    constructor(address owner_, address nft_, address staking_, address emission_, address core_, address rewardToken_)
        ERC20("Hamster Mining Reserve Share", "hmSQUEEK")
        Ownable(owner_)
    {
        if (
            nft_ == address(0) || staking_ == address(0) || emission_ == address(0) || core_ == address(0)
                || rewardToken_ == address(0)
        ) revert ZeroAddress();
        nft = ISqueekNFT(nft_);
        staking = ISqueekStaking(staking_);
        emission = ISqueekEmission(emission_);
        core = ISqueekCore(core_);
        rewardToken = IERC20(rewardToken_);
    }

    // ------------------------------------------------------------------ modifiers

    modifier onlyStrategist() {
        if (msg.sender != strategist && msg.sender != owner()) revert NotStrategist(msg.sender);
        _;
    }

    // ------------------------------------------------------------------ depositor actions

    /// @notice Deposit Squeek NFTs into the permanent reserve and receive hmSQUEEK shares.
    /// @dev Pulls each `tokenId` from msg.sender (caller must own them and have approved the vault),
    ///      stakes them under the vault's account and mints shares proportional to the power added:
    ///      first deposit: shares = deltaPower; later: shares = deltaPower * totalShares / powerBefore.
    ///      Rewards are settled before the stake so earlier holders keep everything accrued so far;
    ///      if SQK is claimable but the claim fails, the deposit reverts with `RewardsUnsettled`.
    /// @return shares Shares minted to msg.sender.
    function deposit(uint256[] calldata tokenIds) external nonReentrant returns (uint256 shares) {
        uint256 n = tokenIds.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_DEPOSIT_BATCH) revert BatchTooLarge(n, MAX_DEPOSIT_BATCH);

        if (!_settle()) revert RewardsUnsettled();

        uint256 powerBefore = staking.accountPower(address(this));
        uint256 supply = totalSupply();
        if (supply != 0 && powerBefore == 0) revert ZeroPowerWithShares(supply);

        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            // transferFrom moves only from msg.sender; reverts unless msg.sender owns `id`.
            nft.transferFrom(msg.sender, address(this), id);
            isHeld[id] = true;
        }
        heldCount += n;

        _stake(tokenIds);

        uint256 powerAfter = staking.accountPower(address(this));
        if (powerAfter <= powerBefore) revert NoPowerAdded();
        uint256 deltaPower = powerAfter - powerBefore;

        shares = supply == 0 ? deltaPower : (deltaPower * supply) / powerBefore;
        if (shares == 0) revert NoPowerAdded();

        _settledInCall = true;
        _mint(msg.sender, shares);
        _settledInCall = false;

        emit Deposited(msg.sender, tokenIds, deltaPower, shares);
    }

    /// @notice Claim the caller's pro-rata SQK. Returns 0 cleanly when nothing accrued.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender, msg.sender);
    }

    /// @notice Claim the caller's pro-rata SQK and send it to `to`.
    function claimRewards(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidRecipient(to);
        return _claim(msg.sender, to);
    }

    /// @notice Stake Squeek NFTs that were pushed to the vault with a plain `transferFrom` (no
    ///         receiver hook, so `onERC721Received` could not refuse them). Such tokens are owned
    ///         by the vault but mine nothing; this puts them to work for every share holder.
    ///         No shares are minted. Permissionless: it can only stake what the vault already owns.
    function stakeStranded(uint256[] calldata tokenIds) external nonReentrant {
        uint256 n = tokenIds.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_DEPOSIT_BATCH) revert BatchTooLarge(n, MAX_DEPOSIT_BATCH);

        uint256 powerBefore = staking.accountPower(address(this));
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            if (isHeld[id] || nft.ownerOf(id) != address(this)) revert NotStranded(id);
            isHeld[id] = true;
        }
        heldCount += n;
        _stake(tokenIds);
        uint256 powerAfter = staking.accountPower(address(this));
        if (powerAfter <= powerBefore) revert NoPowerAdded();

        emit StrandedStaked(msg.sender, tokenIds, powerAfter - powerBefore);
    }

    // ------------------------------------------------------------------ keeper actions

    /// @notice Settle the emission round, pull any claimable SQK into the vault and bump the
    ///         per-share index. Permissionless and never reverts on the Squeekchain side.
    function harvest() external nonReentrant {
        _settle();
    }

    /// @notice Alias of `harvest()`.
    function poke() external nonReentrant {
        _settle();
    }

    // ------------------------------------------------------------------ strategist actions

    /// @notice Merge two equal-level Squeeks the vault holds. Withdraws the pair from staking,
    ///         merges them (donor is burned, survivor gains a level) and re-stakes the survivor,
    ///         all in one transaction. Reverts unless the vault's total power strictly increases.
    function mergeStep(uint256 survivor, uint256 donor) external nonReentrant onlyStrategist {
        if (survivor == donor) revert SameToken();
        if (!isHeld[survivor]) revert NotHeld(survivor);
        if (!isHeld[donor]) revert NotHeld(donor);

        uint256 survivorLevel = nft.level(survivor);
        uint256 donorLevel = nft.level(donor);
        if (survivorLevel != donorLevel) revert LevelMismatch(survivorLevel, donorLevel);

        _settle();

        uint256 powerBefore = staking.accountPower(address(this));

        uint256[] memory pair = new uint256[](2);
        pair[0] = survivor;
        pair[1] = donor;
        _acceptingNfts = true;
        staking.withdraw(address(nft), pair);
        _acceptingNfts = false;

        nft.merge(survivor, donor);

        uint256[] memory single = new uint256[](1);
        single[0] = survivor;
        _stake(single);

        uint256 powerAfter = staking.accountPower(address(this));
        if (powerAfter <= powerBefore) revert PowerDidNotIncrease(powerBefore, powerAfter);

        isHeld[donor] = false;
        heldCount -= 1;

        emit MergeStep(survivor, donor, nft.level(survivor), powerBefore, powerAfter);
    }

    // ------------------------------------------------------------------ owner actions

    /// @notice Set the strategist allowed to run `mergeStep`. The owner can always merge.
    function setStrategist(address newStrategist) external onlyOwner {
        if (newStrategist == address(0)) revert ZeroAddress();
        emit StrategistUpdated(strategist, newStrategist);
        strategist = newStrategist;
    }

    /// @notice Disabled: the vault always needs an owner to appoint the strategist. Use the
    ///         two-step `transferOwnership` / `acceptOwnership` instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev When the strategist role still sits with the outgoing owner (the default), it moves
    ///      with ownership, so a completed handover leaves no privilege with the old key. An
    ///      explicitly appointed strategist is untouched. Runs from the constructor too, which is
    ///      what makes the initial owner the initial strategist.
    function _transferOwnership(address newOwner) internal override {
        address previous = owner();
        super._transferOwnership(newOwner);
        if (strategist == previous) {
            emit StrategistUpdated(previous, newOwner);
            strategist = newOwner;
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice Vault's total mining power as the staking contract sees it (x1e18).
    function totalPower() external view returns (uint256) {
        return staking.accountPower(address(this));
    }

    /// @notice Mining power backing one whole share (1e18 shares), x1e18.
    function powerPerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (staking.accountPower(address(this)) * 1e18) / supply;
    }

    /// @notice SQK a holder could claim right now if `harvest()` ran first.
    /// @dev Includes SQK the staking contract reports as claimable for the vault.
    function pendingRewards(address holder) external view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 index = rewardIndex;
        if (supply > 0) {
            uint256 pendingVault = rewardToken.balanceOf(address(this)) - accountedBalance;
            uint256 claimableNow = staking.claimable(address(this));
            index += ((pendingVault + claimableNow) * INDEX_PRECISION) / supply;
        }
        return unclaimedRewards[holder] + (balanceOf(holder) * (index - holderIndex[holder])) / INDEX_PRECISION;
    }

    /// @notice Live facts about the Squeekchain graph the vault is wired to.
    /// @dev Pure read; the vault never gates on versions so a Squeekchain upgrade cannot brick it.
    function graphHealth()
        external
        view
        returns (
            uint256 maximumLevel,
            uint256 emissionVersion,
            uint256 coreVersion,
            bool stakingGenesisMatches,
            bool stakingMiningMatches,
            bool stakingTokenMatches,
            bool nftMiningMatches,
            bool nftCoreMatches
        )
    {
        maximumLevel = nft.MAXIMUM_LEVEL();
        emissionVersion = emission.implementationCodeVersion();
        coreVersion = core.implementationCodeVersion();
        stakingGenesisMatches = staking.genesis() == address(nft);
        stakingMiningMatches = staking.mining() == address(emission);
        stakingTokenMatches = staking.token() == address(rewardToken);
        nftMiningMatches = nft.mining() == address(emission);
        nftCoreMatches = nft.sqkCore() == address(core);
    }

    /// @notice Emission engine status: (corePaused, nextRound, roundSettled).
    function emissionStatus() external view returns (bool corePaused, uint64 nextRound, bool roundSettled) {
        return emission.checkpointStatus();
    }

    // ------------------------------------------------------------------ ERC-721 receiver

    /// @notice Accepts Squeek NFTs only while the vault itself is pulling them back from staking.
    ///         Unsolicited `safeTransferFrom` to the vault reverts: use `deposit`.
    function onERC721Received(address operator, address, uint256 tokenId, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(nft) || !_acceptingNfts) revert UnexpectedNft(operator, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ guarded share transfers

    /// @inheritdoc ERC20
    function transfer(address to, uint256 value) public override nonReentrant returns (bool) {
        return super.transfer(to, value);
    }

    /// @inheritdoc ERC20
    function transferFrom(address from, address to, uint256 value) public override nonReentrant returns (bool) {
        return super.transferFrom(from, to, value);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Every balance change settles first and syncs both parties' reward accounts, so no
    ///      transfer or mint can pick up SQK that accrued before it. If SQK is claimable but the
    ///      claim fails, the balance change reverts rather than re-splitting the unsettled SQK.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) revert InvalidRecipient(to);
        if (!_settledInCall && !_settle()) revert RewardsUnsettled();
        if (from != address(0)) _sync(from);
        if (to != address(0)) _sync(to);
        super._update(from, to, value);
    }

    function _sync(address holder) internal {
        uint256 index = rewardIndex;
        uint256 owed = (balanceOf(holder) * (index - holderIndex[holder])) / INDEX_PRECISION;
        if (owed != 0) unclaimedRewards[holder] += owed;
        holderIndex[holder] = index;
    }

    /// @dev checkpoint + claim + index bump. The Squeekchain calls are wrapped so a paused or
    ///      idle emission engine never reverts here; `harvest`/`poke`/`claimRewards` ignore the
    ///      result, while balance changes require it.
    /// @return settled False only when the claim failed while the staking contract still reports
    ///         claimable SQK for the vault (or cannot say): that SQK belongs to the current holders.
    function _settle() internal returns (bool settled) {
        try emission.checkpoint() {}
        catch (bytes memory reason) {
            emit CheckpointFailed(reason);
        }
        // Raw call, return data ignored: the staking proxy is upgradeable and a `claim` that
        // returns nothing (or anything) must not revert the vault. Accounting is balance-delta based.
        (bool ok, bytes memory claimReason) =
            address(staking).call(abi.encodeCall(ISqueekStaking.claim, (address(this))));
        if (ok) {
            settled = true;
        } else {
            emit ClaimFailed(claimReason);
            settled = _nothingClaimable();
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 accounted = accountedBalance;
        uint256 supply = totalSupply();
        if (balance > accounted && supply > 0) {
            uint256 received = balance - accounted;
            rewardIndex += (received * INDEX_PRECISION) / supply;
            accountedBalance = balance;
            emit Harvested(received, rewardIndex);
        }
    }

    /// @dev True when the staking contract reports exactly zero claimable SQK for the vault. A
    ///      reverting or malformed answer counts as "unknown", so balance changes stay frozen.
    function _nothingClaimable() internal view returns (bool) {
        (bool ok, bytes memory data) =
            address(staking).staticcall(abi.encodeCall(ISqueekStaking.claimable, (address(this))));
        return ok && data.length >= 32 && abi.decode(data, (uint256)) == 0;
    }

    function _claim(address holder, address to) internal returns (uint256 amount) {
        _settle();
        _sync(holder);
        amount = unclaimedRewards[holder];
        if (amount == 0) return 0;
        unclaimedRewards[holder] = 0;
        accountedBalance -= amount;
        totalRewardsPaid += amount;
        rewardToken.safeTransfer(to, amount);
        emit RewardsClaimed(holder, to, amount);
    }

    function _stake(uint256[] memory tokenIds) internal {
        if (!_stakingApproved) {
            nft.setApprovalForAll(address(staking), true);
            _stakingApproved = true;
        }
        staking.deposit(address(nft), tokenIds);
    }
}

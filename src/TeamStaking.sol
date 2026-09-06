// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentCoordination} from "./AgentCoordination.sol";
import {AgentIntent, AcceptanceAttestation, CoordinationPayload, Status} from "./IAgentCoordination.sol";
import {GameCoordination} from "./GameCoordination.sol";

/**
 * @title TeamStaking
 * @notice Team-based staking with shared rewards using ERC-8001
 * @dev Enables teams to stake together, share rewards proportionally,
 *      and coordinate through signed intents per ERC-8001 standard
 * 
 * USE CASES:
 * - Guilds staking together for higher rewards
 * - Teams pooling resources for shared benefits
 * - Cooperative gameplay with shared economic incentives
 * 
 * ERC-8001 FLOW:
 * 1. Team leader creates intent with all members as participants
 * 2. Leader calls createTeamStake() → proposeCoordination()
 * 3. Each member contributes stake via contributeStake() + acceptCoordination()
 * 4. When all accept: activateTeamStake() → executeCoordination()
 * 5. Rewards distributed proportionally based on contribution
 */
contract TeamStaking {

    // ============ State Structures ============

    /**
     * @notice Team stake configuration
     * @param intentHash Reference to ERC-8001 coordination
     * @param leader Address that created the team stake
     * @param members Array of team member addresses
     * @param minStake Minimum stake per member
     * @param maxStake Maximum stake per member
     * @param totalStaked Total amount staked by all members
     * @param rewardRate Reward rate per block (basis points)
     * @param lockPeriod Blocks to lock stake
     * @param createdAt Block number of creation
     * @param expiresAt Block number when stake expires
     * @param active Whether stake is active
     * @param rewardToken Token for rewards (0x0 for ETH)
     */
    struct TeamStake {
        bytes32 intentHash;
        address leader;
        address[] members;
        uint256 minStake;
        uint256 maxStake;
        uint256 totalStaked;
        uint256 rewardRate; // Basis points per 10000 blocks
        uint256 lockPeriod;
        uint256 createdAt;
        uint256 expiresAt;
        bool active;
        address rewardToken;
    }

    /**
     * @notice Individual member stake data
     * @param amount Amount staked by member
     * @param joinedAt Block number when joined
     * @param claimedRewards Total rewards claimed
     * @param isMember Whether address is registered member
     * @param hasWithdrawn Whether stake has been withdrawn
     */
    struct MemberStake {
        uint256 amount;
        uint256 joinedAt;
        uint256 claimedRewards;
        bool isMember;
        bool hasWithdrawn;
    }

    /**
     * @notice Reward distribution record
     * @param totalDistributed Total rewards distributed
     * @param perShareReward Reward per share at distribution
     * @param distributedAt Block number
     * @param distributionType 0=proportional, 1=equal
     */
    struct RewardDistribution {
        uint256 totalDistributed;
        uint256 perShareReward;
        uint256 distributedAt;
        uint8 distributionType;
    }

    // ============ State Variables ============

    /// @notice GameCoordination contract for ERC-8001 operations
    GameCoordination public immutable coordination;

    /// @notice ERC-20 staking token
    address public immutable stakeToken;

    /// @notice Minimum team size
    uint256 public constant MIN_TEAM_SIZE = 2;

    /// @notice Maximum team size
    uint256 public constant MAX_TEAM_SIZE = 20;

    /// @notice Minimum lock period (1 day)
    uint256 public constant MIN_LOCK_PERIOD = 7200; // ~24 hours @ 12s blocks

    /// @notice Maximum lock period (90 days)
    uint256 public constant MAX_LOCK_PERIOD = 648000; // ~90 days @ 12s blocks

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Team stake by intent hash
    mapping(bytes32 => TeamStake) public teamStakes;

    /// @notice Member stake data by team and address
    mapping(bytes32 => mapping(address => MemberStake)) public memberStakes;

    /// @notice Reward distributions by team
    mapping(bytes32 => RewardDistribution[]) public rewardHistory;

    /// @notice Total rewards distributed by team
    mapping(bytes32 => uint256) public totalRewardsDistributed;

    /// @notice Teams by leader
    mapping(address => bytes32[]) public leaderTeams;

    /// @notice Teams by member
    mapping(address => bytes32[]) public memberTeams;

    /// @notice Whether the leader has declared an emergency for a team
    mapping(bytes32 => bool) public emergencyDeclared;

    // ============ Events ============

    /// @notice Emitted when team stake is created
    event TeamStakeCreated(
        bytes32 indexed stakeId,
        address indexed leader,
        uint256 teamSize,
        uint256 minStake,
        uint256 maxStake,
        uint256 lockPeriod
    );

    /// @notice Emitted when member contributes stake
    event MemberContributed(
        bytes32 indexed stakeId,
        address indexed member,
        uint256 amount,
        uint256 totalTeamStake
    );

    /// @notice Emitted when team stake is activated
    event TeamStakeActivated(
        bytes32 indexed stakeId,
        uint256 totalStaked,
        uint256 expiresAt
    );

    /// @notice Emitted when rewards are distributed
    event RewardsDistributed(
        bytes32 indexed stakeId,
        uint256 totalRewards,
        uint256 perShareReward,
        uint8 distributionType
    );

    /// @notice Emitted when member claims rewards
    event RewardsClaimed(
        bytes32 indexed stakeId,
        address indexed member,
        uint256 amount
    );

    /// @notice Emitted when member withdraws stake
    event StakeWithdrawn(
        bytes32 indexed stakeId,
        address indexed member,
        uint256 amount,
        uint256 rewards
    );

    /// @notice Emitted when team stake is extended
    event StakeExtended(
        bytes32 indexed stakeId,
        uint256 newExpiresAt
    );

    /// @notice Emitted when leader declares an emergency
    event EmergencyDeclared(bytes32 indexed stakeId, address indexed leader);

    // ============ Errors ============

    error InvalidCoordinationContract();
    error InvalidTeamSize();
    error InvalidStakeAmount();
    error StakeNotFound();
    error StakeAlreadyExists();
    error NotTeamLeader();
    error NotTeamMember();
    error AlreadyContributed();
    error ContributionTooLow();
    error ContributionTooHigh();
    error StakeNotActive();
    error StakeStillLocked();
    error StakeExpired();
    error TransferFailed();
    error NoRewardsToClaim();
    error AlreadyWithdrawn();
    error InvalidLockPeriod();
    error InvalidRewardRate();
    error CoordinationNotReady();

    // ============ Constructor ============

    /**
     * @notice Initialize team staking contract
     * @param _coordination GameCoordination contract address
     * @param _stakeToken Token address for staking
     */
    constructor(address _coordination, address _stakeToken) {
        if (_coordination == address(0)) revert InvalidCoordinationContract();
        coordination = GameCoordination(_coordination);
        stakeToken = _stakeToken;
    }

    // ============ Team Stake Creation ============

    /**
     * @notice Create team stake coordination
     * @dev All team members must accept before staking activates
     * @param intent Signed coordination intent
     * @param signature Agent signature
     * @param payload Coordination payload
     * @param minStake Minimum stake per member
     * @param maxStake Maximum stake per member
     * @param lockPeriod Blocks to lock stake
     * @param rewardRate Reward rate in basis points per 10000 blocks
     * @return stakeId The created team stake ID
     * 
     * ERC-8001 FLOW:
     * - proposeCoordination() → Status: Proposed
     * - Members must accept before stake activates
     */
    function createTeamStake(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload,
        uint256 minStake,
        uint256 maxStake,
        uint256 lockPeriod,
        uint256 rewardRate
    ) external returns (bytes32 stakeId) {
        // Validate team size
        if (intent.participants.length < MIN_TEAM_SIZE) revert InvalidTeamSize();
        if (intent.participants.length > MAX_TEAM_SIZE) revert InvalidTeamSize();

        // Validate lock period
        if (lockPeriod < MIN_LOCK_PERIOD) revert InvalidLockPeriod();
        if (lockPeriod > MAX_LOCK_PERIOD) revert InvalidLockPeriod();

        // Validate reward rate (max 100% per 10000 blocks)
        if (rewardRate > BPS_DENOMINATOR) revert InvalidRewardRate();

        // Validate leader is first participant
        if (intent.participants[0] != msg.sender) revert NotTeamLeader();

        // Create coordination through ERC-8001
        stakeId = coordination.proposeCoordination(intent, signature, payload);

        if (teamStakes[stakeId].intentHash != bytes32(0)) revert StakeAlreadyExists();

        // Store team stake configuration
        teamStakes[stakeId] = TeamStake({
            intentHash: stakeId,
            leader: msg.sender,
            members: intent.participants,
            minStake: minStake,
            maxStake: maxStake,
            totalStaked: 0,
            rewardRate: rewardRate,
            lockPeriod: lockPeriod,
            createdAt: block.number,
            expiresAt: block.number + lockPeriod,
            active: false,
            rewardToken: stakeToken
        });

        // Track for lookup
        leaderTeams[msg.sender].push(stakeId);
        for (uint256 i = 0; i < intent.participants.length; i++) {
            memberTeams[intent.participants[i]].push(stakeId);
        }

        emit TeamStakeCreated(
            stakeId,
            msg.sender,
            intent.participants.length,
            minStake,
            maxStake,
            lockPeriod
        );
    }

    // ============ Contribute Stake ============

    /**
     * @notice Individual team member contributes stake
     * @dev Must accept coordination and transfer stake tokens
     * @param stakeId Team stake ID
     * @param attestation Signed acceptance attestation
     * @param amount Amount to stake
     * 
     * ERC-8001 FLOW:
     * - acceptCoordination() → adds acceptance
     * - When all accept: Status → Ready
     */
    function contributeStake(
        bytes32 stakeId,
        AcceptanceAttestation calldata attestation,
        uint256 amount
    ) external {
        TeamStake storage stake = teamStakes[stakeId];

        if (stake.intentHash == bytes32(0)) revert StakeNotFound();
        if (stake.active) revert StakeAlreadyExists(); // Using as "already active"

        // Verify caller is attestation participant
        if (attestation.participant != msg.sender) revert NotTeamMember();

        // Verify amount is within bounds
        if (amount < stake.minStake) revert ContributionTooLow();
        if (amount > stake.maxStake) revert ContributionTooHigh();

        // Check not already contributed
        if (memberStakes[stakeId][msg.sender].amount > 0) revert AlreadyContributed();

        // Transfer stake tokens
        _safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        // Record member stake
        memberStakes[stakeId][msg.sender] = MemberStake({
            amount: amount,
            joinedAt: block.number,
            claimedRewards: 0,
            isMember: true,
            hasWithdrawn: false
        });

        // Update total staked
        stake.totalStaked += amount;

        // Accept coordination through ERC-8001
        coordination.acceptCoordination(stakeId, attestation);

        emit MemberContributed(stakeId, msg.sender, amount, stake.totalStaked);
    }

    // ============ Activate Stake ============

    /**
     * @notice Activate team stake when all members joined
     * @dev Executes coordination through ERC-8001
     * @param stakeId Team stake ID
     * @param payload Coordination payload
     * @param executionData Encoded (address rewardToken, bool autoCompound)
     * 
     * ERC-8001 FLOW:
     * - executeCoordination() → Status: Executed
     * - Triggers _executeTeamStake() hook in GameCoordination
     */
    function activateTeamStake(
        bytes32 stakeId,
        CoordinationPayload calldata payload,
        bytes calldata executionData
    ) external {
        TeamStake storage stake = teamStakes[stakeId];

        if (stake.intentHash == bytes32(0)) revert StakeNotFound();
        if (stake.active) revert StakeAlreadyExists();

        // Check all members have accepted
        (,,,,, uint256 acceptedCount, uint256 requiredCount,) = coordination.getCoordinationDetails(stakeId);
        if (acceptedCount < requiredCount) revert CoordinationNotReady();

        // Execute coordination
        (bool success, ) = coordination.executeCoordination(
            stakeId,
            payload,
            executionData
        );
        if (!success) revert TransferFailed();

        // Activate stake
        stake.active = true;
        stake.expiresAt = block.number + stake.lockPeriod;

        emit TeamStakeActivated(stakeId, stake.totalStaked, stake.expiresAt);
    }

    // ============ Distribute Rewards ============

    /**
     * @notice Distribute rewards to team members
     * @dev Can be called by anyone with rewards
     * @param stakeId Team stake ID
     * @param totalRewards Total rewards to distribute
     * @param distributionType 0=proportional to stake, 1=equal split
     */
    function distributeRewards(
        bytes32 stakeId,
        uint256 totalRewards,
        uint8 distributionType
    ) external {
        TeamStake storage stake = teamStakes[stakeId];

        if (!stake.active) revert StakeNotActive();
        if (distributionType > 1) revert InvalidTeamSize(); // 0 or 1 only

        // Transfer rewards to contract
        _safeTransferFrom(stake.rewardToken, msg.sender, address(this), totalRewards);

        // Calculate per-share reward
        uint256 perShare = distributionType == 0
            ? (totalRewards * 1e18) / stake.totalStaked // Proportional
            : totalRewards / stake.members.length; // Equal

        // Record distribution
        rewardHistory[stakeId].push(RewardDistribution({
            totalDistributed: totalRewards,
            perShareReward: perShare,
            distributedAt: block.number,
            distributionType: distributionType
        }));

        totalRewardsDistributed[stakeId] += totalRewards;

        emit RewardsDistributed(stakeId, totalRewards, perShare, distributionType);
    }

    // ============ Claim Rewards ============

    /**
     * @notice Claim accumulated rewards for caller
     * @param stakeId Team stake ID
     */
    function claimRewards(bytes32 stakeId) external {
        TeamStake storage stake = teamStakes[stakeId];
        MemberStake storage member = memberStakes[stakeId][msg.sender];

        if (!stake.active) revert StakeNotActive();
        if (!member.isMember) revert NotTeamMember();
        if (member.hasWithdrawn) revert AlreadyWithdrawn();
        if (member.amount == 0) revert NoRewardsToClaim();

        // Calculate claimable rewards
        uint256 pendingRewards = calculatePendingRewards(stakeId, msg.sender);
        if (pendingRewards == 0) revert NoRewardsToClaim();

        // Update claimed
        member.claimedRewards += pendingRewards;

        // Transfer rewards
        _safeTransfer(stake.rewardToken, msg.sender, pendingRewards);

        emit RewardsClaimed(stakeId, msg.sender, pendingRewards);
    }

    // ============ Withdraw Stake ============

    /**
     * @notice Withdraw stake and remaining rewards after lock period
     * @param stakeId Team stake ID
     */
    function withdrawStake(bytes32 stakeId) external {
        TeamStake storage stake = teamStakes[stakeId];
        MemberStake storage member = memberStakes[stakeId][msg.sender];

        if (stake.intentHash == bytes32(0)) revert StakeNotFound();
        if (!member.isMember) revert NotTeamMember();
        if (member.hasWithdrawn) revert AlreadyWithdrawn();
        if (block.number < stake.expiresAt) revert StakeStillLocked();

        // Calculate final rewards
        uint256 pendingRewards = calculatePendingRewards(stakeId, msg.sender);
        uint256 stakedAmount = member.amount;
        uint256 totalReturn = stakedAmount + pendingRewards;

        // Mark as withdrawn and zero the stake so no future rewards accrue
        member.hasWithdrawn = true;
        member.amount = 0;

        // Transfer stake + rewards
        _safeTransfer(stakeToken, msg.sender, totalReturn);

        emit StakeWithdrawn(stakeId, msg.sender, stakedAmount, pendingRewards);
    }

    // ============ Emergency Withdraw ============

    /**
     * @notice Leader declares an emergency, unlocking early withdrawal for all members
     * @dev Irreversible. This is the only way to exit an active stake before
     *      the lock period ends - see emergencyWithdraw()
     * @param stakeId Team stake ID
     */
    function declareEmergency(bytes32 stakeId) external {
        TeamStake storage stake = teamStakes[stakeId];

        if (stake.intentHash == bytes32(0)) revert StakeNotFound();
        if (msg.sender != stake.leader) revert NotTeamLeader();

        emergencyDeclared[stakeId] = true;

        emit EmergencyDeclared(stakeId, msg.sender);
    }

    /**
     * @notice Emergency withdraw before the lock period ends
     * @dev Genuinely exceptional path: only available when the stake never
     *      activated or the leader has declared an emergency. Expired stakes
     *      use withdrawStake() instead - this cannot bypass an active lock
     * @param stakeId Team stake ID
     * @param forfeitRewards Whether to forfeit unclaimed rewards on exit
     */
    function emergencyWithdraw(
        bytes32 stakeId,
        bool forfeitRewards
    ) external {
        TeamStake storage stake = teamStakes[stakeId];
        MemberStake storage member = memberStakes[stakeId][msg.sender];

        if (stake.intentHash == bytes32(0)) revert StakeNotFound();
        if (!member.isMember) revert NotTeamMember();
        if (member.hasWithdrawn) revert AlreadyWithdrawn();

        // Active, non-emergency stakes stay locked until expiry
        if (stake.active && !emergencyDeclared[stakeId]) revert StakeStillLocked();

        uint256 pendingRewards = forfeitRewards ? 0 : calculatePendingRewards(stakeId, msg.sender);
        uint256 stakedAmount = member.amount;

        // Mark as withdrawn and zero the stake so no future rewards accrue
        member.hasWithdrawn = true;
        member.amount = 0;

        _safeTransfer(stakeToken, msg.sender, stakedAmount + pendingRewards);

        emit StakeWithdrawn(stakeId, msg.sender, stakedAmount, pendingRewards);
    }

    // ============ View Functions ============

    /**
     * @notice Calculate pending rewards for member
     * @param stakeId Team stake ID
     * @param member Member address
     * @return pendingRewards Amount of rewards pending
     */
    function calculatePendingRewards(
        bytes32 stakeId,
        address member
    ) public view returns (uint256 pendingRewards) {
        TeamStake storage stake = teamStakes[stakeId];
        MemberStake storage m = memberStakes[stakeId][member];

        if (!stake.active || !m.isMember) return 0;

        // Sum all distributions based on member's share
        uint256 totalEarned = 0;

        for (uint256 i = 0; i < rewardHistory[stakeId].length; i++) {
            RewardDistribution storage dist = rewardHistory[stakeId][i];

            if (dist.distributedAt > m.joinedAt) {
                if (dist.distributionType == 0) {
                    // Proportional: perShare * amount / 1e18
                    totalEarned += (dist.perShareReward * m.amount) / 1e18;
                } else {
                    // Equal split
                    totalEarned += dist.perShareReward;
                }
            }
        }

        // Subtract already claimed
        if (totalEarned > m.claimedRewards) {
            pendingRewards = totalEarned - m.claimedRewards;
        }

        return pendingRewards;
    }

    /**
     * @notice Get team stake details
     * @param stakeId Team stake ID
     * @return TeamStake struct
     */
    function getTeamStake(bytes32 stakeId) external view returns (TeamStake memory) {
        return teamStakes[stakeId];
    }

    /**
     * @notice Get member stake details
     * @param stakeId Team stake ID
     * @param member Member address
     * @return MemberStake struct
     */
    function getMemberStake(bytes32 stakeId, address member) external view returns (MemberStake memory) {
        return memberStakes[stakeId][member];
    }

    /**
     * @notice Get teams led by address
     * @param leader Leader address
     * @return Array of stake IDs
     */
    function getLeaderTeams(address leader) external view returns (bytes32[] memory) {
        return leaderTeams[leader];
    }

    /**
     * @notice Get teams where address is member
     * @param member Member address
     * @return Array of stake IDs
     */
    function getMemberTeams(address member) external view returns (bytes32[] memory) {
        return memberTeams[member];
    }

    /**
     * @notice Check if member can withdraw
     * @param stakeId Team stake ID
     * @param member Member address
     * @return canWithdraw_ True if withdrawal is allowed
     * @return reason Reason if not allowed
     */
    function canWithdraw(bytes32 stakeId, address member) external view returns (bool canWithdraw_, string memory reason) {
        TeamStake storage stake = teamStakes[stakeId];
        MemberStake storage m = memberStakes[stakeId][member];

        if (stake.intentHash == bytes32(0)) return (false, "Stake not found");
        if (!m.isMember) return (false, "Not a member");
        if (m.hasWithdrawn) return (false, "Already withdrawn");
        if (block.number >= stake.expiresAt) return (true, "");
        if (emergencyDeclared[stakeId]) return (true, "Emergency declared");
        if (!stake.active) return (true, "Stake inactive");

        uint256 blocksRemaining = stake.expiresAt - block.number;
        return (false, string(abi.encodePacked("Locked for ", uintToString(blocksRemaining), " blocks")));
    }

    // ============ Token Transfer Helpers ============

    /**
     * @notice Transfer tokens, reverting on failure
     * @dev Checks return data because some ERC-20s return false instead of
     *      reverting, and others (like USDT) return nothing at all
     */
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory returndata) = token.call(
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amount)
        );
        if (!success || !(returndata.length == 0 || abi.decode(returndata, (bool)))) {
            revert TransferFailed();
        }
    }

    /**
     * @notice Transfer tokens from an approved account, reverting on failure
     * @dev Same return-data check as _safeTransfer
     */
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory returndata) = token.call(
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                from,
                to,
                amount
            )
        );
        if (!success || !(returndata.length == 0 || abi.decode(returndata, (bool)))) {
            revert TransferFailed();
        }
    }

    // ============ Utility Functions ============

    /**
     * @notice Convert uint to string (for error messages)
     * @param _i Integer to convert
     * @return String representation
     */
    function uintToString(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}

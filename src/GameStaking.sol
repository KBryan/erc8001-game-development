// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title GameStaking
 * @notice Staking contract with tiered rewards and lock periods
 */
contract GameStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public stakingToken;
    IERC20 public rewardToken;

    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 rewardRate;
        bool claimed;
    }

    struct Tier {
        uint256 minDuration;
        uint256 maxDuration;
        uint256 baseAPY; // Basis points (10000 = 100%)
        uint256 multiplier; // Tier bonus in bps
    }

    mapping(address => Stake[]) public userStakes;
    mapping(uint256 => Tier) public tiers;
    uint256 public tierCount;

    uint256 public totalStaked;
    uint256 public rewardPool;

    // Events
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 duration,
        uint256 stakeId
    );
    event Unstaked(
        address indexed user,
        uint256 amount,
        uint256 reward,
        uint256 stakeId
    );
    event RewardAdded(uint256 amount);
    event EmergencyUnstaked(
        address indexed user,
        uint256 amount,
        uint256 forfeitedReward,
        uint256 stakeId
    );

    constructor(address _stakingToken, address _rewardToken) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);

        // Initialize tiers
        tiers[0] = Tier(7 days, 30 days, 500, 1000);   // 5% APY
        tiers[1] = Tier(30 days, 90 days, 1000, 1500); // 10% APY
        tiers[2] = Tier(90 days, 365 days, 1500, 2500); // 15% APY
        tierCount = 3;
    }

    /**
     * @notice Stake tokens for a specified duration
     */
    function stake(uint256 amount, uint256 duration)
        external
        nonReentrant
        returns (uint256 stakeId)
    {
        require(amount > 0, "Cannot stake 0");

        Tier memory tier = _getTier(duration);
        require(tier.minDuration > 0, "Invalid duration");

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        Stake memory newStake = Stake({
            amount: amount,
            startTime: block.timestamp,
            duration: duration,
            rewardRate: tier.baseAPY + tier.multiplier,
            claimed: false
        });

        stakeId = userStakes[msg.sender].length;
        userStakes[msg.sender].push(newStake);

        totalStaked += amount;

        emit Staked(msg.sender, amount, duration, stakeId);
        return stakeId;
    }

    /**
     * @notice Calculate pending rewards for a stake
     */
    function calculateReward(address user, uint256 stakeId)
        public
        view
        returns (uint256)
    {
        require(stakeId < userStakes[user].length, "Invalid stake ID");
        Stake memory s = userStakes[user][stakeId];

        if (s.claimed) return 0;

        uint256 timeStaked = block.timestamp - s.startTime;
        uint256 effectiveTime = timeStaked > s.duration ? s.duration : timeStaked;

        // reward = amount * rate * time / (365 days * 10000)
        return (s.amount * s.rewardRate * effectiveTime) / (365 days * 10000);
    }

    /**
     * @notice Unstake and claim rewards after lock period
     */
    function unstake(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakes[msg.sender].length, "Invalid stake ID");

        Stake storage s = userStakes[msg.sender][stakeId];
        require(!s.claimed, "Already claimed");
        require(
            block.timestamp >= s.startTime + s.duration,
            "Lock period not ended"
        );

        // Compute the reward before marking the stake claimed --
        // calculateReward returns 0 for claimed stakes
        uint256 reward = calculateReward(msg.sender, stakeId);
        s.claimed = true;

        require(rewardPool >= reward, "Insufficient reward pool");

        totalStaked -= s.amount;
        rewardPool -= reward;

        stakingToken.safeTransfer(msg.sender, s.amount);
        rewardToken.safeTransfer(msg.sender, reward);

        emit Unstaked(msg.sender, s.amount, reward, stakeId);
    }

    /**
     * @notice Withdraw principal only after the lock period, forfeiting all rewards
     * @dev Escape hatch for when the reward pool is underfunded: unstake()
     *      reverts if rewardPool cannot cover the earned reward, which would
     *      otherwise freeze principal until the owner calls addRewards. Use
     *      this only when you accept losing the reward -- the forfeited
     *      amount stays in the reward pool for other stakers.
     */
    function emergencyUnstake(uint256 stakeId) external nonReentrant {
        require(stakeId < userStakes[msg.sender].length, "Invalid stake ID");

        Stake storage s = userStakes[msg.sender][stakeId];
        require(!s.claimed, "Already claimed");
        require(
            block.timestamp >= s.startTime + s.duration,
            "Lock period not ended"
        );

        // Record what is being given up before marking the stake claimed
        uint256 forfeited = calculateReward(msg.sender, stakeId);
        s.claimed = true;

        totalStaked -= s.amount;

        stakingToken.safeTransfer(msg.sender, s.amount);

        emit EmergencyUnstaked(msg.sender, s.amount, forfeited, stakeId);
    }

    /**
     * @notice Add rewards to the pool
     */
    function addRewards(uint256 amount) external onlyOwner {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
        emit RewardAdded(amount);
    }

    function _getTier(uint256 duration) internal view returns (Tier memory) {
        for (uint256 i = 0; i < tierCount; i++) {
            if (duration >= tiers[i].minDuration && duration <= tiers[i].maxDuration) {
                return tiers[i];
            }
        }
        return Tier(0, 0, 0, 0);
    }
}

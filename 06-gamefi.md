# GameFi Architecture

## Introduction to GameFi

GameFi (Game Finance) represents the convergence of gaming and decentralized finance. Unlike traditional games where in-game assets have no real-world value, GameFi enables players to earn cryptocurrency, trade NFTs, and participate in yield-generating activities while playing.

### GameFi Components

A modern GameFi ecosystem consists of:
- **Game Token**: Native currency for the game economy
- **Staking Mechanisms**: Lock tokens to earn rewards
- **Yield Integration**: Connect to DeFi protocols like Morpho
- **Oracle Integration**: Price feeds from Pyth for accurate valuations
- **Loot Systems**: Randomized rewards with verifiable entropy

## GameToken Contract

The foundation of any GameFi ecosystem is a well-designed token with gaming-specific features.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title GameToken
 * @notice Native token for GameFi ecosystem with gaming-specific features
 * @dev ERC20 with mint/burn controls, in-game transfer functionality
 */
contract GameToken is ERC20, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant GAME_CONTRACT_ROLE = keccak256("GAME_CONTRACT_ROLE");
    
    // Emission control
    uint256 public maxSupply;
    uint256 public dailyMintLimit;
    uint256 public lastMintTimestamp;
    uint256 public dailyMinted;
    
    // Game mechanics
    mapping(address => bool) public isGameContract;
    mapping(address => uint256) public lockedBalance;
    
    // Events
    event TokensMinted(address indexed to, uint256 amount, string reason);
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event BalanceLocked(address indexed user, uint256 amount);
    event BalanceUnlocked(address indexed user, uint256 amount);
    
    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply,
        uint256 _dailyMintLimit
    ) ERC20(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        
        maxSupply = _maxSupply;
        dailyMintLimit = _dailyMintLimit;
        lastMintTimestamp = block.timestamp;
    }
    
    /**
     * @notice Mint tokens with daily limit enforcement
     */
    function mint(address to, uint256 amount, string calldata reason) 
        external 
        onlyRole(MINTER_ROLE) 
    {
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
        
        // Reset daily counter if new day
        if (block.timestamp >= lastMintTimestamp + 1 days) {
            dailyMinted = 0;
            lastMintTimestamp = block.timestamp;
        }
        
        require(dailyMinted + amount <= dailyMintLimit, "Daily limit exceeded");
        
        unchecked {
            dailyMinted += amount;
        }
        
        _mint(to, amount);
        emit TokensMinted(to, amount, reason);
    }
    
    /**
     * @notice Burn tokens with tracking
     */
    function burn(uint256 amount, string calldata reason) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, reason);
    }
    
    /**
     * @notice Lock tokens for in-game activities
     */
    function lock(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        lockedBalance[msg.sender] += amount;
        emit BalanceLocked(msg.sender, amount);
    }
    
    /**
     * @notice Unlock tokens
     */
    function unlock(uint256 amount) external {
        require(lockedBalance[msg.sender] >= amount, "Insufficient locked");
        lockedBalance[msg.sender] -= amount;
        emit BalanceUnlocked(msg.sender, amount);
    }
    
    /**
     * @notice Get spendable balance (excluding locked)
     */
    function spendableBalance(address user) external view returns (uint256) {
        return balanceOf(user) - lockedBalance[user];
    }
    
    /**
     * @notice Transfer that respects locked balance
     */
    function transferWithLockCheck(address to, uint256 amount) 
        external 
        whenNotPaused 
        returns (bool) 
    {
        require(
            balanceOf(msg.sender) - lockedBalance[msg.sender] >= amount,
            "Insufficient unlocked balance"
        );
        return transfer(to, amount);
    }
}
```

*GameToken implementation*

<a id="lst:gametoken"></a>

## GameStaking Contract

Staking allows players to earn rewards by locking their tokens.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
        uint256 baseAPY; // Basis points (10000 = 100
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
    
    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        
        // Initialize tiers
        tiers[0] = Tier(7 days, 30 days, 500, 1000);   // 5
        tiers[1] = Tier(30 days, 90 days, 1000, 1500); // 10
        tiers[2] = Tier(90 days, 365 days, 1500, 2500); // 15
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
        
        s.claimed = true;
        uint256 reward = calculateReward(msg.sender, stakeId);
        
        require(rewardPool >= reward, "Insufficient reward pool");
        
        totalStaked -= s.amount;
        rewardPool -= reward;
        
        stakingToken.safeTransfer(msg.sender, s.amount);
        rewardToken.safeTransfer(msg.sender, reward);
        
        emit Unstaked(msg.sender, s.amount, reward, stakeId);
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
```

*GameStaking implementation*

<a id="lst:gamestaking"></a>

## Yield Integration with Morpho

Morpho is a lending protocol optimizer that improves yields on Aave and Compound. Integrating Morpho allows games to generate passive income on treasury funds.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IMorpho {
    function supply(
        address poolToken,
        address onBehalf,
        uint256 amount,
        uint256 maxIterations
    ) external returns (uint256 supplied);
    
    function withdraw(
        address poolToken,
        uint256 amount
    ) external returns (uint256 withdrawn);
    
    function balanceOf(
        address poolToken,
        address user
    ) external view returns (uint256);
}

/**
 * @title YieldManager
 * @notice Manages game treasury yield through Morpho integration
 */
contract YieldManager is Ownable, ReentrancyGuard {
    IMorpho public morpho;
    IERC20 public underlying;
    address public poolToken;
    
    uint256 public totalDeposited;
    uint256 public totalYield;
    uint256 public minReserve; // Minimum to keep liquid
    
    // Events
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event YieldHarvested(uint256 amount);
    
    constructor(
        address _morpho,
        address _underlying,
        address _poolToken,
        uint256 _minReserve
    ) {
        morpho = IMorpho(_morpho);
        underlying = IERC20(_underlying);
        poolToken = _poolToken;
        minReserve = _minReserve;
    }
    
    /**
     * @notice Deposit treasury funds into yield-generating Morpho pool
     */
    function deposit(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        
        underlying.transferFrom(msg.sender, address(this), amount);
        underlying.approve(address(morpho), amount);
        
        uint256 supplied = morpho.supply(poolToken, address(this), amount, 0);
        totalDeposited += supplied;
        
        emit Deposited(supplied);
    }
    
    /**
     * @notice Withdraw funds from Morpho
     */
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        uint256 withdrawn = morpho.withdraw(poolToken, amount);
        totalDeposited = totalDeposited > withdrawn ? totalDeposited - withdrawn : 0;
        
        underlying.transfer(owner(), withdrawn);
        emit Withdrawn(withdrawn);
    }
    
    /**
     * @notice Harvest yield and reinvest or distribute
     */
    function harvestYield() external onlyOwner {
        uint256 currentBalance = morpho.balanceOf(poolToken, address(this));
        require(currentBalance > totalDeposited, "No yield generated");
        
        uint256 yield = currentBalance - totalDeposited;
        totalYield += yield;
        totalDeposited = currentBalance;
        
        emit YieldHarvested(yield);
    }
    
    /**
     * @notice Get total balance including yield
     */
    function getTotalBalance() external view returns (uint256) {
        return morpho.balanceOf(poolToken, address(this));
    }
    
    /**
     * @notice Get available yield
     */
    function getAvailableYield() external view returns (uint256) {
        uint256 current = morpho.balanceOf(poolToken, address(this));
        return current > totalDeposited ? current - totalDeposited : 0;
    }
}
```

*Morpho YieldManager integration*

<a id="lst:yieldmanager"></a>

## Pyth Oracle Integration

Accurate price feeds are essential for GameFi valuations and reward calculations.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
    
    function getPrice(bytes32 id) external view returns (Price memory price);
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

/**
 * @title PythPriceFeed
 * @notice Price oracle integration using Pyth Network
 */
contract PythPriceFeed {
    IPyth public pyth;
    
    // Price feed IDs
    bytes32 public constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 public constant BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    
    // Configuration
    uint256 public maxPriceAge = 300; // 5 minutes
    uint256 public confidenceMultiplier = 10; // 10x confidence for safety
    
    error StalePrice();
    error InvalidPrice();
    error ConfidenceTooLow();
    
    constructor(address _pyth) {
        pyth = IPyth(_pyth);
    }
    
    /**
     * @notice Get ETH price in USD with validation
     */
    function getEthPrice() external view returns (uint256 price, uint256 timestamp) {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(ETH_USD, maxPriceAge);
        
        _validatePrice(p);
        
        // Convert to 8 decimal format
        return (uint256(uint64(p.price)), p.publishTime);
    }
    
    /**
     * @notice Get any asset price by ID
     */
    function getAssetPrice(bytes32 priceId) 
        external 
        view 
        returns (uint256 price, uint256 confidence, uint256 timestamp) 
    {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(priceId, maxPriceAge);
        
        _validatePrice(p);
        
        return (
            uint256(uint64(p.price)),
            uint256(p.conf),
            p.publishTime
        );
    }
    
    /**
     * @notice Update price feeds (pay for updates)
     */
    function updatePrices(bytes[] calldata updateData) external payable {
        pyth.updatePriceFeeds{value: msg.value}(updateData);
    }
    
    /**
     * @notice Calculate game reward in USD terms
     */
    function calculateUsdValue(address token, uint256 amount) 
        external 
        view 
        returns (uint256 usdValue) 
    {
        // This would integrate with multiple price feeds
        // Simplified for demonstration
        (uint256 ethPrice,) = this.getEthPrice();
        
        // Example: token priced in ETH
        uint256 tokenPriceInEth = getTokenPriceInEth(token);
        
        usdValue = (amount * tokenPriceInEth * ethPrice) / 1e26; // Adjust decimals
    }
    
    function _validatePrice(IPyth.Price memory p) internal pure {
        if (p.price <= 0) revert InvalidPrice();
        
        // Check confidence interval
        uint256 priceAbs = uint256(uint64(p.price > 0 ? p.price : -p.price));
        if (uint256(p.conf) * 10 > priceAbs) {
            revert ConfidenceTooLow();
        }
    }
    
    function getTokenPriceInEth(address token) internal pure returns (uint256) {
        // Placeholder - would query DEX or additional price feed
        return 0;
    }
}
```

*Pyth oracle integration*

<a id="lst:pyth"></a>

## LootBoxManager with Entropy

Randomized rewards require verifiable entropy. This implementation uses a commit-reveal scheme with future blockhash.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LootBoxManager
 * @notice Randomized loot box system with verifiable entropy
 */
contract LootBoxManager is ReentrancyGuard, Ownable {
    
    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }
    
    struct LootBox {
        string name;
        uint256 price;
        uint256[] probabilities; // Basis points (10000 = 100
        uint256[] rewards;
        bool active;
    }
    
    struct OpenRequest {
        address user;
        uint256 boxId;
        uint256 commitBlock;
        bytes32 entropyHash;
        bool revealed;
    }
    
    IERC20 public paymentToken;
    
    mapping(uint256 => LootBox) public lootBoxes;
    mapping(bytes32 => OpenRequest) public openRequests;
    mapping(address => mapping(uint256 => uint256)) public userInventory;
    
    uint256 public boxCount;
    uint256 public constant REVEAL_DELAY = 5; // Blocks
    uint256 public constant MAX_COMMIT_AGE = 256; // Blockhash availability
    
    // Events
    event BoxCreated(uint256 indexed boxId, string name, uint256 price);
    event OpenCommitted(bytes32 indexed requestId, address user, uint256 boxId);
    event OpenRevealed(
        bytes32 indexed requestId,
        address user,
        Rarity rarity,
        uint256 reward
    );
    
    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
    }
    
    /**
     * @notice Create a new loot box type
     */
    function createLootBox(
        string calldata name,
        uint256 price,
        uint256[] calldata probabilities,
        uint256[] calldata rewards
    ) external onlyOwner returns (uint256 boxId) {
        require(probabilities.length == 5, "Must have 5 rarities");
        require(rewards.length == 5, "Must have 5 rewards");
        
        // Verify probabilities sum to 10000
        uint256 total;
        for (uint256 i = 0; i < probabilities.length; i++) {
            total += probabilities[i];
        }
        require(total == 10000, "Probabilities must sum to 100
        
        boxId = boxCount++;
        lootBoxes[boxId] = LootBox({
            name: name,
            price: price,
            probabilities: probabilities,
            rewards: rewards,
            active: true
        });
        
        emit BoxCreated(boxId, name, price);
    }
    
    /**
     * @notice Commit to opening a loot box
     */
    function commitOpen(uint256 boxId, bytes32 entropyHash) 
        external 
        returns (bytes32 requestId) 
    {
        require(lootBoxes[boxId].active, "Box not active");
        
        // Transfer payment
        paymentToken.transferFrom(msg.sender, address(this), lootBoxes[boxId].price);
        
        requestId = keccak256(abi.encodePacked(
            msg.sender,
            boxId,
            block.number,
            entropyHash
        ));
        
        require(openRequests[requestId].commitBlock == 0, "Request exists");
        
        openRequests[requestId] = OpenRequest({
            user: msg.sender,
            boxId: boxId,
            commitBlock: block.number,
            entropyHash: entropyHash,
            revealed: false
        });
        
        emit OpenCommitted(requestId, msg.sender, boxId);
    }
    
    /**
     * @notice Reveal loot box after delay
     */
    function reveal(bytes32 requestId, uint256 entropy) external nonReentrant {
        OpenRequest storage req = openRequests[requestId];
        
        require(req.user != address(0), "Request not found");
        require(!req.revealed, "Already revealed");
        require(
            block.number >= req.commitBlock + REVEAL_DELAY,
            "Too early"
        );
        require(
            block.number < req.commitBlock + MAX_COMMIT_AGE,
            "Too late - blockhash unavailable"
        );
        
        // Verify entropy matches commitment
        require(
            keccak256(abi.encodePacked(entropy)) == req.entropyHash,
            "Invalid entropy"
        );
        
        // Generate randomness from future blockhash + user entropy
        bytes32 randomness = keccak256(abi.encodePacked(
            blockhash(req.commitBlock + REVEAL_DELAY),
            entropy,
            requestId
        ));
        
        req.revealed = true;
        
        // Determine rarity
        uint256 roll = uint256(randomness) 
        LootBox memory box = lootBoxes[req.boxId];
        
        Rarity rarity;
        uint256 cumulative;
        for (uint256 i = 0; i < 5; i++) {
            cumulative += box.probabilities[i];
            if (roll < cumulative) {
                rarity = Rarity(i);
                break;
            }
        }
        
        uint256 reward = box.rewards[uint256(rarity)];
        userInventory[req.user][uint256(rarity)] += reward;
        
        emit OpenRevealed(requestId, req.user, rarity, reward);
    }
    
    /**
     * @notice Get box details
     */
    function getBox(uint256 boxId) external view returns (LootBox memory) {
        return lootBoxes[boxId];
    }
}
```

*LootBoxManager with entropy system*

<a id="lst:lootbox"></a>

## GameFi Architecture Diagram

> **Figure**: Figure

With the GameFi foundation established, Chapter 7 explores lottery systems with verifiable randomness.
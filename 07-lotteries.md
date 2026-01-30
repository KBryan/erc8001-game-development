# Lotteries

## Introduction

Lotteries are among the most popular blockchain gaming applications. They combine simple mechanics with potentially life-changing payouts, but require careful implementation of randomness to ensure fairness.

### Lottery Design Challenges

- **Verifiable Randomness**: How to select winners fairly
- **Front-running Resistance**: Preventing manipulation
- **Auto-execution**: Handling drawings without manual intervention
- **Scaling**: Supporting large player bases efficiently

## SimpleLottery: Commit-Reveal RNG

The commit-reveal pattern provides cryptographically secure randomness without external oracle dependency.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SimpleLottery
 * @notice Commit-reveal lottery with deterministic winner selection
 */
contract SimpleLottery is ReentrancyGuard, Ownable {
    
    enum Phase { Open, Commit, Reveal, Closed }
    
    struct Entry {
        address participant;
        uint256 amount;
        uint256 tickets;
    }
    
    struct Commitment {
        bytes32 hash;
        uint256 blockNumber;
    }
    
    Phase public phase;
    uint256 public ticketPrice;
    uint256 public minEntries;
    uint256 public commitDuration;
    uint256 public revealDuration;
    
    uint256 public pot;
    Entry[] public entries;
    mapping(address => Commitment) public commitments;
    mapping(address => uint256) public revealedNumbers;
    
    address public winner;
    uint256 public winningNumber;
    bool public paid;
    
    uint256 public phaseStartTime;
    
    // House fee (2.5
    uint256 public constant HOUSE_FEE_BPS = 250;
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // Events
    event PhaseChanged(Phase newPhase);
    event Entered(address indexed participant, uint256 tickets);
    event Committed(address indexed participant, bytes32 hash);
    event Revealed(address indexed participant, uint256 number);
    event WinnerDrawn(address indexed winner, uint256 amount, uint256 winningNumber);
    
    constructor(
        uint256 _ticketPrice,
        uint256 _minEntries,
        uint256 _commitDuration,
        uint256 _revealDuration
    ) {
        ticketPrice = _ticketPrice;
        minEntries = _minEntries;
        commitDuration = _commitDuration;
        revealDuration = _revealDuration;
        phase = Phase.Open;
        phaseStartTime = block.timestamp;
    }
    
    /**
     * @notice Enter the lottery by buying tickets
     */
    function enter(uint256 ticketCount) external payable {
        require(phase == Phase.Open, "Not open");
        require(msg.value == ticketPrice * ticketCount, "Incorrect payment");
        require(ticketCount > 0, "Must buy at least 1 ticket");
        
        entries.push(Entry({
            participant: msg.sender,
            amount: msg.value,
            tickets: ticketCount
        }));
        
        pot += msg.value;
        
        emit Entered(msg.sender, ticketCount);
        
        // Auto-advance if we have enough entries
        if (entries.length >= minEntries) {
            _advancePhase();
        }
    }
    
    /**
     * @notice Commit a hash for reveal phase
     */
    function commit(bytes32 hash) external {
        require(phase == Phase.Commit, "Not commit phase");
        require(_isParticipant(msg.sender), "Not a participant");
        require(commitments[msg.sender].hash == bytes32(0), "Already committed");
        
        commitments[msg.sender] = Commitment({
            hash: hash,
            blockNumber: block.number
        });
        
        emit Committed(msg.sender, hash);
    }
    
    /**
     * @notice Reveal your number
     */
    function reveal(uint256 number, bytes32 salt) external {
        require(phase == Phase.Reveal, "Not reveal phase");
        
        Commitment memory c = commitments[msg.sender];
        require(c.hash != bytes32(0), "No commitment");
        require(
            keccak256(abi.encodePacked(number, salt)) == c.hash,
            "Invalid reveal"
        );
        require(block.number > c.blockNumber + 10, "Too early");
        
        revealedNumbers[msg.sender] = number;
        emit Revealed(msg.sender, number);
    }
    
    /**
     * @notice Draw the winner after reveal phase
     */
    function drawWinner() external nonReentrant {
        require(phase == Phase.Closed, "Not ready");
        require(winner == address(0), "Already drawn");
        
        // Calculate winning number from all reveals
        uint256 seed = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            seed ^= revealedNumbers[entries[i].participant];
        }
        
        // Mix with block hash for unpredictability
        seed ^= uint256(blockhash(block.number - 1));
        
        winningNumber = seed;
        
        // Select winner based on ticket distribution
        uint256 totalTickets = pot / ticketPrice;
        uint256 winningTicket = seed 
        
        uint256 currentTicket = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            currentTicket += entries[i].tickets;
            if (winningTicket < currentTicket) {
                winner = entries[i].participant;
                break;
            }
        }
        
        require(winner != address(0), "Winner selection failed");
        
        // Calculate payout with house fee
        uint256 houseFee = (pot * HOUSE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 payout = pot - houseFee;
        
        paid = true;
        payable(owner()).transfer(houseFee);
        payable(winner).transfer(payout);
        
        emit WinnerDrawn(winner, payout, winningNumber);
    }
    
    /**
     * @notice Advance to next phase (owner or time-based)
     */
    function advancePhase() external {
        _advancePhase();
    }
    
    function _advancePhase() internal {
        if (phase == Phase.Open && entries.length >= minEntries) {
            phase = Phase.Commit;
        } else if (phase == Phase.Commit && 
                   block.timestamp >= phaseStartTime + commitDuration) {
            phase = Phase.Reveal;
        } else if (phase == Phase.Reveal && 
                   block.timestamp >= phaseStartTime + commitDuration + revealDuration) {
            phase = Phase.Closed;
        } else {
            revert("Cannot advance yet");
        }
        
        phaseStartTime = block.timestamp;
        emit PhaseChanged(phase);
    }
    
    function _isParticipant(address user) internal view returns (bool) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].participant == user) return true;
        }
        return false;
    }
    
    /**
     * @notice Get current lottery stats
     */
    function getStats() external view returns (
        Phase currentPhase,
        uint256 currentPot,
        uint256 entryCount,
        uint256 timeRemaining
    ) {
        currentPhase = phase;
        currentPot = pot;
        entryCount = entries.length;
        
        if (phase == Phase.Commit) {
            uint256 elapsed = block.timestamp - phaseStartTime;
            timeRemaining = elapsed < commitDuration ? commitDuration - elapsed : 0;
        } else if (phase == Phase.Reveal) {
            uint256 elapsed = block.timestamp - phaseStartTime;
            timeRemaining = elapsed < revealDuration ? revealDuration - elapsed : 0;
        } else {
            timeRemaining = 0;
        }
    }
}
```

*SimpleLottery with commit-reveal*

<a id="lst:simple-lottery"></a>

## RecurringLottery: Auto-Rollover

For continuous operation, lotteries need automated rollover mechanisms.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/**
 * @title RecurringLottery
 * @notice Auto-executing lottery with Chainlink Automation
 */
contract RecurringLottery is 
    ReentrancyGuard, 
    Ownable, 
    AutomationCompatibleInterface 
{
    struct Round {
        uint256 id;
        uint256 startTime;
        uint256 endTime;
        uint256 pot;
        address[] participants;
        mapping(address => uint256) tickets;
        address winner;
        bool completed;
        uint256 winningTicket;
    }
    
    struct Config {
        uint256 ticketPrice;
        uint256 roundDuration;
        uint256 minPot; // Minimum pot to draw
        uint256 rolloverPercent; // 
        uint256 houseFeePercent;
    }
    
    Config public config;
    uint256 public currentRoundId;
    uint256 public rolloverAmount;
    mapping(uint256 => Round) public rounds;
    
    // Chainlink VRF (simplified - would integrate full VRF)
    address public vrfCoordinator;
    bytes32 public keyHash;
    uint64 public subscriptionId;
    
    // Events
    event RoundStarted(uint256 indexed roundId, uint256 endTime);
    event TicketPurchased(uint256 indexed roundId, address buyer, uint256 count);
    event WinnerSelected(uint256 indexed roundId, address winner, uint256 amount);
    event Rollover(uint256 fromRound, uint256 amount);
    
    constructor(
        uint256 _ticketPrice,
        uint256 _roundDuration,
        uint256 _minPot,
        uint256 _rolloverPercent,
        uint256 _houseFeePercent
    ) {
        config = Config({
            ticketPrice: _ticketPrice,
            roundDuration: _roundDuration,
            minPot: _minPot,
            rolloverPercent: _rolloverPercent,
            houseFeePercent: _houseFeePercent
        });
        
        _startNewRound();
    }
    
    /**
     * @notice Buy tickets for current round
     */
    function buyTickets(uint256 count) external payable {
        require(msg.value == config.ticketPrice * count, "Incorrect payment");
        
        Round storage round = rounds[currentRoundId];
        require(block.timestamp < round.endTime, "Round ended");
        
        if (round.tickets[msg.sender] == 0) {
            round.participants.push(msg.sender);
        }
        round.tickets[msg.sender] += count;
        round.pot += msg.value;
        
        emit TicketPurchased(currentRoundId, msg.sender, count);
    }
    
    /**
     * @notice Chainlink Automation: Check if drawing is needed
     */
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        Round storage round = rounds[currentRoundId];
        
        bool timeElapsed = block.timestamp >= round.endTime;
        bool sufficientPot = round.pot >= config.minPot;
        bool hasParticipants = round.participants.length > 0;
        
        upkeepNeeded = timeElapsed && sufficientPot && hasParticipants && !round.completed;
        performData = abi.encode(currentRoundId);
    }
    
    /**
     * @notice Chainlink Automation: Execute drawing
     */
    function performUpkeep(bytes calldata performData) external override {
        uint256 roundId = abi.decode(performData, (uint256));
        Round storage round = rounds[roundId];
        
        require(block.timestamp >= round.endTime, "Too early");
        require(!round.completed, "Already completed");
        require(round.pot >= config.minPot, "Insufficient pot");
        
        _selectWinner(roundId);
        _startNewRound();
    }
    
    /**
     * @notice Select winner using on-chain randomness (upgrade to VRF recommended)
     */
    function _selectWinner(uint256 roundId) internal {
        Round storage round = rounds[roundId];
        
        // WARNING: In production, use Chainlink VRF instead
        uint256 randomness = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1),
            block.timestamp,
            round.pot,
            roundId
        )));
        
        uint256 totalTickets = round.pot / config.ticketPrice;
        uint256 winningTicket = randomness 
        round.winningTicket = winningTicket;
        
        // Find winner
        uint256 currentTicket = 0;
        for (uint256 i = 0; i < round.participants.length; i++) {
            address participant = round.participants[i];
            currentTicket += round.tickets[participant];
            
            if (winningTicket < currentTicket) {
                round.winner = participant;
                break;
            }
        }
        
        require(round.winner != address(0), "Winner selection failed");
        
        // Calculate amounts
        uint256 houseFee = (round.pot * config.houseFeePercent) / 100;
        uint256 rollover = (round.pot * config.rolloverPercent) / 100;
        uint256 payout = round.pot - houseFee - rollover;
        
        rolloverAmount = rollover;
        round.completed = true;
        
        // Transfer payouts
        payable(owner()).transfer(houseFee);
        payable(round.winner).transfer(payout);
        
        emit WinnerSelected(roundId, round.winner, payout);
        emit Rollover(roundId, rollover);
    }
    
    function _startNewRound() internal {
        currentRoundId++;
        Round storage newRound = rounds[currentRoundId];
        
        newRound.id = currentRoundId;
        newRound.startTime = block.timestamp;
        newRound.endTime = block.timestamp + config.roundDuration;
        newRound.pot = rolloverAmount;
        
        rolloverAmount = 0;
        
        emit RoundStarted(currentRoundId, newRound.endTime);
    }
    
    /**
     * @notice Get round details
     */
    function getRound(uint256 roundId) external view returns (
        uint256 id,
        uint256 startTime,
        uint256 endTime,
        uint256 pot,
        uint256 participantCount,
        address winner,
        bool completed
    ) {
        Round storage r = rounds[roundId];
        return (r.id, r.startTime, r.endTime, r.pot, 
                r.participants.length, r.winner, r.completed);
    }
    
    /**
     * @notice Get user's tickets in current round
     */
    function getMyTickets() external view returns (uint256) {
        return rounds[currentRoundId].tickets[msg.sender];
    }
}
```

*RecurringLottery with auto-rollover*

<a id="lst:recurring-lottery"></a>

## PowerballLottery: Multi-Number Selection

A more complex lottery mimicking traditional Powerball with 5 main numbers and 1 powerball.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PowerballLottery
 * @notice Multi-tier lottery with 5+1 number matching
 */
contract PowerballLottery is ReentrancyGuard, Ownable {
    
    struct Ticket {
        address owner;
        uint8[5] numbers; // Main numbers: 1-69
        uint8 powerball;  // Powerball: 1-26
        bool claimed;
    }
    
    struct Draw {
        uint256 drawTime;
        uint8[5] winningNumbers;
        uint8 winningPowerball;
        uint256 ticketCount;
        uint256 totalPot;
        bool completed;
        mapping(uint8 => uint256) prizeTiers; // tier => amount
    }
    
    uint256 public ticketPrice = 0.01 ether;
    uint256 public drawInterval = 1 days;
    uint256 public nextDrawTime;
    
    mapping(uint256 => Ticket) public tickets;
    mapping(uint256 => Draw) public draws;
    mapping(uint256 => uint256[]) public drawTickets;
    
    uint256 public ticketCounter;
    uint256 public drawCounter;
    
    // Prize distribution (percentage of pot)
    uint256[5] public prizeShares = [50, 20, 15, 10, 5]; // Jackpot down to match-3
    
    // Events
    event TicketPurchased(
        uint256 indexed ticketId,
        address owner,
        uint8[5] numbers,
        uint8 powerball
    );
    event DrawCompleted(
        uint256 indexed drawId,
        uint8[5] numbers,
        uint8 powerball
    );
    event PrizeClaimed(
        uint256 indexed drawId,
        address winner,
        uint256 tier,
        uint256 amount
    );
    
    constructor() {
        nextDrawTime = block.timestamp + drawInterval;
    }
    
    /**
     * @notice Buy a ticket with chosen numbers
     */
    function buyTicket(uint8[5] calldata numbers, uint8 powerball) 
        external 
        payable 
        returns (uint256 ticketId 
    ) {
        require(msg.value == ticketPrice, "Incorrect payment");
        require(block.timestamp < nextDrawTime, "Draw closed");
        require(_validateNumbers(numbers, powerball), "Invalid numbers");
        
        ticketId = ticketCounter++;
        tickets[ticketId] = Ticket({
            owner: msg.sender,
            numbers: numbers,
            powerball: powerball,
            claimed: false
        });
        
        uint256 currentDraw = drawCounter;
        drawTickets[currentDraw].push(ticketId);
        draws[currentDraw].ticketCount++;
        draws[currentDraw].totalPot += msg.value;
        
        emit TicketPurchased(ticketId, msg.sender, numbers, powerball);
    }
    
    /**
     * @notice Execute the draw (owner or automation)
     */
    function executeDraw() external {
        require(block.timestamp >= nextDrawTime, "Too early");
        require(!draws[drawCounter].completed, "Already drawn");
        
        Draw storage draw = draws[drawCounter];
        
        // Generate winning numbers (upgrade to VRF in production)
        (draw.winningNumbers, draw.winningPowerball) = _generateNumbers();
        draw.drawTime = block.timestamp;
        draw.completed = true;
        
        // Calculate prize pools
        _calculatePrizes(draw);
        
        emit DrawCompleted(drawCounter, draw.winningNumbers, draw.winningPowerball);
        
        // Setup next draw
        drawCounter++;
        nextDrawTime = block.timestamp + drawInterval;
    }
    
    /**
     * @notice Claim prize for a winning ticket
     */
    function claimPrize(uint256 ticketId, uint256 drawId) external nonReentrant {
        require(draws[drawId].completed, "Draw not complete");
        
        Ticket storage ticket = tickets[ticketId];
        require(ticket.owner == msg.sender, "Not ticket owner");
        require(!ticket.claimed, "Already claimed");
        
        uint8 tier = _checkWinningTier(ticket, draws[drawId]);
        require(tier > 0, "Not a winner");
        
        uint256 prize = draws[drawId].prizeTiers[tier];
        require(prize > 0, "No prize for tier");
        
        ticket.claimed = true;
        payable(msg.sender).transfer(prize);
        
        emit PrizeClaimed(drawId, msg.sender, tier, prize);
    }
    
    /**
     * @notice Check if a ticket won
     */
    function checkTicket(uint256 ticketId, uint256 drawId) 
        external 
        view 
        returns (uint8 tier, uint256 prize) 
    {
        if (!draws[drawId].completed) return (0, 0);
        
        tier = _checkWinningTier(tickets[ticketId], draws[drawId]);
        prize = draws[drawId].prizeTiers[tier];
    }
    
    function _validateNumbers(uint8[5] memory numbers, uint8 powerball) 
        internal 
        pure 
        returns (bool) 
    {
        if (powerball < 1 || powerball > 26) return false;
        
        for (uint256 i = 0; i < 5; i++) {
            if (numbers[i] < 1 || numbers[i] > 69) return false;
            // Check duplicates
            for (uint256 j = i + 1; j < 5; j++) {
                if (numbers[i] == numbers[j]) return false;
            }
        }
        return true;
    }
    
    function _generateNumbers() internal view returns (uint8[5] memory numbers, uint8 powerball) {
        uint256 seed = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1),
            block.timestamp,
            drawCounter
        )));
        
        // Generate unique numbers 1-69
        for (uint256 i = 0; i < 5; i++) {
            numbers[i] = uint8((seed 
            seed >>= 8;
            
            // Ensure uniqueness (simple approach)
            for (uint256 j = 0; j < i; j++) {
                if (numbers[i] == numbers[j]) {
                    numbers[i] = uint8(((numbers[i] + seed) 
                }
            }
        }
        
        powerball = uint8((seed 
    }
    
    function _checkWinningTier(Ticket memory ticket, Draw storage draw) 
        internal 
        view 
        returns (uint8) 
    {
        uint8 matches = 0;
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 5; j++) {
                if (ticket.numbers[i] == draw.winningNumbers[j]) {
                    matches++;
                    break;
                }
            }
        }
        
        bool powerballMatch = ticket.powerball == draw.winningPowerball;
        
        // Tier 1: 5 + PB (Jackpot)
        if (matches == 5 && powerballMatch) return 1;
        // Tier 2: 5
        if (matches == 5) return 2;
        // Tier 3: 4 + PB
        if (matches == 4 && powerballMatch) return 3;
        // Tier 4: 4
        if (matches == 4) return 4;
        // Tier 5: 3 + PB
        if (matches == 3 && powerballMatch) return 5;
        
        return 0;
    }
    
    function _calculatePrizes(Draw storage draw) internal {
        uint256 total = draw.totalPot;
        
        // Distribute to tiers
        for (uint8 i = 1; i <= 5; i++) {
            draw.prizeTiers[i] = (total * prizeShares[i - 1]) / 100;
        }
    }
}
```

*PowerballLottery with 5+1 numbers*

<a id="lst:powerball"></a>

## VRF Upgrade Paths

For production use, integrate Chainlink VRF for verifiable randomness.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

/**
 * @title VRFUpgradedLottery
 * @notice Lottery using Chainlink VRF v2 for secure randomness
 */
contract VRFUpgradedLottery is VRFConsumerBaseV2 {
    VRFCoordinatorV2Interface public coordinator;
    
    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;
    
    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint256[] randomWords;
        uint256 drawId;
    }
    
    mapping(uint256 => RequestStatus) public requests;
    uint256 public lastRequestId;
    
    // Lottery state
    mapping(uint256 => uint256) public drawToRequest;
    bool public drawPending;
    
    event RandomnessRequested(uint256 requestId, uint256 drawId);
    event RandomnessFulfilled(uint256 requestId, uint256[] randomWords);
    
    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subId
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        coordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        keyHash = _keyHash;
        subscriptionId = _subId;
    }
    
    /**
     * @notice Request randomness for a draw
     */
    function requestRandomness(uint256 drawId) external returns (uint256 requestId) {
        require(!drawPending, "Draw in progress");
        
        requestId = coordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1 // Request 1 random number
        );
        
        requests[requestId] = RequestStatus({
            fulfilled: false,
            exists: true,
            randomWords: new uint256[](0),
            drawId: drawId
        });
        
        drawToRequest[drawId] = requestId;
        drawPending = true;
        lastRequestId = requestId;
        
        emit RandomnessRequested(requestId, drawId);
    }
    
    /**
     * @notice VRF callback with random numbers
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        require(requests[requestId].exists, "Request not found");
        
        requests[requestId].fulfilled = true;
        requests[requestId].randomWords = randomWords;
        drawPending = false;
        
        // Process the draw with verified randomness
        _completeDraw(requests[requestId].drawId, randomWords[0]);
        
        emit RandomnessFulfilled(requestId, randomWords);
    }
    
    function _completeDraw(uint256 drawId, uint256 randomness) internal {
        // Implement winner selection using verified randomness
        // randomness is cryptographically secure from Chainlink
    }
}
```

*VRF upgrade for secure randomness*

<a id="lst:vrf-upgrade"></a>

## Lottery Security Checklist

| p{6cm}p{8cm}@{}}

**Requirement** | **Implementation** |
|---|---|
| Verifiable randomness | Chainlink VRF or commit-reveal |
| Front-running resistance | Commit-reveal pattern |
| Auto-execution | Chainlink Automation |
| Fair ticket distribution | Cumulative probability mapping |
| Multiple winners support | Tiered prize structures |
| Emergency pause | Circuit breaker pattern |

Chapter 8 continues with gambling games and house edge mechanics.
# Lotteries

## Introduction

Lotteries are among the most popular blockchain gaming applications. They combine simple mechanics with potentially life-changing payouts, but require careful implementation of randomness to ensure fairness.

### Lottery Design Challenges

- **Verifiable Randomness**: How to select winners fairly
- **Front-running Resistance**: Preventing manipulation
- **Auto-execution**: Handling drawings without manual intervention
- **Scaling**: Supporting large player bases efficiently

## SimpleLottery: Commit-Reveal RNG

The commit-reveal pattern provides randomness without external oracle dependency, and honest participants get a fair draw. It is not manipulation-proof, however: the last participant to reveal can compute the final seed before deciding whether to reveal at all, and this contract imposes no penalty for withholding a reveal---production systems need reveal bonds or forfeiture penalties, or should use a VRF instead. Note also that `enter()` allows only one entry per address (buy multiple tickets in a single call): the winning seed XORs together every entry's revealed number, so a participant appearing twice would XOR their own contribution back out of the seed.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
    
    // House fee (2.5%)
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
    ) Ownable(msg.sender) {
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
        // One entry per address: drawWinner XORs each entry's revealed
        // number into the seed, so a participant appearing twice would XOR
        // their own contribution back out and erase it from the accumulator.
        // Buy multiple tickets in a single entry instead.
        require(!_isParticipant(msg.sender), "Already entered");

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
        uint256 winningTicket = seed % totalTickets;
        
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
        // call over transfer: the 2300-gas stipend breaks smart-contract wallets
        (bool feeSuccess, ) = payable(owner()).call{value: houseFee}("");
        require(feeSuccess, "Fee transfer failed");
        (bool paySuccess, ) = payable(winner).call{value: payout}("");
        require(paySuccess, "Payout transfer failed");
        
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

For continuous operation, lotteries need automated rollover mechanisms. Note that rolled-over funds seed the next round's pot without representing any tickets, so the contract tracks `ticketsSold` separately and draws the winner over that count---dividing the pot by the ticket price would invent phantom ticket indices that no participant holds.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
        uint256 ticketsSold; // Tickets actually purchased (pot may also hold rollover)
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
        uint256 rolloverPercent; // % of pot to next round
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
    ) Ownable(msg.sender) {
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
        round.ticketsSold += count;
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
        
        // Draw over tickets actually sold, never over the pot: rolled-over
        // funds inflate the pot without adding tickets, and dividing the pot
        // by the ticket price would create phantom ticket indices no
        // participant holds, bricking the round.
        uint256 totalTickets = round.ticketsSold;
        require(totalTickets > 0, "No tickets sold");
        uint256 winningTicket = randomness % totalTickets;
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
        // call over transfer: the 2300-gas stipend breaks smart-contract wallets
        (bool feeSuccess, ) = payable(owner()).call{value: houseFee}("");
        require(feeSuccess, "Fee transfer failed");
        (bool paySuccess, ) = payable(round.winner).call{value: payout}("");
        require(paySuccess, "Payout transfer failed");
        
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

Prize claiming is deliberately split into two phases. A naive design that pays each winner the full tier pool on claim is insolvent the moment a tier has more than one winner: every winner would withdraw the entire pool, draining funds that belong to other winners---or other draws. Instead, winners first *register* their ticket with `claimPrize()` during a 7-day claim window; once the window closes the winner count per tier is final, and each winner withdraws an equal, pro-rata share of the tier pool with `withdrawPrize()`. Tiers that end the window with no registered winners can be recovered by the owner via `withdrawUnclaimed()`.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PowerballLottery
 * @notice Multi-tier lottery with 5+1 number matching
 * @dev Prize accounting: each draw's tier pools are funded solely from that
 *      draw's own pot, and payouts are split in two phases. Winners first
 *      register their ticket with claimPrize() during the claim window; once
 *      the window closes the winner count per tier is final, and each winner
 *      withdraws an equal share of the tier pool with withdrawPrize(). This
 *      guarantees a draw can never pay out more than its own pot, even with
 *      multiple winners in a tier or several draws sharing the contract
 *      balance. Pools of tiers with no registered winners can be recovered by
 *      the owner after the window via withdrawUnclaimed().
 */
contract PowerballLottery is ReentrancyGuard, Ownable {

    struct Ticket {
        address owner;
        uint256 drawId;   // Draw this ticket was purchased for
        uint8[5] numbers; // Main numbers: 1-69
        uint8 powerball;  // Powerball: 1-26
        bool registered;  // Win registered during the claim window
        bool claimed;     // Prize withdrawn
        uint8 wonTier;    // Winning tier recorded at registration
    }

    struct Draw {
        uint256 drawTime;
        uint8[5] winningNumbers;
        uint8 winningPowerball;
        uint256 ticketCount;
        uint256 totalPot;
        bool completed;
        mapping(uint8 => uint256) prizeTiers;  // tier => pool amount
        mapping(uint8 => uint256) tierWinners; // tier => registered winner count
    }

    uint256 public ticketPrice = 0.01 ether;
    uint256 public drawInterval = 1 days;
    uint256 public nextDrawTime;
    uint256 public constant CLAIM_WINDOW = 7 days;
    
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
    event PrizeRegistered(
        uint256 indexed drawId,
        uint256 indexed ticketId,
        address winner,
        uint256 tier
    );
    event PrizeClaimed(
        uint256 indexed drawId,
        address winner,
        uint256 tier,
        uint256 amount
    );
    
    constructor() Ownable(msg.sender) {
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
            drawId: drawCounter,
            numbers: numbers,
            powerball: powerball,
            registered: false,
            claimed: false,
            wonTier: 0
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
     * @notice Register a winning ticket during the claim window
     * @dev The ticket must have been purchased for `drawId`; payouts happen
     *      via withdrawPrize() once the window closes and the winner count
     *      per tier is final, so a tier pool is never overpaid.
     */
    function claimPrize(uint256 ticketId, uint256 drawId) external nonReentrant {
        Draw storage draw = draws[drawId];
        require(draw.completed, "Draw not complete");
        require(block.timestamp <= draw.drawTime + CLAIM_WINDOW, "Claim window closed");

        Ticket storage ticket = tickets[ticketId];
        require(ticket.drawId == drawId, "Ticket not for this draw");
        require(ticket.owner == msg.sender, "Not ticket owner");
        require(!ticket.registered, "Already registered");

        uint8 tier = _checkWinningTier(ticket, draw);
        require(tier > 0, "Not a winner");
        require(draw.prizeTiers[tier] > 0, "No prize for tier");

        ticket.registered = true;
        ticket.wonTier = tier;
        draw.tierWinners[tier]++;

        emit PrizeRegistered(drawId, ticketId, msg.sender, tier);
    }

    /**
     * @notice Withdraw an equal share of the tier pool after the claim window
     */
    function withdrawPrize(uint256 ticketId) external nonReentrant {
        Ticket storage ticket = tickets[ticketId];
        require(ticket.owner == msg.sender, "Not ticket owner");
        require(ticket.registered, "Not registered");
        require(!ticket.claimed, "Already claimed");

        Draw storage draw = draws[ticket.drawId];
        require(block.timestamp > draw.drawTime + CLAIM_WINDOW, "Claim window open");

        uint8 tier = ticket.wonTier;
        uint256 prize = draw.prizeTiers[tier] / draw.tierWinners[tier];

        ticket.claimed = true;
        // call over transfer: the 2300-gas stipend breaks smart-contract wallets
        (bool success, ) = payable(msg.sender).call{value: prize}("");
        require(success, "Prize transfer failed");

        emit PrizeClaimed(ticket.drawId, msg.sender, tier, prize);
    }

    /**
     * @notice Recover pools of tiers with no registered winners after the claim window
     */
    function withdrawUnclaimed(uint256 drawId) external onlyOwner {
        Draw storage draw = draws[drawId];
        require(draw.completed, "Draw not complete");
        require(block.timestamp > draw.drawTime + CLAIM_WINDOW, "Claim window open");

        uint256 amount;
        for (uint8 i = 1; i <= 5; i++) {
            if (draw.tierWinners[i] == 0) {
                amount += draw.prizeTiers[i];
                draw.prizeTiers[i] = 0;
            }
        }
        require(amount > 0, "Nothing to withdraw");

        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Withdraw transfer failed");
    }

    /**
     * @notice Check if a ticket won
     * @dev Returns the current per-winner share; the final share is only
     *      known once the claim window has closed.
     */
    function checkTicket(uint256 ticketId, uint256 drawId)
        external
        view
        returns (uint8 tier, uint256 prize)
    {
        if (!draws[drawId].completed) return (0, 0);
        if (tickets[ticketId].drawId != drawId) return (0, 0);

        tier = _checkWinningTier(tickets[ticketId], draws[drawId]);
        uint256 winners = draws[drawId].tierWinners[tier];
        prize = winners > 0
            ? draws[drawId].prizeTiers[tier] / winners
            : draws[drawId].prizeTiers[tier];
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
            numbers[i] = uint8((seed % 69) + 1);
            seed >>= 8;
            
            // Ensure uniqueness (simple approach)
            for (uint256 j = 0; j < i; j++) {
                if (numbers[i] == numbers[j]) {
                    numbers[i] = uint8(((numbers[i] + seed) % 69) + 1);
                }
            }
        }
        
        powerball = uint8((seed % 26) + 1);
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

> **Version note.** This example targets Chainlink VRF v2.5. Compared to v2, the consumer base contract is `VRFConsumerBaseV2Plus` (which exposes the coordinator as `s_vrfCoordinator` and brings its own `ConfirmedOwner`), subscription IDs are `uint256` rather than `uint64`, and `requestRandomWords` takes a single `RandomWordsRequest` struct whose `extraArgs` carries a `nativePayment` flag---set it to `true` to pay VRF fees in native ETH instead of LINK.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title VRFUpgradedLottery
 * @notice Lottery using Chainlink VRF v2.5 for secure randomness
 * @dev VRFConsumerBaseV2Plus exposes the coordinator as `s_vrfCoordinator`
 *      and brings its own ConfirmedOwner (onlyOwner) with it.
 */
contract VRFUpgradedLottery is VRFConsumerBaseV2Plus {
    bytes32 public keyHash;
    uint256 public subscriptionId; // v2.5 subscription ids are uint256
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
        uint256 _subId
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        keyHash = _keyHash;
        subscriptionId = _subId;
    }

    /**
     * @notice Request randomness for a draw
     */
    function requestRandomness(uint256 drawId) external returns (uint256 requestId) {
        require(!drawPending, "Draw in progress");

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1, // Request 1 random number
                // nativePayment: true would pay VRF fees in native ETH
                // instead of LINK -- a v2.5 addition.
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
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
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
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

| **Requirement** | **Implementation** |
|---|---|
| Verifiable randomness | Chainlink VRF or commit-reveal |
| Front-running resistance | Commit-reveal pattern |
| Auto-execution | Chainlink Automation |
| Fair ticket distribution | Cumulative probability mapping |
| Multiple winners support | Two-phase claims with pro-rata tier pools |
| Emergency pause | Circuit breaker pattern |

Chapter 8 continues with gambling games and house edge mechanics.
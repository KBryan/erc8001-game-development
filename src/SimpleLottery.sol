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
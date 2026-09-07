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
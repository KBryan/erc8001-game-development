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
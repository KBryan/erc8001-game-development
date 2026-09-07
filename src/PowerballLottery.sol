// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
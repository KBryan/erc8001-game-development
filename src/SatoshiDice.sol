// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SatoshiDice
 * @notice Provably fair dice game with configurable odds
 */
contract SatoshiDice is ReentrancyGuard, Ownable {
    
    struct Bet {
        address player;
        uint256 amount;
        uint8 target;     // Roll under this number to win
        uint256 payout;   // Potential payout
        uint256 commitBlock;
        bytes32 commitHash;
        bool revealed;
        bool won;
        uint8 result;
    }
    
    mapping(bytes32 => Bet) public bets;
    mapping(address => bytes32[]) public playerBets;
    
    uint256 public minBet = 0.001 ether;
    uint256 public maxBet = 1 ether;
    uint256 public houseEdgeBps = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_ROLL = 100;
    
    uint256 public totalWagered;
    uint256 public totalPaid;
    uint256 public betCount;
    
    // Events
    event BetPlaced(
        bytes32 indexed commitHash,
        address player,
        uint256 amount,
        uint8 target,
        uint256 payout
    );
    event BetRevealed(
        bytes32 indexed commitHash,
        address player,
        uint8 result,
        bool won,
        uint256 payout
    );
    event FundsDeposited(address from, uint256 amount);
    event FundsWithdrawn(address to, uint256 amount);
    
    /**
     * @notice Place a bet by committing a hash
     * @param target Roll under this number (2-98) to win
     */
    function placeBet(uint8 target) external payable returns (bytes32 commitHash) {
        // Target 99 is excluded: at 2% house edge its payout would exactly
        // equal the bet, leaving no winning outcome for the player.
        require(target > 1 && target < MAX_ROLL - 1, "Target must be 2-98");
        require(msg.value >= minBet && msg.value <= maxBet, "Invalid bet size");
        
        // Calculate payout based on probability
        // Probability of winning: (target - 1) / 100
        // Fair payout: bet * 100 / (target - 1)
        // With house edge: fair payout * (1 - houseEdge)
        
        uint256 fairPayout = (msg.value * MAX_ROLL * (BPS_DENOMINATOR - houseEdgeBps)) /
                           ((target - 1) * BPS_DENOMINATOR);
        
        require(
            address(this).balance >= fairPayout - msg.value,
            "Insufficient contract balance"
        );
        
        commitHash = keccak256(abi.encodePacked(
            msg.sender,
            block.number,
            msg.value,
            target,
            block.timestamp
        ));
        
        require(bets[commitHash].amount == 0, "Bet exists");
        
        bets[commitHash] = Bet({
            player: msg.sender,
            amount: msg.value,
            target: target,
            payout: fairPayout,
            commitBlock: block.number,
            commitHash: commitHash,
            revealed: false,
            won: false,
            result: 0
        });
        
        playerBets[msg.sender].push(commitHash);
        
        unchecked {
            totalWagered += msg.value;
            betCount++;
        }
        
        emit BetPlaced(commitHash, msg.sender, msg.value, target, fairPayout);
    }
    
    /**
     * @notice Reveal the result and settle the bet
     */
    function revealBet(bytes32 commitHash) external nonReentrant {
        Bet storage bet = bets[commitHash];
        require(bet.player != address(0), "Bet not found");
        require(!bet.revealed, "Already revealed");
        require(
            block.number > bet.commitBlock + 1,
            "Wait for next block"
        );
        require(
            block.number < bet.commitBlock + 256,
            "Blockhash expired"
        );
        
        // Generate roll from blockhash
        uint256 randomness = uint256(keccak256(abi.encodePacked(
            blockhash(bet.commitBlock + 1),
            commitHash
        )));
        
        uint8 result = uint8(randomness % MAX_ROLL) + 1; // 1-100
        bet.result = result;
        bet.revealed = true;
        
        if (result < bet.target) {
            bet.won = true;
            totalPaid += bet.payout;
            // call over transfer: the 2300-gas stipend breaks smart-contract wallets
            (bool success, ) = payable(bet.player).call{value: bet.payout}("");
            require(success, "Payout transfer failed");
        }
        
        emit BetRevealed(
            commitHash,
            bet.player,
            result,
            bet.won,
            bet.won ? bet.payout : 0
        );
    }
    
    /**
     * @notice Calculate potential payout
     */
    function calculatePayout(uint256 betAmount, uint8 target) 
        external 
        view 
        returns (uint256) 
    {
        return (betAmount * MAX_ROLL * (BPS_DENOMINATOR - houseEdgeBps)) /
               ((target - 1) * BPS_DENOMINATOR);
    }
    
    /**
     * @notice Get expected value of a bet
     */
    function expectedValue(uint256 betAmount, uint8 target) 
        external 
        view 
        returns (int256) 
    {
        uint256 winProb = (target - 1);
        uint256 loseProb = MAX_ROLL - winProb;
        uint256 payout = this.calculatePayout(betAmount, target);
        
        // EV = (winProb * winAmount) - (loseProb * loseAmount)
        int256 winValue = int256((winProb * (payout - betAmount)) / MAX_ROLL);
        int256 loseValue = int256((loseProb * betAmount) / MAX_ROLL);
        
        return winValue - loseValue;
    }
    
    /**
     * @notice Deposit funds to contract
     */
    function deposit() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }
    
    /**
     * @notice Withdraw funds (owner only)
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Withdraw transfer failed");
        emit FundsWithdrawn(owner(), amount);
    }
    
    /**
     * @notice Get player bet history
     */
    function getPlayerBets(address player) external view returns (bytes32[] memory) {
        return playerBets[player];
    }
    
    /**
     * @notice Get contract statistics
     */
    function getStats() external view returns (
        uint256 wagered,
        uint256 paid,
        uint256 bets,
        uint256 balance,
        int256 profit
    ) {
        wagered = totalWagered;
        paid = totalPaid;
        bets = betCount;
        balance = address(this).balance;
        profit = int256(wagered) - int256(paid);
    }
}
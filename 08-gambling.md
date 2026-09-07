# Gambling Games

## Introduction

Blockchain gambling games can offer provably fair mechanics, transparent odds, and instant global accessibility---when built on a secure randomness source. This chapter implements classic games with mathematical precision and proper house edge management; note that the Roulette example deliberately uses insecure randomness as a teaching exercise.

> **Legal disclaimer.** Operating an on-chain gambling service is illegal or licence-gated in most jurisdictions, regardless of how the contracts are deployed or who holds the keys. The contracts in this chapter are educational implementations for studying game mechanics, house edge mathematics, and security patterns---they are not products to deploy. Some of them (notably Roulette) are deliberately insecure teaching examples. You are responsible for knowing and complying with the law wherever you operate.

### House Edge Fundamentals

The house edge ensures long-term sustainability while providing entertainment value:

```
House Edge = -(Expected Value / Wager Amount) × 100%
```

Because the player's expected value is negative, the house edge comes out as a positive percentage---the share of each wager the house keeps on average. A 2% house edge means players lose an average of 2% per bet over the long run---comparable to or better than traditional casinos.

## SatoshiDice: Modernized

SatoshiDice was the first Bitcoin gambling game. This Ethereum implementation uses commit-reveal for fairness.

```solidity

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
```

*SatoshiDice implementation*

<a id="lst:satoshidice"></a>

### SatoshiDice Mathematics

| **Target** | **Win Prob** | **Multiplier** | **House Edge** | **RTP** |
|---|---|---|---|---|
| 10 | 9% | 10.89x | 2.0% | 98.0% |
| 25 | 24% | 4.08x | 2.0% | 98.0% |
| 50 | 49% | 2.00x | 2.0% | 98.0% |
| 75 | 74% | 1.32x | 2.0% | 98.0% |
| 90 | 89% | 1.10x | 2.0% | 98.0% |

## Roulette: Multi-Bet Type

European roulette with single zero, supporting multiple bet types. This contract is an insecure teaching example: its spin result is precomputable in the same transaction (see the warning blocks below), so it must never be deployed with real funds.

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Roulette
 * @notice European roulette with 6 bet types
 * @dev WARNING: INSECURE RANDOMNESS - educational only, do not deploy with
 *      real funds. The spin result is derived from blockhash(block.number - 1),
 *      msg.sender, and block.timestamp in the same transaction that places the
 *      bet, so every input is known before the transaction executes. An
 *      attacker contract can precompute the outcome and submit a straight-up
 *      35:1 bet only when it is guaranteed to win. A production casino must
 *      use a verifiable randomness source such as Chainlink VRF.
 */
contract Roulette is ReentrancyGuard, Ownable {
    
    enum BetType {
        Straight,    // Single number: 35:1
        Split,       // 2 numbers: 17:1
        Street,      // 3 numbers: 11:1
        Corner,      // 4 numbers: 8:1
        SixLine,     // 6 numbers: 5:1
        EvenOdd,     // 18 numbers: 1:1
        RedBlack,    // 18 numbers: 1:1
        HighLow,     // 18 numbers: 1:1
        Dozen,       // 12 numbers: 2:1
        Column       // 12 numbers: 2:1
    }
    
    struct Bet {
        BetType betType;
        uint8[] numbers;
        uint256 amount;
    }
    
    struct Spin {
        address player;
        Bet[] bets;
        uint256 totalBet;
        uint256 blockNumber;
        bool spun;
        uint8 result;
        uint256 totalPayout;
    }
    
    // Roulette wheel numbers (European)
    // Red: 1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36
    // Black: 2,4,6,8,10,11,13,15,17,20,22,24,26,28,29,31,33,35
    // Green: 0
    
    mapping(uint8 => bool) public isRed;
    mapping(address => Spin[]) public playerSpins;
    
    uint256 public minBet = 0.001 ether;
    uint256 public maxTotalBet = 10 ether;
    uint256 public houseEdgeBps = 270; // 2.7% (single zero advantage)
    
    uint256 public totalWagered;
    uint256 public totalPaid;
    
    event SpinPlaced(address indexed player, uint256 spinId, uint256 totalBet);
    event SpinResult(
        address indexed player,
        uint256 spinId,
        uint8 result,
        uint256 payout,
        bool isRed
    );
    
    constructor() {
        // Initialize red numbers
        uint8[18] memory reds = [1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
        for (uint256 i = 0; i < reds.length; i++) {
            isRed[reds[i]] = true;
        }
    }
    
    /**
     * @notice Place multiple bets and spin
     */
    function spin(Bet[] calldata bets) external payable nonReentrant returns (uint256 spinId) {
        require(bets.length > 0, "No bets");
        require(bets.length <= 10, "Max 10 bets per spin");
        
        uint256 totalBet = 0;
        for (uint256 i = 0; i < bets.length; i++) {
            totalBet += bets[i].amount;
            require(_validateBet(bets[i]), "Invalid bet");
        }
        
        require(msg.value == totalBet, "Incorrect payment");
        require(totalBet >= minBet, "Bet too small");
        require(totalBet <= maxTotalBet, "Bet too large");
        
        // Generate result
        uint8 result = _generateResult();
        uint256 payout = _calculatePayout(bets, result);
        
        require(
            address(this).balance >= payout,
            "Insufficient balance"
        );
        
        // Record spin
        Spin storage newSpin = playerSpins[msg.sender].push();
        spinId = playerSpins[msg.sender].length - 1;
        
        newSpin.player = msg.sender;
        newSpin.totalBet = totalBet;
        newSpin.blockNumber = block.number;
        newSpin.spun = true;
        newSpin.result = result;
        newSpin.totalPayout = payout;
        
        // Copy bets
        for (uint256 i = 0; i < bets.length; i++) {
            newSpin.bets.push(bets[i]);
        }
        
        totalWagered += totalBet;

        // Pay out
        if (payout > 0) {
            totalPaid += payout;
            // call over transfer: the 2300-gas stipend breaks smart-contract wallets
            (bool success, ) = payable(msg.sender).call{value: payout}("");
            require(success, "Payout transfer failed");
        }
        
        emit SpinPlaced(msg.sender, spinId, totalBet);
        emit SpinResult(msg.sender, spinId, result, payout, isRed[result]);
    }
    
    /**
     * @notice Get payout multiplier for bet type
     */
    function getMultiplier(BetType betType) public pure returns (uint256) {
        if (betType == BetType.Straight) return 36;
        if (betType == BetType.Split) return 18;
        if (betType == BetType.Street) return 12;
        if (betType == BetType.Corner) return 9;
        if (betType == BetType.SixLine) return 6;
        if (betType == BetType.EvenOdd) return 2;
        if (betType == BetType.RedBlack) return 2;
        if (betType == BetType.HighLow) return 2;
        if (betType == BetType.Dozen) return 3;
        if (betType == BetType.Column) return 3;
        return 0;
    }
    
    /**
     * @notice Get house edge for bet type
     */
    function getHouseEdge(BetType betType) external pure returns (uint256 bps) {
        // European roulette: 2.7% house edge on all bets
        // (1/37 = 0.027)
        return 270;
    }
    
    /**
     * @dev WARNING: INSECURE RANDOMNESS - educational only, do not deploy
     *      with real funds. blockhash(block.number - 1), msg.sender, and
     *      block.timestamp are all readable before this transaction runs, so
     *      a contract can compute the result off-chain (or in the same
     *      transaction) and bet only on guaranteed wins. Production must use
     *      a VRF.
     */
    function _generateResult() internal view returns (uint8) {
        return uint8(
            uint256(keccak256(abi.encodePacked(
                blockhash(block.number - 1),
                msg.sender,
                block.timestamp
            ))) % 37
        ); // 0-36
    }
    
    function _validateBet(Bet memory bet) internal pure returns (bool) {
        if (bet.amount == 0) return false;
        
        uint256 expectedNumbers;
        if (bet.betType == BetType.Straight) expectedNumbers = 1;
        else if (bet.betType == BetType.Split) expectedNumbers = 2;
        else if (bet.betType == BetType.Street) expectedNumbers = 3;
        else if (bet.betType == BetType.Corner) expectedNumbers = 4;
        else if (bet.betType == BetType.SixLine) expectedNumbers = 6;
        else if (bet.betType == BetType.EvenOdd) expectedNumbers = 0; // Special
        else if (bet.betType == BetType.RedBlack) expectedNumbers = 0;
        else if (bet.betType == BetType.HighLow) expectedNumbers = 0;
        else if (bet.betType == BetType.Dozen) expectedNumbers = 0;
        else if (bet.betType == BetType.Column) expectedNumbers = 0;
        
        if (expectedNumbers > 0 && bet.numbers.length != expectedNumbers) {
            return false;
        }
        
        // Validate numbers in range
        for (uint256 i = 0; i < bet.numbers.length; i++) {
            if (bet.numbers[i] > 36) return false;
        }
        
        return true;
    }
    
    function _calculatePayout(Bet[] calldata bets, uint8 result)
        internal
        view
        returns (uint256 totalPayout)
    {
        for (uint256 i = 0; i < bets.length; i++) {
            if (_isWinningBet(bets[i], result)) {
                totalPayout += bets[i].amount * getMultiplier(bets[i].betType);
            }
        }
    }
    
    function _isWinningBet(Bet memory bet, uint8 result) internal view returns (bool) {
        if (bet.betType == BetType.Straight ||
            bet.betType == BetType.Split ||
            bet.betType == BetType.Street ||
            bet.betType == BetType.Corner ||
            bet.betType == BetType.SixLine) {
            for (uint256 i = 0; i < bet.numbers.length; i++) {
                if (bet.numbers[i] == result) return true;
            }
            return false;
        }
        
        if (bet.betType == BetType.EvenOdd) {
            if (result == 0) return false;
            // numbers[0]: 0 = even, 1 = odd
            bool betEven = bet.numbers[0] == 0;
            bool resultEven = result % 2 == 0;
            return betEven == resultEven;
        }
        
        if (bet.betType == BetType.RedBlack) {
            if (result == 0) return false;
            bool betRed = bet.numbers[0] == 0;
            return betRed == isRed[result];
        }
        
        if (bet.betType == BetType.HighLow) {
            if (result == 0) return false;
            bool betLow = bet.numbers[0] == 0; // 1-18
            return betLow ? (result <= 18) : (result >= 19);
        }
        
        if (bet.betType == BetType.Dozen) {
            uint8 dozen = bet.numbers[0]; // 0, 1, 2
            if (dozen == 0) return result >= 1 && result <= 12;
            if (dozen == 1) return result >= 13 && result <= 24;
            return result >= 25 && result <= 36;
        }
        
        if (bet.betType == BetType.Column) {
            uint8 col = bet.numbers[0]; // 0, 1, 2
            return result > 0 && (result - 1) % 3 == col;
        }
        
        return false;
    }
    
    receive() external payable {}
}
```

*Roulette implementation with 6 bet types*

<a id="lst:roulette"></a>

### Roulette Mathematics

European roulette with single zero has a consistent 2.7% house edge:

| **Bet Type** | **Numbers Covered** | **Payout** | **Probability** |
|---|---|---|---|
| Straight | 1 | 35:1 | 2.7% |
| Split | 2 | 17:1 | 5.4% |
| Street | 3 | 11:1 | 8.1% |
| Corner | 4 | 8:1 | 10.8% |
| Six Line | 6 | 5:1 | 16.2% |
| Dozen/Column | 12 | 2:1 | 32.4% |
| Even/Odd/Red/Black/High/Low | 18 | 1:1 | 48.6% |

## House Edge Calculations

### Expected Value Formula

For any bet, the expected value is:

```
EV = (P_win × W) - (P_loss × B)
```

Where:
- $P_{win}$ = Probability of winning
- $P_{loss}$ = Probability of losing
- $W$ = Win amount (payout - bet)
- $B$ = Bet amount

### Risk of Ruin

For bankroll management, the risk of ruin formula:

```
RoR = (q / p)^n
```

Where:
- $p$ = Probability of winning
- $q$ = Probability of losing
- $n$ = Number of betting units in bankroll

### Kelly Criterion

Optimal bet sizing:

```
f* = (bp - q) / b
```

Where:
- $f^*$ = Fraction of bankroll to bet
- $b$ = Net odds received
- $p$ = Probability of winning
- $q$ = Probability of losing

## Responsible Gaming Features

```solidity

abstract contract ResponsibleGaming {
    
    mapping(address => uint256) public dailyWagered;
    mapping(address => uint256) public lastWagerReset;
    mapping(address => uint256) public lossLimit;
    mapping(address => bool) public selfExcluded;
    
    uint256 public globalDailyLimit = 100 ether;
    uint256 public maxLossLimit = 50 ether;
    
    modifier responsibleGaming(address player, uint256 amount) {
        require(!selfExcluded[player], "Self-excluded");
        
        // Reset daily counter if needed
        if (block.timestamp > lastWagerReset[player] + 1 days) {
            dailyWagered[player] = 0;
            lastWagerReset[player] = block.timestamp;
        }
        
        require(
            dailyWagered[player] + amount <= globalDailyLimit,
            "Daily limit exceeded"
        );
        
        _;
        
        dailyWagered[player] += amount;
    }
    
    function selfExclude() external {
        selfExcluded[msg.sender] = true;
    }
    
    function setLossLimit(uint256 limit) external {
        require(limit <= maxLossLimit, "Limit too high");
        lossLimit[msg.sender] = limit;
    }
}
```

*Responsible gaming protections*

With gambling mechanics established, Chapter 9 covers production deployment across multiple chains.
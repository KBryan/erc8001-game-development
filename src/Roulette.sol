// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Roulette
 * @notice European roulette with 6 bet types
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
        
        // Pay out
        if (payout > 0) {
            totalPaid += payout;
            payable(msg.sender).transfer(payout);
        }
        
        totalWagered += totalBet;
        
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
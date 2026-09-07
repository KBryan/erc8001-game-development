// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract GamingErrors {
    // Custom error declarations
    error InsufficientBalance(uint256 available, uint256 required);
    error InvalidBetAmount(uint256 amount, uint256 min, uint256 max);
    error GameNotActive(uint256 gameId, uint8 currentState);
    error NotAuthorized(address caller, address required);
    error RoundNotEnded(uint256 currentBlock, uint256 endBlock);
    error PayoutCalculationFailed(uint256 bet, uint256 odds);

    mapping(address => uint256) public balances;
    mapping(uint256 => uint8) public gameStates;

    function placeBet(uint256 gameId, uint256 amount) external {
        // Gas-efficient error handling
        if (balances[msg.sender] < amount) {
            revert InsufficientBalance(balances[msg.sender], amount);
        }

        if (gameStates[gameId] != 1) {
            revert GameNotActive(gameId, gameStates[gameId]);
        }

        if (amount < 0.01 ether || amount > 10 ether) {
            revert InvalidBetAmount(amount, 0.01 ether, 10 ether);
        }

        // Proceed with bet logic...
    }
}
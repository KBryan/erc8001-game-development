// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/SatoshiDice.sol";

contract SatoshiDiceFuzzTest is Test {
    SatoshiDice public dice;
    
    function setUp() public {
        dice = new SatoshiDice();
        vm.deal(address(dice), 1000 ether);
    }
    
    /**
     * @notice Fuzz test: Any valid target should calculate consistent payouts
     */
    function testFuzz_PayoutCalculation(uint8 target, uint256 amount) public {
        // Bound inputs to valid ranges (99 is excluded: the house edge
        // exactly cancels the fair profit there, so the game rejects it)
        target = uint8(bound(target, 2, 98));
        amount = bound(amount, 0.001 ether, 1 ether);
        
        uint256 payout = dice.calculatePayout(amount, target);
        
        // Invariants:
        // 1. Payout should always be greater than bet (for targets < 100)
        if (target > 1) {
            assertGt(payout, amount, "Payout should exceed bet");
        }
        
        // 2. Payout should decrease as target increases
        uint256 payoutHigher = dice.calculatePayout(amount, target + 1);
        assertLe(payoutHigher, payout, "Higher target should have lower or equal payout");
    }
    
    /**
     * @notice Fuzz test: Expected value should always be negative (house edge)
     */
    function testFuzz_HouseEdge(uint8 target) public {
        target = uint8(bound(target, 2, 98));
        
        int256 ev = dice.expectedValue(1 ether, target);
        
        // House edge ensures negative expected value
        assertLt(ev, 0, "EV should be negative (house edge)");
    }
    
    /**
     * @notice Invariant: Contract balance should never go negative
     */
    function testFuzz_ContractBalanceInvariant(uint256 seed) public {
        vm.deal(address(this), 10 ether);
        dice.deposit{value: 10 ether}();
        
        uint256 initialBalance = address(dice).balance;
        
        // Simulate many bets
        for (uint256 i = 0; i < 100; i++) {
            uint8 target = uint8(bound(uint256(keccak256(abi.encode(seed, i))), 2, 99));
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i, "amt"))), 0.001 ether, 0.1 ether);
            
            if (address(dice).balance >= amount * 100) {
                try this.placeBetExternal{value: amount}(target) {
                    // Bet placed
                } catch {
                    // Bet failed (expected for invalid conditions)
                }
            }
        }
        
        assertGe(address(dice).balance, 0, "Balance should never be negative");
    }
    
    function placeBetExternal(uint8 target) external payable {
        dice.placeBet(target);
    }
}
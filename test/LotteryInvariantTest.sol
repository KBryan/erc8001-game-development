// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/SimpleLottery.sol";

contract LotteryInvariantTest is Test {
    SimpleLottery public lottery;
    Handler public handler;
    
    function setUp() public {
        lottery = new SimpleLottery(
            0.01 ether,
            3,
            10,
            10
        );
        handler = new Handler(lottery);
        
        targetContract(address(handler));
    }
    
    /**
     * @notice Invariant: Total invested should equal pot when no payouts
     */
    function invariant_PotAccounting() public view {
        assertEq(address(lottery).balance, lottery.pot());
    }
    
    /**
     * @notice Invariant: Entry count should match entries array length
     */
    function invariant_EntryCount() public {
        // Would need to track entries via handler
    }
    
    /**
     * @notice Invariant: Winner should only be set after draw
     */
    function invariant_WinnerState() public view {
        if (lottery.winner() != address(0)) {
            assertTrue(lottery.phase() == SimpleLottery.Phase.Closed);
        }
    }
}

contract Handler is Test {
    SimpleLottery public lottery;
    
    constructor(SimpleLottery _lottery) {
        lottery = _lottery;
    }
    
    function enter(uint256 amount) external {
        amount = bound(amount, 0.01 ether, 0.1 ether);
        vm.deal(address(this), amount);
        lottery.enter{value: amount}(1);
    }
    
    function commit(bytes32 hash) external {
        lottery.commit(hash);
    }
    
    receive() external payable {}
}
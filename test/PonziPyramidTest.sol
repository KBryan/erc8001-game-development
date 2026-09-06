// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/SimplePonzi.sol";
import "../src/SimplePyramid.sol";

contract PonziPyramidTest is Test {
    SimplePonzi public ponzi;
    SimplePyramid public pyramid;
    
    address public alice = address(1);
    address public bob = address(2);
    address public carol = address(3);
    
    // The test contract deploys the pyramid, making it the creator that
    // receives commissions -- it must be able to accept ETH
    receive() external payable {}

    function setUp() public {
        ponzi = new SimplePonzi();
        pyramid = new SimplePyramid();
        
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }
    
    function test_PonziPayout() public {
        // Alice invests first
        vm.prank(alice);
        ponzi.invest{value: 0.01 ether}();
        
        uint256 aliceBalanceBefore = alice.balance;
        
        // Bob invests, paying Alice
        vm.prank(bob);
        ponzi.invest{value: 0.011 ether}();
        
        // Alice should receive 110% of her investment
        assertEq(alice.balance - aliceBalanceBefore, 0.011 ether);
    }
    
    function test_PyramidCommissions() public {
        address creator = pyramid.creator();
        uint256 creatorBalanceBefore = creator.balance;
        
        // Alice joins under creator
        vm.prank(alice);
        pyramid.join{value: 0.1 ether}(creator);
        
        // Creator should receive commission
        assertTrue(creator.balance > creatorBalanceBefore);
    }
}
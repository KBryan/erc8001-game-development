// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/SimplePonzi.sol";

contract SimplePonziTest is Test {
    SimplePonzi public ponzi;
    address public alice = address(1);
    address public bob = address(2);

    function setUp() public {
        ponzi = new SimplePonzi();
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
    }

    function test_InitialState() public {
        assertEq(ponzi.currentWinner(), address(0));
        assertEq(ponzi.highestBid(), 0);
    }

    function test_Invest() public {
        vm.prank(alice);
        ponzi.invest{value: 0.1 ether}();

        assertEq(ponzi.currentWinner(), alice);
        assertEq(ponzi.highestBid(), 0.1 ether);
    }
}
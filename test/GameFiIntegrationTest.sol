// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/GameToken.sol";
import "../src/GameStaking.sol";

contract GameFiIntegrationTest is Test {
    GameToken public token;
    GameStaking public staking;
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    function setUp() public {
        token = new GameToken("GameToken", "GAME", 1e9 ether, 100000 ether);
        staking = new GameStaking(address(token), address(token));
        
        // Setup roles
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.grantRole(token.GAME_CONTRACT_ROLE(), address(staking));
        
        // Fund users
        token.mint(alice, 1000 ether, "initial");
        token.mint(bob, 1000 ether, "initial");
        
        // Add rewards to staking
        token.mint(address(this), 10000 ether, "rewards");
        token.approve(address(staking), 10000 ether);
        staking.addRewards(10000 ether);
    }
    
    function test_StakeAndEarnRewards() public {
        vm.startPrank(alice);
        
        token.approve(address(staking), 100 ether);
        uint256 stakeId = staking.stake(100 ether, 30 days);
        
        // Fast forward 15 days
        vm.warp(block.timestamp + 15 days);
        
        uint256 reward = staking.calculateReward(alice, stakeId);
        assertGt(reward, 0, "Should have earned rewards");
        
        // Fast forward to end
        vm.warp(block.timestamp + 15 days);
        
        uint256 balanceBefore = token.balanceOf(alice);
        staking.unstake(stakeId);
        
        assertGt(token.balanceOf(alice) - balanceBefore, 100 ether);
        
        vm.stopPrank();
    }
    
    function test_EmergencyUnstakeWhenRewardPoolUnfunded() public {
        // Fresh staking contract whose reward pool is never funded
        GameStaking unfunded = new GameStaking(address(token), address(token));

        vm.startPrank(alice);
        token.approve(address(unfunded), 100 ether);
        uint256 stakeId = unfunded.stake(100 ether, 30 days);

        vm.warp(block.timestamp + 30 days);

        // Strict unstake reverts: the pool cannot cover the earned reward
        vm.expectRevert("Insufficient reward pool");
        unfunded.unstake(stakeId);

        // Emergency exit returns principal only, forfeiting the reward
        uint256 balanceBefore = token.balanceOf(alice);
        unfunded.emergencyUnstake(stakeId);
        assertEq(token.balanceOf(alice) - balanceBefore, 100 ether);
        assertEq(unfunded.totalStaked(), 0);

        // The stake is spent -- no double exit
        vm.expectRevert("Already claimed");
        unfunded.emergencyUnstake(stakeId);
        vm.stopPrank();
    }

    function test_MultipleUsersStaking() public {
        // Alice stakes
        vm.startPrank(alice);
        token.approve(address(staking), 500 ether);
        staking.stake(500 ether, 30 days);
        vm.stopPrank();
        
        // Bob stakes
        vm.startPrank(bob);
        token.approve(address(staking), 300 ether);
        staking.stake(300 ether, 30 days);
        vm.stopPrank();
    }
}
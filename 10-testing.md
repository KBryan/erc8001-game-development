# Testing

## Introduction

Comprehensive testing is non-negotiable for gaming contracts handling real value. Foundry provides industry-leading testing capabilities that surpass traditional JavaScript-based frameworks.

## Testing Patterns

### Unit Testing

Unit tests isolate individual functions with controlled inputs:

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/SimplePonzi.sol";

contract SimplePonziTest is Test {
    SimplePonzi public ponzi;
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    
    function setUp() public {
        ponzi = new SimplePonzi();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }
    
    function test_InitialState() public {
        assertEq(ponzi.currentWinner(), address(0));
        assertEq(ponzi.highestBid(), 0);
        assertEq(ponzi.totalInvested(), 0);
    }
    
    function test_FirstInvestment() public {
        vm.prank(alice);
        ponzi.invest{value: 0.01 ether}();
        
        assertEq(ponzi.currentWinner(), alice);
        assertEq(ponzi.highestBid(), 0.01 ether);
        assertEq(ponzi.investorCount(), 1);
    }
    
    function test_SecondInvestmentPaysFirst() public {
        // Alice invests first
        vm.prank(alice);
        ponzi.invest{value: 0.01 ether}();
        
        uint256 aliceBalanceBefore = alice.balance;
        
        // Bob invests, Alice should get paid
        vm.prank(bob);
        ponzi.invest{value: 0.011 ether}();
        
        // Alice should receive 110
        uint256 expectedPayout = 0.01 ether * 11000 / 10000;
        assertEq(alice.balance - aliceBalanceBefore, expectedPayout);
        
        // Bob is now winner
        assertEq(ponzi.currentWinner(), bob);
    }
    
    function test_RevertOnInsufficientInvestment() public {
        // First investment needs minimum
        vm.prank(alice);
        vm.expectRevert(SimplePonzi.InsufficientInvestment.selector);
        ponzi.invest{value: 0.001 ether}(); // Too small
    }
    
    function test_RevertOnDirectTransfer() public {
        vm.prank(alice);
        vm.expectRevert("Use invest() function");
        payable(address(ponzi)).transfer(0.01 ether);
    }
}
```

*Unit testing with Foundry*

<a id="lst:unit-testing"></a>

### Integration Testing

Integration tests verify multiple contracts working together:

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "../src/GameFi/GameToken.sol";
import "../src/GameFi/GameStaking.sol";

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
```

*Integration testing*

## Fuzz Testing

Fuzz tests generate random inputs to discover edge cases:

```solidity

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
        // Bound inputs to valid ranges
        target = uint8(bound(target, 2, 99));
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
        target = uint8(bound(target, 2, 99));
        
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
```

*Fuzz testing examples*

<a id="lst:fuzz-testing"></a>

## Invariant Testing

Invariants specify properties that must always hold:

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/InvariantTest.sol";
import "forge-std/Test.sol";
import "../src/SimpleLottery.sol";

contract LotteryInvariantTest is InvariantTest, Test {
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
    function invariant_PotAccounting() public {
        assertEq(lottery.totalInvested(), lottery.pot());
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
    function invariant_WinnerState() public {
        if (lottery.winner() != address(0)) {
            assertTrue(lottery.phase() == SimpleLottery.Phase.Closed);
        }
    }
}

contract Handler {
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
```

*Invariant testing*

<a id="lst:invariant-testing"></a>

## Fork Testing

Test against live network state:

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract ForkTest is Test {
    // Fork against mainnet
    string constant MAINNET_RPC = "https://eth.llamarpc.com";
    uint256 mainnetFork;
    
    function setUp() public {
        mainnetFork = vm.createFork(MAINNET_RPC);
    }
    
    function test_WETHPriceOnFork() public {
        vm.selectFork(mainnetFork);
        
        // Query real mainnet state
        IUniswapV2Pair wethUsdc = IUniswapV2Pair(
            0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc
        );
        
        (uint112 reserve0, uint112 reserve1,) = wethUsdc.getReserves();
        
        // WETH is token0, USDC is token1
        uint256 price = (uint256(reserve1) * 1e18) / reserve0;
        
        assertGt(price, 1000 * 1e6, "WETH should be > $1000");
    }
    
    function test_MultipleForks() public {
        uint256 baseFork = vm.createFork("https://mainnet.base.org");
        uint256 arbFork = vm.createFork("https://arb1.arbitrum.io/rpc");
        
        // Test on Base
        vm.selectFork(baseFork);
        assertEq(block.chainid, 8453);
        
        // Test on Arbitrum
        vm.selectFork(arbFork);
        assertEq(block.chainid, 42161);
    }
}
```

*Fork testing against mainnet*

## Gas Profiling

### Gas Snapshots

```bash

# Create gas snapshot
forge snapshot --snap .gas-snapshot

# Compare against previous snapshot
forge snapshot --diff .gas-snapshot

# Gas report for specific functions
forge test --gas-report --match-contract SimplePonziTest
```

*Gas snapshot commands*

### Gas Optimization Testing

```solidity

// Test that optimizations actually save gas
contract GasOptimizationTest is Test {
    
    function test_CheckedVsUnchecked() public {
        uint256 gasChecked = gasleft();
        uint256 sum = 0;
        for (uint256 i = 0; i < 100; i++) {
            sum += i; // Checked arithmetic
        }
        gasChecked = gasChecked - gasleft();
        
        uint256 gasUnchecked = gasleft();
        sum = 0;
        for (uint256 i = 0; i < 100; i++) {
            unchecked { sum += i; }
        }
        gasUnchecked = gasUnchecked - gasleft();
        
        console.log("Checked gas:", gasChecked);
        console.log("Unchecked gas:", gasUnchecked);
        console.log("Savings:", gasChecked - gasUnchecked);
        
        assertLt(gasUnchecked, gasChecked, "Unchecked should use less gas");
    }
}
```

*Gas optimization verification*

## Mutation Testing

Mutation testing verifies test quality by introducing bugs:

```bash

# Install gambit for mutation testing
cargo install gambit

# Run mutation testing
gambit mutate -f src/SimplePonzi.sol
gambit test

# This creates mutants like:
# - Changing < to <=
# - Removing require statements
# - Changing constants
# Tests should catch these mutations
```

*Mutation testing workflow*

## Testing Best Practices

1. **100\% code coverage** is the minimum, not the goal
2. **Test invariants**, not just specific scenarios
3. **Use fuzzing** to discover edge cases
4. **Test on forks** with real protocol state
5. **Measure gas** and track regression
6. **Test upgrade paths** for proxy contracts
7. **Simulate attacks** in your test suite

## CI/CD Integration

```yaml

# .github/workflows/test.yml
name: test

on:
  push:
  pull_request:

jobs:
  check:
    name: Foundry project
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1

      - name: Run tests
        run: forge test -vvv

      - name: Run gas snapshot check
        run: forge snapshot --check

      - name: Run coverage
        run: forge coverage --report lcov

      - name: Upload coverage
        uses: codecov/codecov-action@v3
        with:
          files: ./lcov.info
```

*GitHub Actions CI configuration*

This concludes our comprehensive guide to building games with Ethereum smart contracts. The appendix provides quick reference for gas costs and optimization patterns.
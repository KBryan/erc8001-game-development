# Modern Solidity Patterns

## The 0.8.x Revolution

Solidity 0.8.x represents a significant evolution from the 0.4.x and 0.5.x eras of 2018. The modern compiler introduces critical safety features, improved type checking, and gas optimizations that fundamentally change how we write gaming contracts.

### Arithmetic Overflow Protection

The most impactful change in Solidity 0.8.0 is automatic overflow and underflow protection. In earlier versions, developers relied on SafeMath or OpenZeppelin libraries:

```solidity

// Solidity 0.4.x - Required SafeMath
import "@openzeppelin/contracts/math/SafeMath.sol";

contract OldGame {
    using SafeMath for uint256;

    function addRewards(uint256 a, uint256 b) public pure returns (uint256) {
        return a.add(b); // Gas overhead for library call
    }
}

// Solidity 0.8.x - Built-in protection
contract ModernGame {
    function addRewards(uint256 a, uint256 b) public pure returns (uint256) {
        return a + b; // Automatic overflow check by compiler
    }
}
```

*Overflow protection evolution*

#### The `unchecked Block`

For scenarios where overflow is acceptable or performance-critical, the `unchecked` block removes protection:

```solidity

contract GasOptimizedGame {
    function incrementRound(uint256 current) public pure returns (uint256) {
        unchecked {
            // Save ~80 gas when overflow is impossible by design
            return current + 1;
        }
    }

    function batchTransfer(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "Length mismatch");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < recipients.length;) {
            _transfer(recipients[i], amounts[i]);

            unchecked {
                // i++ cannot overflow in realistic scenarios
                totalAmount += amounts[i];
                i++;
            }
        }
    }
}
```

*Strategic use of unchecked blocks*

| lcc@{}}

**Operation** | **Checked (0.8.x)** | **Unchecked** |
|---|---|---|
| Addition | 38 gas | 18 gas |
| Subtraction | 38 gas | 18 gas |
| Multiplication | 50 gas | 30 gas |
| Increment (i++) | 38 gas | 8 gas |

## Custom Errors

Introduced in Solidity 0.8.4, custom errors provide a gas-efficient alternative to string-based require statements.

### Error Declaration and Usage

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

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
```

*Custom error implementation*

<a id="lst:custom-errors"></a>

### Gas Savings Analysis

Custom errors save significant gas, especially for reverts that are rarely triggered:

| lcc@{}}

**Revert Type** | **Deployment Gas** | **Revert Gas** |
|---|---|---|
| String message | +2000 per unique | 150 + length |
| Custom error | +400 per unique | ~100 flat |

For a gaming contract with 10 different error conditions, custom errors save approximately 16,000 gas at deployment and 50+ gas per revert.

## Immutable and Constant Variables

Proper use of immutability declarations optimizes both gas and security.

```solidity

contract GameConfiguration {
    // Constant - inlined at compile time, no storage
    uint256 public constant MAX_BET = 100 ether;
    uint256 public constant HOUSE_EDGE_BPS = 250; // 2.5%
    uint8 public constant DECIMALS = 18;

    // Immutable - set in constructor, stored in code
    address public immutable houseWallet;
    address public immutable tokenContract;
    uint256 public immutable gameStartTime;

    constructor(address _house, address _token) {
        houseWallet = _house;
        tokenContract = _token;
        gameStartTime = block.timestamp;
    }
}
```

*Immutable and constant optimization*

## Gas Optimization Patterns

### Storage Layout Optimization

Storage operations are expensive. Pack variables efficiently:

```solidity

contract InefficientStorage {
    // Uses 3 storage slots
    bool public isActive;      // Slot 0 (1 byte, 31 wasted)
    address public owner;      // Slot 1 (20 bytes)
    uint256 public balance;    // Slot 2 (32 bytes)
    uint8 public decimals;     // Slot 3 (1 byte, 31 wasted)
}

contract OptimizedStorage {
    // Uses 2 storage slots
    address public owner;      // Slot 0: 20 bytes
    uint96 public balance;     // Slot 0: 12 bytes (packed with address)
    bool public isActive;      // Slot 1: 1 byte
    uint8 public decimals;     // Slot 1: 1 byte (packed)
    uint248 public feeReserve; // Slot 1: remaining 30 bytes
}
```

*Storage packing optimization*

### Event Optimization

Events are the cheapest form of storage. Use indexed parameters for efficient filtering:

```solidity

contract EventOptimized {
    // Max 3 indexed parameters (topic0-3)
    event BetPlaced(
        indexed address player,
        indexed uint256 gameId,
        indexed uint256 roundId,
        uint256 amount,
        uint8 betType,
        uint256 timestamp
    );

    // Non-indexed data is cheaper but harder to filter
    event GameResult(
        indexed uint256 gameId,
        address[] winners,  // Dynamic, not indexed
        uint256[] payouts   // Dynamic, not indexed
    );

    function placeBet(uint256 gameId, uint8 betType) external payable {
        // ... logic ...
        emit BetPlaced(
            msg.sender,
            gameId,
            currentRound,
            msg.value,
            betType,
            block.timestamp
        );
    }
}
```

*Efficient event emission*

### Mapping vs Array

Choose appropriate data structures:

```solidity

contract DataStructureChoice {
    // Array: O(n) search, ordered iteration
    address[] public players;
    mapping(address => bool) public isPlayer;

    // Mapping: O(1) lookup, no iteration
    mapping(address => uint256) public balances;
    mapping(bytes32 => bool) public usedHashes;

    function addPlayer(address player) external {
        require(!isPlayer[player], "Already added");
        players.push(player);
        isPlayer[player] = true;
    }

    function getPlayerCount() external view returns (uint256) {
        return players.length; // O(1)
    }

    // Bad: O(n) lookup in array
    function findPlayerIndex(address player) external view returns (uint256) {
        for (uint256 i = 0; i < players.length; i++) {
            if (players[i] == player) return i;
        }
        revert("Not found");
    }
}
```

*Data structure selection patterns*

## Function Optimization

### External vs Public

```solidity

contract FunctionVisibility {
    // Public: copies calldata to memory (expensive)
    function processPublic(uint256[] memory data) public pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < data.length; i++) {
            sum += data[i];
        }
        return sum;
    }

    // External: reads directly from calldata (cheap)
    function processExternal(uint256[] calldata data) external pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < data.length; i++) {
            sum += data[i];
        }
        return sum;
    }

    // Save ~800 gas on 100-element array
}
```

*External vs public for arrays*

### View Function Caching

```solidity

contract CachingExample {
    mapping(address => uint256) public balances;

    function badBatchTransfer(
        address[] calldata recipients,
        uint256 amount
    ) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            // SLOAD in every iteration!
            require(balances[msg.sender] >= amount, "Insufficient");
            balances[msg.sender] -= amount;
            balances[recipients[i]] += amount;
        }
    }

    function goodBatchTransfer(
        address[] calldata recipients,
        uint256 amount
    ) external {
        // Cache balance
        uint256 senderBalance = balances[msg.sender];
        uint256 totalAmount = amount * recipients.length;

        require(senderBalance >= totalAmount, "Insufficient");

        unchecked {
            balances[msg.sender] = senderBalance - totalAmount;
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            balances[recipients[i]] += amount; // Single SSTORE per recipient
        }
    }
}
```

*Storage caching optimization*

## Assembly for Critical Paths

For maximum gas efficiency in hot paths, inline assembly can be employed:

```solidity

contract AssemblyOptimized {
    function sendETH(address payable recipient, uint256 amount) internal {
        assembly {
            // Call with empty calldata
            let success := call(
                gas(),      // Forward all gas
                recipient,  // To address
                amount,     // ETH amount
                0,          // in_offset
                0,          // in_size
                0,          // out_offset
                0           // out_size
            )

            if iszero(success) {
                // Revert with error selector
                mstore(0x00, 0x08c379a0) // Error(string) selector
                revert(0x00, 0x04)
            }
        }
    }

    // Save ~150 gas per transfer vs Solidity call
}
```

*Assembly optimization for ETH transfers*

## Best Practices Summary

1. **Use Solidity 0.8.19+** for latest optimizations and security fixes
2. **Employ custom errors** for all revert conditions
3. **Apply unchecked blocks** strategically in loops and safe arithmetic
4. **Pack storage variables** to minimize slot usage
5. **Use external** over public for array parameters
6. **Cache storage reads** in memory for repeated access
7. **Minimize event data** but use indexed parameters wisely
8. **Choose mappings** for O(1) lookups over arrays

With modern Solidity patterns established, Chapter 4 examines security considerations essential for gaming contracts handling real value.
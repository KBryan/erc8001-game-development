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

For operations where overflow is provably impossible, the `unchecked` block removes the compiler's protection. The rule is strict: use `unchecked` only for values whose bounds you control---like a loop counter limited by an array's length---and never for sums or products of attacker-influenced inputs.

```solidity

contract GasOptimizedGame {
    mapping(address => uint256) public balances;

    function incrementRound(uint256 current) public pure returns (uint256) {
        unchecked {
            // Safe: a round counter cannot realistically reach 2^256
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
            // Checked: amounts are caller-controlled, so the sum
            // must keep overflow protection
            totalAmount += amounts[i];
            balances[recipients[i]] += amounts[i];

            unchecked {
                // Safe: i is bounded by recipients.length
                ++i;
            }
        }

        // Checked: reverts if the caller lacks the funds
        balances[msg.sender] -= totalAmount;
    }
}
```

*Strategic use of unchecked blocks*

Note that `totalAmount += amounts[i]` stays checked: the amounts come straight from calldata, and an attacker who could overflow that sum would credit recipients with more than the sender pays. Only the counter increment---which can never exceed the array length---goes inside `unchecked`.

The savings are real but modest: a raw `ADD` opcode costs 3 gas, while the compiler's overflow check adds roughly 20--40 gas per operation in context (the comparison, conditional jump, and revert path). Exact numbers vary by compiler version and surrounding code, so measure with `forge snapshot` rather than relying on fixed figures. In hot loops, the counter increment is usually the best `unchecked` candidate.

## Custom Errors

Introduced in Solidity 0.8.4, custom errors provide a gas-efficient alternative to string-based require statements.

### Error Declaration and Usage

```solidity

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
```

*Custom error implementation*

<a id="lst:custom-errors"></a>

### Gas Savings Analysis

Custom errors save gas in two places. At deployment, each revert string must be stored in the contract's bytecode, while a custom error contributes only a four-byte selector plus a little dispatch code---the longer and more numerous your error messages, the bigger the win. At revert time, ABI-encoding a selector (plus any typed arguments) is cheaper than ABI-encoding a string. Exact figures depend on compiler version, optimizer settings, and message length, so treat any fixed numbers with suspicion and compare with `forge snapshot` on your own contract. For a gaming contract with many distinct error conditions, the deployment savings alone usually justify the switch.

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

Storage operations are expensive. Solidity packs adjacent declarations into 32-byte slots in order, so declaration order matters: a full-width `uint256` placed between two half-width values prevents them from sharing a slot.

```solidity

contract InefficientStorage {
    // Uses 3 storage slots
    uint128 public rewardRate;   // Slot 0: 16 bytes (16 wasted)
    uint256 public totalStaked;  // Slot 1: 32 bytes (full slot)
    uint128 public lastUpdate;   // Slot 2: 16 bytes (16 wasted)
}

contract OptimizedStorage {
    // Uses 2 storage slots
    uint128 public rewardRate;   // Slot 0: 16 bytes
    uint128 public lastUpdate;   // Slot 0: 16 bytes (packed)
    uint256 public totalStaked;  // Slot 1: 32 bytes (full slot)
}
```

*Storage packing optimization*

Reordering the declarations saves one slot---roughly 20,000 gas the first time that slot would have been written, and cheaper reads whenever both packed values are needed together, since one `SLOAD` fetches the pair.

### Event Optimization

Events are the cheapest form of storage. Use indexed parameters for efficient filtering:

```solidity

contract EventOptimized {
    // Max 3 indexed parameters (topic0-3)
    event BetPlaced(
        address indexed player,
        uint256 indexed gameId,
        uint256 indexed roundId,
        uint256 amount,
        uint8 betType,
        uint256 timestamp
    );

    // Non-indexed data is cheaper but harder to filter
    event GameResult(
        uint256 indexed gameId,
        address[] winners,  // Dynamic, not indexed
        uint256[] payouts   // Dynamic, not indexed
    );

    uint256 public currentRound;

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

### Calldata vs Memory Parameters

Visibility (`external` vs `public`) is about API surface: `public` functions can also be called internally, `external` ones cannot. Since Solidity 0.6.9, either visibility can take `calldata` parameters, so the gas lever is not the visibility keyword---it is the data location of reference-type parameters. A `memory` parameter forces the compiler to copy the argument out of calldata; a `calldata` parameter is read in place.

```solidity

contract DataLocation {
    // Memory: the array is copied from calldata to memory on entry (expensive)
    function processMemory(uint256[] memory data) public pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < data.length; i++) {
            sum += data[i];
        }
        return sum;
    }

    // Calldata: reads directly from calldata, no copy (cheap)
    function processCalldata(uint256[] calldata data) public pure returns (uint256) {
        uint256 sum = 0;
        for (uint256 i = 0; i < data.length; i++) {
            sum += data[i];
        }
        return sum;
    }

    // Skipping the copy saves gas proportional to the array's size
}
```

*Calldata vs memory for array parameters*

Still prefer `external` for functions that are never called internally---it documents intent and keeps the internal call graph honest---but choose `calldata` for the gas savings.

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
    error TransferFailed();

    // The plain Solidity version: clear, and already cheap
    function sendETHSolidity(address payable recipient, uint256 amount) internal {
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    // The assembly equivalent
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
                // TransferFailed() selector, left-aligned in the word
                mstore(0x00, shl(224, 0x90b8ec18))
                revert(0x00, 0x04)
            }
        }
    }
}
```

*Assembly optimization for ETH transfers*

Note the selector handling: `0x90b8ec18` is `bytes4(keccak256("TransferFailed()"))`, and revert data must carry it in the *first* four bytes of the word, so it is shifted left by 224 bits before the `revert(0x00, 0x04)`. Storing the selector right-aligned would revert with four zero bytes instead. The real savings here come from using a custom error rather than a revert string; the assembly call itself buys little over the Solidity version, and the exact difference depends on compiler version and optimizer settings---profile before committing to assembly.

## Best Practices Summary

1. **Use Solidity 0.8.26** for latest optimizations and security fixes
2. **Employ custom errors** for all revert conditions
3. **Apply unchecked blocks** strategically in loops and safe arithmetic
4. **Pack storage variables** to minimize slot usage
5. **Use calldata** over memory for reference-type parameters (and external for functions never called internally)
6. **Cache storage reads** in memory for repeated access
7. **Minimize event data** but use indexed parameters wisely
8. **Choose mappings** for O(1) lookups over arrays

With modern Solidity patterns established, Chapter 4 examines security considerations essential for gaming contracts handling real value.
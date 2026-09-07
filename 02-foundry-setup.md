# Foundry Setup

## Introduction to Foundry

Foundry is a blazing fast, portable, and modular toolkit for Ethereum application development written in Rust. It represents a fundamental shift from the JavaScript-based tooling of the Truffle era, bringing the testing language inline with the production language and dramatically improving developer experience.

### Why Foundry Over Truffle?

The transition from Truffle to Foundry is not merely incremental---it's transformational:

**Aspect** | **Truffle** | **Foundry** |
|---|---|---|
| Test Language | JavaScript | Solidity |
| Compilation Speed | 10--30 seconds | 1--3 seconds |
| Test Execution | Interpreted | Native (Rust) |
| Fuzz Testing | Limited/External | Built-in |
| Gas Snapshots | Manual | Automated |
| Cheat Codes | Limited | Extensive |
| Debugging | Basic | Advanced traces |

## Installation and Configuration

### Installing Foundry

Foundry provides a simple installation script that works across platforms:

```bash

# Install Foundry
curl -L https://foundry.paradigm.xyz | bash

# Reload shell configuration
source ~/.bashrc  # or ~/.zshrc for zsh users

# Update to latest version
foundryup
```

*Installing Foundry*

<a id="lst:install-foundry"></a>

After installation, three primary commands become available:
- `forge` --- Build and test contracts
- `cast` --- Interact with contracts
- `anvil` --- Local Ethereum node

### Project Initialization

Create a new project for your gaming contracts:

```bash

# Create new project directory
mkdir gaming-contracts && cd gaming-contracts

# Initialize Foundry project
forge init

# Project structure created:
# ├── src/           # Contract source files
# ├── test/          # Test files
# ├── script/        # Deployment scripts
# ├── lib/           # Dependencies
# └── foundry.toml   # Configuration
```

*Initializing a Foundry project*

<a id="lst:init-project"></a>

### Foundry Configuration

The `foundry.toml` file controls compilation, testing, and deployment settings. A production-ready configuration for gaming contracts:

```toml

[profile.default]
src = "src"
test = "test"
script = "script"
libs = ["lib"]
solc = "0.8.26"
optimizer = true
optimizer_runs = 200
verbosity = 3

# Gas reporting
gas_reports = ["*"]

# Fuzz testing
[fuzz]
runs = 1000

# Invariant testing
[invariant]
runs = 128
depth = 15

# Etherscan verification
[etherscan]
mainnet = { key = "${ETHERSCAN_API_KEY}" }
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
arbitrum = { key = "${ARBISCAN_API_KEY}", url = "https://api.arbiscan.io/api" }

# RPC endpoints
[rpc_endpoints]
mainnet = "${MAINNET_RPC_URL}"
base = "${BASE_RPC_URL}"
arbitrum = "${ARBITRUM_RPC_URL}"
```

*Production-ready foundry.toml configuration*

<a id="lst:foundry-config"></a>

## Forge: The Build and Test Engine

Forge is the primary development tool, handling compilation, testing, and deployment.

### Compilation

Compile contracts with detailed output:

```bash

# Standard compilation
forge build

# Force recompilation
forge build --force

# Build specific files
forge build --contracts src/MyGame.sol

# Generate compilation database (for IDE support)
forge build --build-info
```

*Forge compilation commands*

### Testing Fundamentals

Foundry tests are written in Solidity, eliminating language context switching:

```solidity

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
```

*Basic Foundry test structure*

<a id="lst:basic-test"></a>

Run tests with various options:

```bash

# Run all tests
forge test

# Run with verbose output (-v, -vv, -vvv)
forge test -vvv

# Run specific test
forge test --match-test test_Invest

# Run tests in specific file
forge test --match-path test/SimplePonzi.t.sol

# Run with gas reporting
forge test --gas-report
```

*Test execution commands*

### Advanced Testing: Fuzzing

Foundry's built-in fuzzing generates random inputs to test edge cases:

```solidity

function testFuzz_Invest(uint256 amount) public {
    // Bound the amount to reasonable range
    amount = bound(amount, 0.001 ether, 100 ether);
    vm.deal(alice, amount);

    vm.prank(alice);
    ponzi.invest{value: amount}();

    assertEq(ponzi.highestBid(), amount);
    assertEq(ponzi.currentWinner(), alice);
}
```

*Fuzz testing example*

<a id="lst:fuzz-test"></a>

### Cheat Codes

Cheat codes enable powerful testing capabilities:

**Cheat Code** | **Description** |
|---|---|
| `vm.prank(address)` | Execute next call as specified address |
| `vm.startPrank(address)` | Start executing as address until stopped |
| `vm.deal(address, uint256)` | Set ETH balance of address |
| `vm.warp(uint256)` | Set block timestamp |
| `vm.roll(uint256)` | Set block number |
| `vm.expectRevert()` | Expect next call to revert |
| `vm.mockCall(...)` | Mock external contract calls |
| `vm.etch(address, bytes)` | Set bytecode at address |

## Anvil: Local Ethereum Node

Anvil provides a local blockchain for development and testing with instant mining and rich inspection capabilities.

### Starting Anvil

```bash

# Start with default settings (10 pre-funded accounts)
anvil

# Fork mainnet for realistic testing
anvil --fork-url $MAINNET_RPC_URL

# Custom configuration
anvil --port 8545 --block-time 12 --accounts 20

# Fork at specific block
anvil --fork-url $MAINNET_RPC_URL --fork-block-number 18000000
```

*Anvil startup options*

### Anvil Features for Game Testing

```solidity

// In your test file, fork from Anvil
function testWithFork() public {
    // Create and select fork
    uint256 forkId = vm.createFork("http://localhost:8545");
    vm.selectFork(forkId);

    // Now interacting with forked state
    assertEq(vm.activeFork(), forkId);
}
```

*Fork testing with Anvil*

## Cast: Command-Line Interaction

Cast enables ad-hoc contract interaction without writing scripts.

### Reading Chain State

```bash

# Get ETH balance
cast balance 0x742d35Cc6634C0532925a3b844Bc9e7595f3e6e5

# Call a view function
cast call CONTRACT_ADDRESS "currentWinner()(address)"

# Get storage slot
cast storage CONTRACT_ADDRESS 0

# Decode transaction data
cast decode-tx 0x1234...
```

*Cast state reading commands*

### Sending Transactions

```bash

# Send ETH
cast send --private-key $PK TO_ADDRESS --value 0.1ether

# Call a function that modifies state
cast send --private-key $PK CONTRACT_ADDRESS \
    "invest()" --value 0.1ether

# Estimate gas
cast estimate CONTRACT_ADDRESS "invest()" --value 0.1ether
```

*Cast transaction commands*

## Dependency Management

Foundry uses git submodules for dependency management:

```bash

# Install OpenZeppelin contracts
forge install OpenZeppelin/openzeppelin-contracts

# Install specific version
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0

# Update dependencies
forge update

# Remove dependency
forge remove openzeppelin-contracts
```

*Dependency management with Forge*

> **Version note**: This book pins OpenZeppelin v5. If you maintain an older v4 codebase, note the reverse mapping: v4 kept `ReentrancyGuard` and `Pausable` under `contracts/security/` (v5 moved them to `contracts/utils/`), and v4's `Ownable` constructor took no arguments (v5 requires an `initialOwner`). Readers on v4 must adjust imports and constructors accordingly.

Remappings in `foundry.toml` map imports to installed dependencies:

```toml

[profile.default]
remappings = [
    "@openzeppelin/=lib/openzeppelin-contracts/",
    "forge-std/=lib/forge-std/src/",
    "@pyth/=lib/pyth-sdk-solidity/"
]
```

*Import remappings configuration*

## Best Practices

1. **Always use specific Solidity versions**: Pin `pragma solidity ^0.8.26;` for reproducibility.
2. **Enable optimizer**: Set `optimizer = true` with appropriate `optimizer_runs` for your use case.
3. **Test thoroughly**: Aim for high coverage with unit, fuzz, and integration tests.
4. **Use gas snapshots**: Track gas changes with `forge snapshot` and `forge snapshot --diff`.
5. **Version control dependencies**: Pin dependency versions and review updates carefully.

With Foundry configured, we proceed to Chapter 3 for a deep dive into modern Solidity patterns optimized for gaming contracts.
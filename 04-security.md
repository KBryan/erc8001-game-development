# Security

## Introduction

Gaming contracts are prime targets for attackers due to their direct handling of value and predictable execution patterns. Unlike DeFi protocols with extensive auditing, many gaming contracts receive less scrutiny while managing significant player funds. This chapter addresses the critical security patterns essential for production gaming contracts.

## Reentrancy Attacks

### The Classic Vulnerability

The DAO hack of 2016, exploiting a reentrancy vulnerability, resulted in a 60-million-dollar loss and the Ethereum hard fork. Gaming contracts are particularly susceptible due to their payout mechanisms.

```solidity

// VULNERABLE - DO NOT USE
contract VulnerablePayout {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance");

        // EXTERNAL CALL BEFORE STATE UPDATE!
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        balances[msg.sender] = 0; // Too late!
    }
}
```

*Vulnerable contract with reentrancy*

<a id="lst:reentrancy-vuln"></a>

### Attack Mechanism

The attacker deploys a malicious contract that calls back into the victim during the external call:

```solidity

contract Attacker {
    VulnerablePayout public target;
    uint256 public attackCount;

    constructor(address _target) {
        target = VulnerablePayout(_target);
    }

    // Initial attack entry point
    function attack() external payable {
        target.deposit{value: msg.value}();
        target.withdraw();
    }

    // Called when receiving ETH from vulnerable contract
    receive() external payable {
        if (attackCount < 10) {
            attackCount++;
            // Re-enter before balance is updated
            target.withdraw();
        }
    }
}
```

*Reentrancy attack contract*

### Checks-Effects-Interactions Pattern

The fundamental defense: update state before external calls.

```solidity

contract SecurePayout {
    mapping(address => uint256) public balances;

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance");

        // CHECKS: Validate conditions
        // EFFECTS: Update state FIRST
        balances[msg.sender] = 0;

        // INTERACTIONS: External call LAST
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }
}
```

*Checks-Effects-Interactions implementation*

<a id="lst:cei-pattern"></a>

### Reentrancy Guards

For complex contracts with multiple external calls, use OpenZeppelin's ReentrancyGuard:

```solidity

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ProtectedGame is ReentrancyGuard {
    mapping(address => uint256) public balances;

    function withdraw() external nonReentrant {
        uint256 amount = balances[msg.sender];
        require(amount > 0, "No balance");

        balances[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    // Can also protect complex operations
    function processBetAndPayout(address winner) external nonReentrant {
        // Multiple external calls are now safe
        _distributeToWinner(winner);
        _updateJackpot();
        _notifyOracle();
    }
}
```

*ReentrancyGuard implementation*

### Read-Only Reentrancy

A subtle variant: the contract itself may be safe against direct reentrancy, yet a `view` function can expose inconsistent state during an external call. The victim is not the vault---it is any *third-party integrator* that reads the view function while the vault's ETH send is in flight.

```solidity

contract GuardedVault {
    uint256 public totalDeposits;
    mapping(address => uint256) public deposits;

    function deposit() external payable {
        totalDeposits += msg.value;
        deposits[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = deposits[msg.sender];
        require(amount > 0, "No balance");

        // Effects before interaction: withdraw() itself
        // cannot be re-entered profitably
        deposits[msg.sender] = 0;

        // ...but totalDeposits is only reduced AFTER the send
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        totalDeposits -= amount;
    }

    // Correct in isolation -- but stale while withdraw()'s
    // external call is in flight: the ETH has already left,
    // yet totalDeposits still counts it
    function getShare(address user) external view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return (deposits[user] * 1e18) / totalDeposits;
    }
}

// Third-party protocol that trusts the vault's view function
contract LendingIntegrator {
    GuardedVault public vault;

    constructor(address _vault) {
        vault = GuardedVault(_vault);
    }

    function collateralValue(address user) public view returns (uint256) {
        // If invoked from an attacker's receive() during
        // vault.withdraw(), totalDeposits is inflated and every
        // other depositor's share reads too low -- mispriced collateral
        return vault.getShare(user);
    }
}
```

*Read-only reentrancy vulnerability*

The attacker calls `withdraw()` and, from the `receive()` callback, triggers the integrator (for example, a liquidation that prices collateral via `collateralValue`). The vault's own state machine is never violated---only observed at its inconsistent midpoint. Defenses: update *all* related state before the external call, or expose a reentrancy-lock check (`nonReentrantView`) that integrators can consult.

## Integer Overflow and Underflow

### Historical Context

Solidity 0.8.x provides automatic overflow protection. However, understanding these vulnerabilities remains essential for:
- Auditing legacy contracts
- Using unchecked blocks safely
- Cross-chain interactions with older VMs

### Modern Protection

```solidity

// Solidity 0.8.x - Automatic protection
contract ModernOverflow {
    function subtract(uint256 a, uint256 b) public pure returns (uint256) {
        return a - b; // Automatically reverts if b > a
    }
}

// Using unchecked for gas optimization
contract GasOptimized {
    function increment(uint256 counter) public pure returns (uint256) {
        unchecked {
            return counter + 1; // Only use when overflow is impossible
        }
    }
}
```

*Modern overflow handling*

## Oracle Manipulation

### Price Oracle Risks

Gaming contracts integrating DeFi protocols or using price feeds face oracle manipulation risks.

```solidity

// VULNERABLE - Single oracle source
contract VulnerablePriceGame {
    address public priceFeed;

    function calculatePayout() public view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        return uint256(price) * betAmount / 1e8;
    }
}

// SECURE - Multiple validation checks
contract SecurePriceGame {
    AggregatorV3Interface public priceFeed;
    uint256 public lastPrice;
    uint256 public lastUpdateTime;
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint256 public constant MAX_PRICE_DEVIATION = 10; // 10%

    function getValidatedPrice() public view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Check for stale data
        require(updatedAt > 0, "Round not complete");
        require(block.timestamp - updatedAt < MAX_PRICE_AGE, "Stale price");
        require(answeredInRound >= roundId, "Stale round");

        uint256 currentPrice = uint256(price);
        require(currentPrice > 0, "Invalid price");

        // Check deviation from last known good price
        if (lastPrice > 0) {
            uint256 deviation = currentPrice > lastPrice 
                ? (currentPrice - lastPrice) * 100 / lastPrice
                : (lastPrice - currentPrice) * 100 / lastPrice;
            require(deviation < MAX_PRICE_DEVIATION, "Price deviation too high");
        }

        return currentPrice;
    }
}
```

*Oracle manipulation protection*

### TWAP and Multiple Sources

For high-value gaming contracts, use Time-Weighted Average Prices (TWAP) or multiple oracle sources:

```solidity

contract MultiOracleGame {
    AggregatorV3Interface public chainlinkOracle;
    IUniswapV3Pool public uniswapPool;

    function getRobustPrice() external view returns (uint256) {
        uint256 chainlinkPrice = _getChainlinkPrice();
        uint256 twapPrice = _getTWAPPrice();

        // Ensure oracles agree within tolerance
        uint256 diff = chainlinkPrice > twapPrice 
            ? chainlinkPrice - twapPrice 
            : twapPrice - chainlinkPrice;

        require(diff * 100 / chainlinkPrice < 5, "Oracle divergence");

        // Return more conservative price
        return chainlinkPrice < twapPrice ? chainlinkPrice : twapPrice;
    }
}
```

*Multi-source oracle validation*

## MEV and Front-running

### Understanding MEV

Maximal Extractable Value (MEV) refers to profit miners/validators can extract by reordering, including, or excluding transactions. Gaming contracts are particularly vulnerable.

### Front-running Attacks

```solidity

// VULNERABLE - Predictable outcome
contract VulnerableLottery {
    uint256 public winningNumber;
    uint256 public jackpot;
    bool public revealed;

    function enter() external payable {
        jackpot += msg.value;
    }

    function reveal(uint256 secret) external {
        require(!revealed, "Already revealed");
        winningNumber = uint256(keccak256(abi.encodePacked(secret)));
        revealed = true;
    }

    function claimPrize(uint256 guess) external {
        require(revealed, "Not revealed");
        if (guess == winningNumber) {
            payable(msg.sender).transfer(jackpot);
        }
    }
}
```

*Vulnerable to front-running*

### Commit-Reveal Pattern

```solidity

// SECURE - Commit-reveal scheme
contract SecureLottery {
    mapping(address => bytes32) public commitments;
    mapping(address => uint256) public revealedNumbers;

    uint256 public constant COMMIT_DURATION_BLOCKS = 100; // ~20 minutes at 12s blocks
    uint256 public immutable commitStartBlock;

    constructor() {
        commitStartBlock = block.number;
    }

    function commit(bytes32 hash) external {
        require(
            block.number < commitStartBlock + COMMIT_DURATION_BLOCKS,
            "Commit phase over"
        );
        require(commitments[msg.sender] == bytes32(0), "Already committed");

        commitments[msg.sender] = hash;
    }

    function reveal(uint256 number, bytes32 salt) external {
        require(
            block.number >= commitStartBlock + COMMIT_DURATION_BLOCKS,
            "Still in commit phase"
        );

        bytes32 c = commitments[msg.sender];
        require(c != bytes32(0), "No commitment");
        require(
            keccak256(abi.encodePacked(number, salt, msg.sender)) == c,
            "Invalid reveal"
        );

        revealedNumbers[msg.sender] = number;
    }

    function claim() external {
        // Calculate winner from all revealed numbers...
    }
}
```

*Commit-reveal protection*

## Access Control

Privileged operations---pausing the game, changing parameters, emergency withdrawals---must be restricted to authorized accounts. OpenZeppelin's `AccessControl` assigns fine-grained roles rather than concentrating every power in a single owner.

```solidity

import "@openzeppelin/contracts/access/AccessControl.sol";

contract AccessControlledGame is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    bool public paused;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        paused = false;
    }

    function emergencyWithdraw() external onlyRole(DEFAULT_ADMIN_ROLE) {
        payable(msg.sender).transfer(address(this).balance);
    }
}
```

*Access control implementation*

## Randomness Security

### Insecure Randomness Sources

```solidity

// INSECURE - Do not use for value
contract InsecureRandom {
    function badRandom() public view returns (uint256) {
        // All observable or influenceable by the block proposer.
        // Post-Merge, prevrandao is not miner-mined difficulty: the
        // proposer can still bias it a limited amount, so it is
        // unsuitable for high-value randomness.
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender
        )));
    }
}
```

*Insecure randomness sources*

## Security Checklist

**No.** | **Check** | **Tool/Method** |
|---|---|---|
| 1 | Reentrancy protection (CEI + guards) | Slither, manual review |
| 2 | Integer overflow/underflow handling | Slither, Certora |
| 3 | Access control validation | OpenZeppelin Defender |
| 4 | Oracle manipulation resistance | TWAP, multiple sources |
| 5 | Front-running protection | Commit-reveal, batch auctions |
| 6 | Secure randomness | Chainlink VRF, Entropy |
| 7 | Gas optimization | Foundry gas snapshots |
| 8 | Event emission coverage | Manual review |
| 9 | Edge case handling | Fuzzing tests |
| 10 | Emergency mechanisms | Circuit breakers, multisig |

With security foundations established, Chapter 5 examines classic gaming patterns including Ponzi and Pyramid schemes---from an educational security perspective.
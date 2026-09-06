# Deployment

## Introduction

Deploying gaming contracts to production requires careful planning across multiple dimensions: network selection, verification, monitoring, and upgrade paths. This chapter covers deployment strategies for modern Layer-2 networks.

## Network Selection

### Ethereum Mainnet vs Layer-2

| lccc@{}}

**Factor** | **Ethereum** | **Base** | **Arbitrum** |
|---|---|---|---|
| Gas Cost (simple tx) | \$5--50 | \$0.01--0.10 | \$0.10--0.50 |
| Block Time | 12 sec | 2 sec | 0.25 sec |
| Finality | 15 min | 15 min | 7 days |
| TVL Security | Highest | High | High |
| Ecosystem Maturity | Maximum | Growing | Mature |
| Bridge Risk | N/A | Canonical | Canonical |

### Why Layer-2 for Gaming

Gaming contracts require frequent, low-value transactions:
- Buying lottery tickets
- Placing bets
- Claiming rewards
- In-game purchases

With Ethereum mainnet gas costs at 20--100 gwei, a simple bet costing 50,000 gas would cost \$2--10. On Base, the same transaction costs under \$0.01.

## Foundry Deployment Scripts

### Basic Deployment Script

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "../src/SimpleLottery.sol";

contract DeploySimpleLottery is Script {
    function run() external returns (SimpleLottery) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        SimpleLottery lottery = new SimpleLottery(
            0.01 ether,    // ticket price
            10,             // min entries
            100,            // commit duration (blocks)
            100             // reveal duration (blocks)
        );
        
        vm.stopBroadcast();
        
        return lottery;
    }
}
```

*Basic Foundry deployment script*

<a id="lst:deploy-script"></a>

### Multi-Network Deployment

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "../src/GameToken.sol";
import "../src/GameStaking.sol";

contract DeployGameFi is Script {
    struct NetworkConfig {
        address admin;
        uint256 maxSupply;
        uint256 dailyMintLimit;
    }
    
    mapping(uint256 => NetworkConfig) public configs;
    
    constructor() {
        // Admin address comes from the environment so no key is hardcoded
        address admin = vm.envOr("GAMEFI_ADMIN", address(0));

        // Base Mainnet
        configs[8453] = NetworkConfig({
            admin: admin,
            maxSupply: 1_000_000_000 ether,
            dailyMintLimit: 100_000 ether
        });

        // Arbitrum One
        configs[42161] = NetworkConfig({
            admin: admin,
            maxSupply: 1_000_000_000 ether,
            dailyMintLimit: 100_000 ether
        });
    }
    
    function run() external {
        uint256 chainId = block.chainid;
        NetworkConfig memory cfg = configs[chainId];
        
        require(cfg.admin != address(0), "Network not configured");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy token
        GameToken token = new GameToken(
            "GameToken",
            "GAME",
            cfg.maxSupply,
            cfg.dailyMintLimit
        );
        
        // Deploy staking
        GameStaking staking = new GameStaking(
            address(token),
            address(token)
        );
        
        // Setup roles
        token.grantRole(token.MINTER_ROLE(), cfg.admin);
        token.grantRole(token.GAME_CONTRACT_ROLE(), address(staking));
        
        vm.stopBroadcast();
        
        // Log addresses for verification
        console.log("GameToken deployed at:", address(token));
        console.log("GameStaking deployed at:", address(staking));
    }
}
```

*Multi-network deployment script*

## Base Chain Deployment

### Base Mainnet Configuration

```toml

# foundry.toml - Base configuration
[rpc_endpoints]
base = "${BASE_RPC_URL}"
base_goerli = "https://goerli.base.org"

[etherscan]
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
base_goerli = { key = "${BASESCAN_API_KEY}", url = "https://api-goerli.basescan.org/api" }
```

*Base network configuration*

### Deploying to Base

```bash

# Set environment variables
export BASE_RPC_URL="https://mainnet.base.org"
export BASESCAN_API_KEY="your-api-key"
export PRIVATE_KEY="0x..."

# Deploy to Base
cd /root/ethereum-games-book
forge script script/DeployGameFi.s.sol:DeployGameFi \
    --rpc-url base \
    --broadcast \
    --verify \
    -vvvv

# Deploy with specific gas settings
forge script script/DeployGameFi.s.sol \
    --rpc-url base \
    --broadcast \
    --verify \
    --gas-price 100000000 \
    --priority-gas-price 100000000
```

*Base deployment commands*

## Arbitrum Deployment

### Arbitrum Considerations

Arbitrum uses a different gas model than Ethereum:
- L2 gas: Computation on Arbitrum
- L1 calldata: Data posted to Ethereum

```toml

# foundry.toml - Arbitrum configuration
[rpc_endpoints]
arbitrum = "${ARBITRUM_RPC_URL}"
arbitrum_sepolia = "https://sepolia-rollup.arbitrum.io/rpc"

[etherscan]
arbitrum = { key = "${ARBISCAN_API_KEY}", url = "https://api.arbiscan.io/api" }
arbitrum_sepolia = { key = "${ARBISCAN_API_KEY}", url = "https://api-sepolia.arbiscan.io/api" }
```

*Arbitrum configuration*

### Gas Optimization for Arbitrum

```solidity

// Optimize for Arbitrum's L1 calldata costs
contract ArbitrumOptimized {
    
    // BAD: Many small writes
    function badUpdate(uint256[] calldata values) external {
        for (uint256 i = 0; i < values.length; i++) {
            data[i] = values[i]; // Multiple SSTOREs
        }
    }
    
    // GOOD: Batch operations
    struct BatchData {
        uint256[] indices;
        uint256[] values;
    }
    
    function batchUpdate(BatchData calldata batch) external {
        require(batch.indices.length == batch.values.length);
        // Single transaction, less calldata overhead
    }
    
    // Use events instead of storage where possible
    event DataRecorded(bytes32 indexed key, bytes data);
    
    function recordOffchain(bytes32 key, bytes calldata data) external {
        // Emit event - stored in calldata, not L2 storage
        emit DataRecorded(key, data);
    }
}
```

*Arbitrum gas optimization*

## Contract Verification

### Automatic Verification

Foundry supports automatic verification during deployment:

```bash

# Verify on deployment
forge script script/Deploy.s.sol \
    --rpc-url base \
    --broadcast \
    --verify \
    --verifier etherscan

# Verify already deployed contract
forge verify-contract \
    --chain-id 8453 \
    --num-of-optimizations 200 \
    --watch \
    --constructor-args $(cast abi-encode "constructor(uint256,uint256)" 100 200) \
    DEPLOYED_CONTRACT_ADDRESS \
    src/MyContract.sol:MyContract
```

*Contract verification commands*

### Sourcify Verification

Sourcify provides open-source verification:

```bash

# Verify on Sourcify
forge script script/Deploy.s.sol \
    --rpc-url base \
    --broadcast \
    --verify \
    --verifier sourcify
```

*Sourcify verification*

## Post-Deployment Tasks

### Ownership Transfer

```solidity

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract PostDeployment is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address newOwner = vm.envAddress("NEW_OWNER");
        address token = vm.envAddress("TOKEN_ADDRESS");
        
        vm.startBroadcast(deployerKey);
        
        // Transfer ownership
        Ownable(token).transferOwnership(newOwner);
        
        // Grant admin role.
        // CAUTION: DEFAULT_ADMIN_ROLE is bytes32(0), NOT keccak256 of its
        // name -- hashing the name grants a meaningless role while the
        // deployer silently keeps real admin.
        bytes32 adminRole = AccessControl(token).DEFAULT_ADMIN_ROLE();
        AccessControl(token).grantRole(adminRole, newOwner);

        // Renounce deployer roles
        AccessControl(token).renounceRole(adminRole, vm.addr(deployerKey));
        
        vm.stopBroadcast();
    }
}
```

*Post-deployment ownership transfer*

Note the way the admin role is read from the contract rather than hashed by name. OpenZeppelin's `DEFAULT_ADMIN_ROLE` is `bytes32(0)`, not `keccak256("DEFAULT_ADMIN_ROLE")` -- a script that hashes the name grants and renounces a role nobody checks, leaving the deployer silently in control while the handover appears to succeed.

### Emergency Procedures

```solidity

contract EmergencyProcedures {
    
    // Pause functionality
    function emergencyPause(address target) external onlyOwner {
        Pausable(target).pause();
    }
    
    // Withdraw stuck funds
    function emergencyWithdraw(address token, uint256 amount) 
        external 
        onlyOwner 
    {
        IERC20(token).transfer(owner(), amount);
    }
    
    // Upgrade proxy (if using upgradeable pattern)
    function upgradeImplementation(
        address proxy,
        address newImplementation
    ) external onlyOwner {
        TransparentUpgradeableProxy(payable(proxy)).upgradeTo(newImplementation);
    }
}
```

*Emergency procedures*

## Monitoring Setup

### Event Monitoring

```typescript

// monitor.ts - Basic event monitoring
import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, provider);

// Monitor for large bets
contract.on("BetPlaced", (commitHash, player, amount, target, payout) => {
    if (ethers.formatEther(amount) > "10") {
        console.log(`Large bet detected: ${player} bet ${amount}`);
        // Alert logic here
    }
});

// Monitor for unusual patterns
const recentBets = new Map();

contract.on("BetPlaced", (_, player) => {
    const count = recentBets.get(player) || 0;
    recentBets.set(player, count + 1);
    
    if (count + 1 > 100) {
        console.log(`Suspicious activity: ${player} placed ${count + 1} bets`);
    }
});
```

*Event monitoring script*

## Deployment Checklist

| p{1cm}p{6cm}p{7cm}@{}}

**Step** | **Task** | **Verification** |
|---|---|---|
| 1 | Run full test suite | `forge test --fork-url mainnet` |
| 2 | Verify gas snapshots | `forge snapshot --diff` |
| 3 | Deploy to testnet | Verify on Base Goerli/Arb Sepolia |
| 4 | Verify contract source | Etherscan/Basescan verification |
| 5 | Test verified contract | Interact via block explorer |
| 6 | Deploy to mainnet | Use hardware wallet for deployer |
| 7 | Transfer ownership | To multisig or governance |
| 8 | Set up monitoring | Events, balance, anomalies |
| 9 | Create emergency plan | Pause mechanisms, contact info |
| 10 | Document deployment | Contract addresses, ABIs, notes |

With deployment complete, Chapter 10 covers comprehensive testing strategies.
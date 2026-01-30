# Chapter 11: ERC-8001 Multiplayer Coordination

This chapter covers the **ERC-8001 Agent Coordination Standard** and its integration into GameFi contracts for secure, cryptographically-verified multiplayer interactions.

## Table of Contents

1. [What is ERC-8001?](#what-is-erc-8001)
2. [Core Concepts](#core-concepts)
3. [EIP-712 Signed Intents](#eip-712-signed-intents)
4. [Coordination Lifecycle](#coordination-lifecycle)
5. [Game-Specific Implementations](#game-specific-implementations)
   - [GameCoordination](#gamecoordination)
   - [MultiplayerGameLobby](#multiplayergamelobby)
   - [TeamStaking](#teamstaking)
   - [ERC8001LootBox](#erc8001lootbox)
6. [Security Benefits](#security-benefits)
7. [Integration Guide](#integration-guide)
8. [Best Practices](#best-practices)

---

## What is ERC-8001?

**ERC-8001** is an Ethereum standard for **multi-agent coordination** that enables multiple parties to agree on shared actions through cryptographically signed intents. Think of it as a "smart contract handshake" where all parties must digitally sign before any action executes.

### Why Games Need Coordination

Traditional blockchain games suffer from **trust problems** in multiplayer scenarios:

| Problem | Without ERC-8001 | With ERC-8001 |
|---------|------------------|---------------|
| Tournament Entry | Players pay, organizer might not start | All sign intent first, then atomically execute |
| Team Rewards | One member distributes unequally | Pre-signed agreement on equal split |
| Loot Distribution | First grabber wins | Coordinated fair distribution |
| Matchmaking | No-shows waste gas | Commitment before joining |

### Key Innovation: Conditional Execution

ERC-8001 enables **"if everyone agrees, then execute"** logic on-chain:

```solidity
// Only executes if ALL participants signed
if (allParticipantsAccepted(intentHash)) {
    executeCoordination(intentHash, payload, data);
}
```

---

## Core Concepts

### 1. AgentIntent (The Proposal)

An `AgentIntent` is the initial proposal created by a coordinator (agent). It defines:

```solidity
struct AgentIntent {
    bytes32 payloadHash;        // Hash of what will be executed
    uint64 expiry;              // Deadline for acceptance
    uint64 nonce;               // Replay protection
    address agentId;            // Coordinator's address
    bytes32 coordinationType;   // Type (TOURNAMENT, BATTLE, etc.)
    uint256 coordinationValue;  // Entry fee, stake amount, etc.
    address[] participants;     // All parties involved (sorted)
}
```

**Real-world analogy**: Like a contract proposal sent to all parties. Everyone can see the terms before signing.

### 2. AcceptanceAttestation (The Agreement)

Each participant creates an `AcceptanceAttestation` to agree:

```solidity
struct AcceptanceAttestation {
    bytes32 intentHash;         // Which proposal being accepted
    address participant;        // Who is accepting
    uint64 nonce;               // Their replay protection
    uint64 expiry;              // When their acceptance expires
    bytes32 conditionsHash;     // Any additional conditions
    bytes signature;            // EIP-712 signature
}
```

**Real-world analogy**: Each party signing the contract, with their own copy kept.

### 3. CoordinationPayload (The Execution)

The `CoordinationPayload` contains the actual data to execute:

```solidity
struct CoordinationPayload {
    uint32 version;             // Payload format version
    bytes32 coordinationType;   // Must match intent
    bytes coordinationData;     // Encoded execution data
    bytes32 conditionsHash;     // Execution conditions
    uint64 timestamp;           // Creation time
    bytes metadata;             // Additional info
}
```

**Real-world analogy**: The specific instructions on what to do once all signatures are collected.

### 4. Status Tracking

```solidity
enum Status {
    None,       // Not created
    Proposed,   // Awaiting acceptances
    Ready,      // All accepted, ready to execute
    Executed,   // Completed
    Cancelled,  // Cancelled by proposer
    Expired     // Past deadline
}
```

---

## EIP-712 Signed Intents

ERC-8001 uses **EIP-712** typed data signing for security and clarity. Instead of signing opaque hashes, participants sign human-readable structures.

### Type Hashes

The contract defines type hashes for each structure:

```solidity
bytes32 public constant AGENT_INTENT_TYPEHASH = keccak256(
    "AgentIntent(bytes32 payloadHash,uint64 expiry,uint64 nonce,address agentId,bytes32 coordinationType,uint256 coordinationValue,address[] participants)"
);

bytes32 public constant ACCEPTANCE_TYPEHASH = keccak256(
    "AcceptanceAttestation(bytes32 intentHash,address participant,uint64 nonce,uint64 expiry,bytes32 conditionsHash)"
);
```

### Domain Separator

Each contract has a unique domain separator for cross-contract replay protection:

```solidity
DOMAIN_SEPARATOR = keccak256(abi.encode(
    DOMAIN_TYPEHASH,
    keccak256(bytes("ERC-8001-Core")),
    keccak256(bytes("1")),
    block.chainid,
    address(this)
));
```

### Wallet Display Example

When signing an intent, wallets show:

```
Sign Typed Data

Domain: ERC-8001-Core
Version: 1
Chain: Ethereum Mainnet
Contract: 0x1234...

Message:
- payloadHash: 0xabc123...
- expiry: Jan 30, 2025 15:00 UTC
- agentId: 0xYourAddress...
- coordinationType: TOURNAMENT
- coordinationValue: 0.1 ETH
- participants: [0xAlice..., 0xBob..., 0xYou...]
```

---

## Coordination Lifecycle

### Phase 1: Proposal (Proposed)

**Who**: Coordinator (agent)  
**What**: Create and sign intent

```solidity
function proposeCoordination(
    AgentIntent calldata intent,
    bytes calldata signature,
    CoordinationPayload calldata payload
) external returns (bytes32 intentHash);
```

**Process**:
1. Agent defines coordination terms
2. Computes `payloadHash` = keccak256(payload)
3. Signs intent with EIP-712
4. Submits to contract
5. Contract validates:
   - Intent not expired
   - Participants sorted and unique
   - Agent is in participant list
   - Payload hash matches
   - Nonce is strictly increasing

**Gas cost**: ~80,000 gas (one-time setup)

### Phase 2: Acceptance (Proposed → Ready)

**Who**: Each participant  
**What**: Sign and submit acceptance

```solidity
function acceptCoordination(
    bytes32 intentHash,
    AcceptanceAttestation calldata attestation
) external returns (bool allAccepted);
```

**Process**:
1. Participant reviews intent terms
2. Creates acceptance attestation
3. Signs with EIP-712
4. Submits to contract
5. Contract validates:
   - Intent exists and is Proposed
   - Not expired
   - Caller is valid participant
   - Not already accepted
   - Signature valid
   - Attestation expiry > now

**When All Accept**:
```solidity
if (st.acceptedCount == st.participants.length) {
    st.status = Status.Ready;
    emit CoordinationReady(intentHash, count, minAcceptanceExpiry);
}
```

**Gas cost**: ~35,000 gas per acceptance

### Phase 3: Execution (Ready → Executed)

**Who**: Any address (can be different from participants)  
**What**: Trigger actual execution

```solidity
function executeCoordination(
    bytes32 intentHash,
    CoordinationPayload calldata payload,
    bytes calldata executionData
) external returns (bool success, bytes memory result);
```

**Process**:
1. Caller provides matching payload
2. Contract verifies:
   - Status is Ready
   - Intent not expired
   - All acceptances still valid
   - Payload hash matches stored hash
3. Marks as Executed (prevents reentrancy)
4. Calls `_executeInternal()` hook
5. Emits execution result

**Gas cost**: Variable based on implementation

### Phase 4: Cleanup

**Cancellation** (Proposer only before expiry):
```solidity
function cancelCoordination(bytes32 intentHash, string calldata reason) external;
```

**Expiration** (Anyone can mark as Expired after deadline):
- Automatically detected during other operations
- Gas refund for cleanup operations

---

## Game-Specific Implementations

### GameCoordination

Extends base `AgentCoordination` with game primitives:

```solidity
contract GameCoordination is AgentCoordination {
    // Coordination types for games
    bytes32 public constant COORDINATION_TOURNAMENT = keccak256("TOURNAMENT");
    bytes32 public constant COORDINATION_TEAM_STAKE = keccak256("TEAM_STAKE");
    bytes32 public constant COORDINATION_BATTLE = keccak256("BATTLE");
    bytes32 public constant COORDINATION_LOOT_SHARE = keccak256("LOOT_SHARE");
    bytes32 public constant COORDINATION_LOBBY = keccak256("LOBBY");
}
```

**Features**:
- Tournament management with entry fees
- Battle coordination for PvP
- Loot sharing agreements
- Team staking pools
- Configurable coordination types

### MultiplayerGameLobby

Simplified lobby system using ERC-8001:

```solidity
// Create a lobby (proposes coordination)
function createLobby(
    uint256 maxPlayers,
    uint256 entryFee,
    GameMode mode,
    uint256 duration
) external returns (bytes32 lobbyId);

// Join lobby (accepts coordination)
function joinLobby(bytes32 lobbyId, AcceptanceAttestation calldata attestation) 
    external payable;

// Start game (executes when all ready)
function startGame(bytes32 lobbyId) external;
```

**Use case**: Skill-based matchmaking where players commit to playing before the game starts.

### TeamStaking

Team-based staking with shared rewards:

```solidity
// Create team stake
function createTeamStake(
    address[] calldata teamMembers,
    uint256 minContribution,
    uint256 targetAmount
) external returns (bytes32 stakeId);

// Contribute to stake
function contribute(bytes32 stakeId, AcceptanceAttestation calldata attestation) 
    external payable;

// Claim rewards when conditions met
function claimRewards(bytes32 stakeId) external;
```

**Use case**: Guild staking pools where all members must agree on reward distribution.

### ERC8001LootBox

Multi-party loot distribution using Pyth Entropy:

```solidity
// Open loot box with coordination
function openLootBox(
    bytes32 intentHash,
    CoordinationPayload calldata payload,
    bytes calldata executionData,
    bytes32 userRandomNumber
) external returns (bool success, uint256[] memory itemIds);

// Items distributed based on verifiable randomness
// All parties agree on distribution before opening
```

**Use case**: Dungeon raids where all party members agree on loot distribution before opening.

---

## Security Benefits

### 1. Replay Protection

```solidity
// Nonce tracking prevents replay attacks
mapping(address => uint64) public agentNonces;

require(intent.nonce > agentNonces[intent.agentId], "Nonce not strictly increasing");
agentNonces[intent.agentId] = intent.nonce;
```

**Benefit**: Old signatures can't be reused, even if copied.

### 2. Domain Separation

```solidity
// Different contracts have different domain separators
DOMAIN_SEPARATOR = keccak256(abi.encode(
    DOMAIN_TYPEHASH,
    keccak256(bytes(DOMAIN_NAME)),  // "ERC-8001-Core"
    keccak256(bytes(DOMAIN_VERSION)), // "1"
    block.chainid,
    address(this)
));
```

**Benefit**: Signatures for one contract don't work on another, even with identical data.

### 3. Expiration Enforcement

```solidity
require(intent.expiry > block.timestamp, "Intent expired");
require(attestation.expiry > block.timestamp, "Acceptance expired");
```

**Benefit**: Old proposals can't be executed months later when conditions changed.

### 4. Smart Contract Signature Support

```solidity
function _isValidSig(address signer, bytes32 digest, bytes memory signature) 
    internal view returns (bool) {
    if (signer.code.length == 0) {
        // EOA: Use ECDSA recovery
        (address recovered, ECDSA.RecoverError err) = digest.tryRecover(signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer;
    } else {
        // Smart Contract: Use ERC-1271
        try IERC1271(signer).isValidSignature(digest, signature) 
            returns (bytes4 magic) {
            return magic == IERC1271.isValidSignature.selector;
        } catch {
            return false;
        }
    }
}
```

**Benefit**: Works with smart contract wallets (Safe, Argent, etc.) not just EOAs.

### 5. Reentrancy Protection

```solidity
modifier nonReentrant() {
    require(!_locked, "Reentrant");
    _locked = true;
    _;
    _locked = false;
}
```

**Benefit**: Prevents complex reentrancy attacks during execution.

### 6. Atomic Execution

Once status changes to `Executed`, it cannot be reverted:

```solidity
// State change BEFORE external calls (CEI pattern)
st.status = Status.Executed;
(success, result) = _executeInternal(intentHash, payload, executionData, st);
```

**Benefit**: Prevents double-execution even if external call reverts.

---

## Integration Guide

### Step 1: Inherit GameCoordination

```solidity
import {GameCoordination} from "./GameCoordination.sol";

contract MyTournament is GameCoordination {
    constructor(address _gameToken) GameCoordination(_gameToken) {}
}
```

### Step 2: Override _executeInternal

```solidity
function _executeInternal(
    bytes32 intentHash,
    CoordinationPayload calldata payload,
    bytes calldata executionData,
    CoordinationState storage state
) internal override returns (bool success, bytes memory result) {
    // Decode your specific data
    (uint256 tournamentId, address winner) = abi.decode(
        payload.coordinationData, 
        (uint256, address)
    );
    
    // Execute your logic
    tournaments[tournamentId].winner = winner;
    distributePrizes(tournamentId, winner);
    
    return (true, abi.encode(tournamentId));
}
```

### Step 3: Create Frontend Integration

```javascript
// Using ethers.js
import { ethers } from 'ethers';

// 1. Create intent
const intent = {
    payloadHash: ethers.keccak256(payloadData),
    expiry: Math.floor(Date.now() / 1000) + 3600, // 1 hour
    nonce: await contract.getAgentNonce(playerAddress),
    agentId: playerAddress,
    coordinationType: ethers.keccak256(ethers.toUtf8Bytes("TOURNAMENT")),
    coordinationValue: ethers.parseEther("0.1"),
    participants: [playerAddress, opponentAddress].sort()
};

// 2. Sign intent (EIP-712)
const domain = {
    name: "ERC-8001-Core",
    version: "1",
    chainId: 1,
    verifyingContract: contractAddress
};

const types = {
    AgentIntent: [
        { name: 'payloadHash', type: 'bytes32' },
        { name: 'expiry', type: 'uint64' },
        { name: 'nonce', type: 'uint64' },
        { name: 'agentId', type: 'address' },
        { name: 'coordinationType', type: 'bytes32' },
        { name: 'coordinationValue', type: 'uint256' },
        { name: 'participants', type: 'address[]' }
    ]
};

const signature = await signer.signTypedData(domain, types, intent);

// 3. Submit to contract
await contract.proposeCoordination(intent, signature, payload);
```

### Step 4: Handle Acceptances

```javascript
// Each participant signs acceptance
const attestation = {
    intentHash: computedIntentHash,
    participant: userAddress,
    nonce: await contract.getAgentNonce(userAddress),
    expiry: Math.floor(Date.now() / 1000) + 1800, // 30 min
    conditionsHash: ethers.ZeroHash
};

const attestationTypes = {
    AcceptanceAttestation: [
        { name: 'intentHash', type: 'bytes32' },
        { name: 'participant', type: 'address' },
        { name: 'nonce', type: 'uint64' },
        { name: 'expiry', type: 'uint64' },
        { name: 'conditionsHash', type: 'bytes32' }
    ]
};

const acceptanceSig = await signer.signTypedData(
    domain, 
    attestationTypes, 
    attestation
);

// Submit acceptance
await contract.acceptCoordination(intentHash, {
    ...attestation,
    signature: acceptanceSig
});
```

### Step 5: Execute

```javascript
// Once all accept, anyone can execute
await contract.executeCoordination(intentHash, payload, executionData);
```

---

## Best Practices

### 1. Keep Participant Lists Small

```solidity
uint256 public constant MAX_PARTICIPANTS = 32;
```

Gas costs scale with participant count. For larger groups, use representative agents.

### 2. Set Reasonable Expirations

```solidity
// Intent: 24 hours
uint64 intentExpiry = uint64(block.timestamp + 1 days);

// Acceptance: 1 hour after signing
uint64 acceptanceExpiry = uint64(block.timestamp + 1 hours);
```

### 3. Validate Off-Chain First

```javascript
// Check status before submitting
const status = await contract.getCoordinationStatus(intentHash);
if (status.status !== 1) { // Proposed
    throw new Error("Intent not in Proposed state");
}
```

### 4. Use Sorted Participants

```solidity
// Must be sorted ascending
address[] participants = [alice, bob, charlie].sort();
require(_isSortedUnique(participants), "Participants not canonical");
```

### 5. Emit Events for Indexing

```solidity
event CoordinationProposed(...);
event CoordinationAccepted(...);
event CoordinationReady(...);
event CoordinationExecuted(...);
```

Frontend should listen to these for real-time updates.

### 6. Test Edge Cases

```solidity
// Test: Double acceptance should revert
vm.expectRevert("Already accepted");
coordination.acceptCoordination(intentHash, attestation);

// Test: Expired intent should revert
vm.warp(intent.expiry + 1);
vm.expectRevert("Intent expired");
coordination.acceptCoordination(intentHash, attestation);
```

### 7. Document Coordination Types

```solidity
/// @notice coordinationType values:
/// - keccak256("TOURNAMENT"): Competitive events with entry fees
/// - keccak256("TEAM_STAKE"): Shared staking pools
/// - keccak256("BATTLE"): PvP encounters
/// - keccak256("LOOT_SHARE"): Treasure distribution
bytes32 public constant COORDINATION_TOURNAMENT = keccak256("TOURNAMENT");
```

---

## Summary

ERC-8001 brings **cryptographic coordination** to blockchain games, enabling:

- **Trustless multiplayer**: No central authority needed
- **Pre-commitment**: Players commit before acting
- **Atomic execution**: All-or-nothing operations
- **Verifiable fairness**: All terms signed and auditable

By integrating ERC-8001 into your GameFi contracts, you create systems where players can confidently participate in complex multiplayer interactions without trusting each other or a central authority.

### Key Takeaways

1. **AgentIntent** = Proposal signed by coordinator
2. **AcceptanceAttestation** = Agreement signed by each participant
3. **CoordinationPayload** = What actually executes
4. **EIP-712** = Human-readable, secure signatures
5. **Status progression** = Proposed → Ready → Executed

The implementations in this chapter (`GameCoordination`, `MultiplayerGameLobby`, `TeamStaking`, `ERC8001LootBox`) demonstrate how to build real multiplayer games on this foundation.

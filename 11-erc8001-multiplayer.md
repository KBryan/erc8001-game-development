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

> **Standard status**: ERC-8001 is a draft proposal at the time of writing. The core flow described here is stable in this book's reference implementation, but the standard itself may still change before finalization — check the current EIP text before deploying against it.

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

Each contract has a unique domain separator for cross-contract replay protection. It is built from the chain id and contract address, and served fork-safely — cached at deployment, rebuilt if the chain id ever changes so signatures cannot replay across a chain fork:

```solidity
function DOMAIN_SEPARATOR() public view returns (bytes32) {
    return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
}

function _buildDomainSeparator() private view returns (bytes32) {
    return keccak256(
        abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(DOMAIN_NAME)),     // "ERC-8001-Core"
            keccak256(bytes(DOMAIN_VERSION)),  // "1"
            block.chainid,
            address(this)
        )
    );
}
```

### Wallet Display Example

When signing an intent, wallets render the typed fields — but as their **raw values**, not friendly labels. A `bytes32` coordination type shows as a hash, an expiry as a Unix timestamp, and a value in wei:

```
Sign Typed Data

Domain: ERC-8001-Core, version 1
Chain: 8453
Contract: 0x1234...

Message:
- payloadHash: 0xabc123...
- expiry: 1767225600
- nonce: 7
- agentId: 0xYourAddress...
- coordinationType: 0x73fda5...  (keccak256("TOURNAMENT"))
- coordinationValue: 100000000000000000
- participants: [0xAlice..., 0xBob..., 0xYou...]
```

EIP-712 gives users *verifiable* structure, not *readable* structure: your front end must decode and present the terms ("Tournament, 0.1 ETH entry, 3 players, expires in 1 hour") before requesting the signature, so the wallet prompt confirms what the player already understood.

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
   - Caller is the agent, or a relayer the agent pre-approved via `approveRelayer`
   - Intent not expired
   - Participants sorted and unique
   - Agent is in participant list
   - Payload hash matches
   - Nonce is strictly increasing

The relayer gate matters: without it, anyone could copy a signed intent from the mempool and submit it first, becoming the recorded submitter — with the cancellation rights that role carries. Approving a game contract once (`coordination.approveRelayer(gameContract, true)`) is what authorizes it to propose, execute, and cancel on your behalf.

**Gas cost**: roughly 290,000 gas for a 4-player coordination (measured with `forge test --gas-report` against this book's reference implementation). The dominant cost is storing the participant list — about 20,000 gas per address — so cost grows roughly linearly with roster size.

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
   - `attestation.participant` is on the intent's participant list
   - That participant has not already accepted
   - The participant's signature is valid
   - Attestation expiry > now

Note that the contract validates the **attestation's signer**, not `msg.sender`. The signature is what authorizes the acceptance, so anyone can submit it on the participant's behalf — this deliberate design is what lets wrapper contracts like `MultiplayerGameLobby` relay signed acceptances for their players.

**When All Accept**:
```solidity
if (st.acceptedCount == st.participants.length) {
    st.status = Status.Ready;
    emit CoordinationReady(intentHash, count, minAcceptanceExpiry);
}
```

**Gas cost**: roughly 120,000 gas per acceptance (measured; includes signature verification and fresh storage writes for the acceptance record)

### Phase 3: Execution (Ready → Executed)

**Who**: The proposer, or the contract that submitted the proposal  
**What**: Trigger actual execution

Execution is deliberately *not* permissionless: a stranger who executed a Ready coordination directly would flip its status to `Executed` behind the wrapper contract's back, stranding any escrowed fees the wrapper was managing. Restricting execution to the proposer and submitter keeps wrapper state and coordination state in lockstep.

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

**Cancellation**:
```solidity
function cancelCoordination(bytes32 intentHash, string calldata reason) external;
```

Before expiry, only the proposer — or the contract that submitted the proposal on the proposer's behalf, such as a game lobby — may cancel. After expiry, anyone may.

**Expiration**:
- Expiry is enforced whenever acceptance, execution, or cancellation is attempted — there is no automatic background sweep, because contracts only run when called
- After the deadline, anyone can call `cancelCoordination` to mark the intent `Expired`, which lets wrapper contracts release refunds

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
- Tournament management with entry fees; only the coordination proposer can complete a tournament, and the winner must be a registered participant
- Battle coordination for PvP, resolved by the proposer with the winner constrained to the two combatants
- Team rewards paid from a deposited, tracked pool (`depositTeamRewards` funds it; `distributeTeamRewards` splits it) rather than a caller-supplied amount
- Loot sharing agreements
- Configurable coordination types

### MultiplayerGameLobby

A lobby wraps one ERC-8001 coordination: the **lobby ID is the intent hash**, the roster is fixed when the host proposes, and the game can start exactly when every rostered player has accepted *and paid*. One prerequisite: the host approves the lobby as their relayer once — `coordination.approveRelayer(address(lobby), true)` — before creating their first lobby.

```solidity
// Create a lobby: the host submits their signed AgentIntent naming the
// exact roster -- this proposes the ERC-8001 coordination (the lobby
// must be an approved relayer for the host)
function createLobby(
    AgentIntent calldata intent,
    bytes calldata signature,
    CoordinationPayload calldata payload,
    uint256 gameMode,
    bytes32 mapId
) external returns (bytes32 lobbyId);

// Join: every rostered player -- the host included -- submits a signed
// AcceptanceAttestation; the entry fee is pulled in the game's ERC-20
// token from the ATTESTATION'S participant (who approves the token to
// the lobby first), so a relayed join still charges the player, never
// the relayer. Not payable: fees are tokens, not ETH.
function joinLobby(
    bytes32 lobbyId,
    AcceptanceAttestation calldata attestation
) external;

// Start: once all rostered players have joined, executes the
// coordination
function startGame(
    bytes32 lobbyId,
    CoordinationPayload calldata payload,
    bytes calldata executionData
) external;

// Payout: the host declares the winner, who receives the pot
// (entryFee x players), paid exactly once
function declareWinner(bytes32 lobbyId, address winner) external;
```

Before the game starts, the host can `cancelLobby` (anyone can, once the intent has expired), which cancels the underlying coordination and refunds every collected entry fee.

**Use case**: Skill-based matchmaking where players commit to playing before the game starts.

### TeamStaking

Team-based staking with shared rewards. The leader proposes with a signed intent (after approving the contract as their relayer, as with the lobby); members accept by contributing:

```solidity
// Leader proposes: signed intent plus the stake terms
function createTeamStake(
    AgentIntent calldata intent,
    bytes calldata signature,
    CoordinationPayload calldata payload,
    uint256 minStake,
    uint256 maxStake,
    uint256 lockPeriod,
    uint256 rewardRate
) external returns (bytes32 stakeId);

// Each member contributes tokens along with their signed acceptance
function contributeStake(
    bytes32 stakeId,
    AcceptanceAttestation calldata attestation,
    uint256 amount
) external;

// Once every member has accepted, activate (executes the coordination
// and starts the lock period)
function activateTeamStake(
    bytes32 stakeId,
    CoordinationPayload calldata payload,
    bytes calldata executionData
) external;

// Rewards are claimed per member; stakes withdraw after the lock period
function claimRewards(bytes32 stakeId) external;
function withdrawStake(bytes32 stakeId) external;

// The leader can declare an emergency, permitting early exits
function declareEmergency(bytes32 stakeId) external;
```

The lock is real: an active stake cannot be exited early unless the leader has declared an emergency, and a member who has withdrawn can never claim later distributions.

**Use case**: Guild staking pools where all members must agree on reward distribution.

### ERC8001LootBox

Multi-party loot distribution using Pyth Entropy (the organizer approves the contract as their relayer first, as with the lobby). Opening is **asynchronous** — one transaction requests verifiable randomness, and the items are distributed later in the oracle's callback:

```solidity
// Organizer proposes the box with item hashes and a per-player open fee
function createLootBox(
    AgentIntent calldata intent,
    bytes calldata signature,
    CoordinationPayload calldata payload,
    bytes32[] calldata itemHashes,
    uint256 openFee
) external returns (bytes32 boxId);

// Every participant agrees with a signed attestation
function agreeToOpen(
    bytes32 boxId,
    AcceptanceAttestation calldata attestation
) external;

// Opening step 1: executes the coordination and requests randomness
// from Pyth Entropy (msg.value pays the oracle fee); items are NOT
// distributed yet
function openLootBox(
    bytes32 boxId,
    CoordinationPayload calldata payload,
    bytes32 userRandomness
) external payable returns (uint64 sequenceNumber);

// Opening step 2: Pyth calls back with the random value; this
// distributes the items and pays the collected open fees to the
// organizer
function entropyCallback(uint64 sequenceNumber, bytes32 randomness) external;
```

There is no synchronous "open and receive items" call — front ends should listen for the `LootBoxOpened` and `ItemDistributed` events emitted from the callback.

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
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

// OZ SignatureChecker handles the split: ECDSA recovery for EOAs,
// ERC-1271 isValidSignature for smart contract wallets
function _isValidSig(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool) {
    return SignatureChecker.isValidSignatureNowCalldata(signer, digest, signature);
}
```

**Benefit**: Works with smart contract wallets (Safe, Argent, etc.) not just EOAs — and leaning on OpenZeppelin's audited `SignatureChecker` avoids hand-rolling the EOA/ERC-1271 branching (an earlier draft of this contract did, and got the failure path subtly wrong).

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
    // Sort by numeric address value (plain .sort() compares strings,
    // which breaks on mixed-case checksummed addresses)
    participants: [playerAddress, opponentAddress]
        .sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1))
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
// Once all accept, the proposer (or the contract that submitted the
// proposal) executes -- execution is not open to third parties
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

The contract enforces a canonical ordering — sorted ascending, no duplicates:

```solidity
require(_isSortedUnique(intent.participants), "Participants not canonical");
```

Solidity has no built-in array sort, so sort in the front end — by numeric address value, not string order (checksummed hex strings don't sort lexicographically into numeric order):

```javascript
const participants = [alice, bob, charlie]
    .sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1));
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

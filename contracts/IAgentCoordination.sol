// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IAgentCoordination
 * @notice Interface for ERC-8001 Agent Coordination Standard
 * @dev Enables multi-agent coordination through signed intents
 */

/// @notice Status of a coordination
enum Status {
    None,       // 0: Not created
    Proposed,   // 1: Intent proposed, awaiting acceptances
    Ready,      // 2: All participants accepted, ready to execute
    Executed,   // 3: Coordination executed
    Cancelled,  // 4: Cancelled by proposer
    Expired     // 5: Intent or acceptance expired
}

/**
 * @notice Intent struct for proposing coordination
 * @param payloadHash Hash of the CoordinationPayload data
 * @param expiry Timestamp when intent expires
 * @param nonce Agent's nonce for replay protection
 * @param agentId Address of the agent proposing the coordination
 * @param coordinationType Type of coordination (e.g., TOURNAMENT, BATTLE)
 * @param coordinationValue Value associated with coordination (e.g., entry fee)
 * @param participants Sorted array of participant addresses
 */
struct AgentIntent {
    bytes32 payloadHash;
    uint64 expiry;
    uint64 nonce;
    address agentId;
    bytes32 coordinationType;
    uint256 coordinationValue;
    address[] participants;
}

/**
 * @notice Attestation struct for accepting coordination
 * @param intentHash Hash of the AgentIntent being accepted
 * @param participant Address of the participant accepting
 * @param nonce Participant's nonce for replay protection
 * @param expiry Timestamp when acceptance expires
 * @param conditionsHash Hash of any additional conditions
 * @param signature EIP-712 signature over this struct
 */
struct AcceptanceAttestation {
    bytes32 intentHash;
    address participant;
    uint64 nonce;
    uint64 expiry;
    bytes32 conditionsHash;
    bytes signature;
}

/**
 * @notice Payload struct containing actual execution data
 * @param version Version of the payload format
 * @param coordinationType Type of coordination (matches intent)
 * @param coordinationData Encoded execution data
 * @param conditionsHash Hash of execution conditions
 * @param timestamp Creation timestamp
 * @param metadata Additional metadata
 */
struct CoordinationPayload {
    uint32 version;
    bytes32 coordinationType;
    bytes coordinationData;
    bytes32 conditionsHash;
    uint64 timestamp;
    bytes metadata;
}

/**
 * @title IAgentCoordination
 * @notice Interface for the ERC-8001 Agent Coordination contract
 */
interface IAgentCoordination {
    
    /// @notice Emitted when a coordination is proposed
    event CoordinationProposed(
        bytes32 indexed intentHash,
        address indexed proposer,
        bytes32 coordinationType,
        uint256 participantCount,
        uint256 coordinationValue
    );

    /// @notice Emitted when a participant accepts coordination
    event CoordinationAccepted(
        bytes32 indexed intentHash,
        address indexed participant,
        bytes32 indexed acceptanceHash,
        uint256 acceptedCount,
        uint256 totalParticipants
    );

    /// @notice Emitted when coordination is executed
    event CoordinationExecuted(
        bytes32 indexed intentHash,
        address indexed executor,
        bool success,
        uint256 gasUsed,
        bytes result
    );

    /// @notice Emitted when coordination is cancelled or expired
    event CoordinationCancelled(
        bytes32 indexed intentHash,
        address indexed cancelledBy,
        string reason,
        uint8 finalStatus
    );

    /**
     * @notice Propose a new coordination
     * @param intent The intent struct with coordination details
     * @param signature EIP-712 signature over the intent
     * @param payload The coordination payload
     * @return intentHash Hash of the created intent
     */
    function proposeCoordination(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload
    ) external returns (bytes32 intentHash);

    /**
     * @notice Accept a proposed coordination
     * @param intentHash Hash of the intent to accept
     * @param attestation Acceptance attestation with signature
     * @return allAccepted True if all participants have accepted
     */
    function acceptCoordination(
        bytes32 intentHash,
        AcceptanceAttestation calldata attestation
    ) external returns (bool allAccepted);

    /**
     * @notice Execute a ready coordination
     * @param intentHash Hash of the intent to execute
     * @param payload The coordination payload (must match hash)
     * @param executionData Additional execution parameters
     * @return success Whether execution succeeded
     * @return result Execution result data
     */
    function executeCoordination(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData
    ) external returns (bool success, bytes memory result);

    /**
     * @notice Cancel a coordination
     * @param intentHash Hash of the intent to cancel
     * @param reason Reason for cancellation
     */
    function cancelCoordination(bytes32 intentHash, string calldata reason) external;

    /**
     * @notice Get coordination status
     * @param intentHash Hash of the intent
     * @return status Current status
     * @return proposer Address of proposer
     * @return participants Array of participant addresses
     * @return acceptedBy Array of addresses that have accepted
     * @return expiry Expiration timestamp
     */
    function getCoordinationStatus(bytes32 intentHash)
        external
        view
        returns (
            Status status,
            address proposer,
            address[] memory participants,
            address[] memory acceptedBy,
            uint256 expiry
        );

    /**
     * @notice Get detailed coordination info
     */
    function getCoordinationDetails(bytes32 intentHash)
        external
        view
        returns (
            Status status,
            address proposer,
            bytes32 payloadHash,
            uint64 intentExpiry,
            uint64 minAcceptanceExpiry,
            uint256 acceptedCount,
            uint256 totalParticipants,
            uint256 coordinationValue
        );

    /// @notice Get agent's current nonce
    function getAgentNonce(address agent) external view returns (uint64);

    /// @notice Check if participant has accepted
    function hasAccepted(bytes32 intentHash, address participant) external view returns (bool);

    /// @notice Get required number of acceptances
    function getRequiredAcceptances(bytes32 intentHash) external view returns (uint256);

    /// @notice Get EIP-712 domain separator
    function getDomainSeparator() external view returns (bytes32);

    /// @notice Get hash for EIP-712 typed data
    function getTypedDataDigest(bytes32 structHash) external view returns (bytes32);
}

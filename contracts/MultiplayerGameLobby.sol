// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentCoordination} from "./AgentCoordination.sol";
import {GameCoordination} from "./GameCoordination.sol";

/**
 * @title MultiplayerGameLobby
 * @notice Simple game lobby using ERC-8001 coordination
 * @dev Enables multiplayer game lobbies with entry fees, player limits,
 *      and on-chain coordination status for off-chain game servers
 * 
 * ERC-8001 FLOW IN THIS CONTRACT:
 * 1. Host creates AgentIntent (off-chain) with participants list
 * 2. Host calls createLobby() → proposeCoordination() (Status: Proposed)
 * 3. Each player calls joinLobby() → acceptCoordination() (Status: Ready when all accept)
 * 4. Anyone can call startGame() → executeCoordination() (Status: Executed)
 * 5. Off-chain game server monitors status to start actual gameplay
 */
contract MultiplayerGameLobby {

    // ============ State Structures ============

    /**
     * @notice Game lobby state
     * @param intentHash Reference to ERC-8001 coordination
     * @param host Address that created the lobby
     * @param players Array of invited player addresses
     * @param acceptedCount Number of players who accepted
     * @param minPlayers Minimum players needed to start
     * @param maxPlayers Maximum players allowed
     * @param entryFee Amount each player must pay (in game tokens)
     * @param gameMode Identifier for game mode/type
     * @param mapId Identifier for map/level
     * @param status Current lobby status
     * @param createdAt Block timestamp of creation
     */
    struct GameLobby {
        bytes32 intentHash;
        address host;
        address[] players;
        uint256 acceptedCount;
        uint256 minPlayers;
        uint256 maxPlayers;
        uint256 entryFee;
        uint256 gameMode;
        bytes32 mapId;
        LobbyStatus status;
        uint256 createdAt;
    }

    /**
     * @notice Lobby lifecycle status
     * @dev Tracks state independently of ERC-8001 for UX clarity
     */
    enum LobbyStatus {
        None,       // Lobby doesn't exist
        Created,    // Coordination proposed
        Joining,    // Players accepting
        Ready,      // All required players accepted
        Starting,   // Game execution in progress
        Active,     // Game is running (off-chain)
        Finished,   // Game completed
        Cancelled   // Lobby cancelled
    }

    // ============ State Variables ============

    /// @notice GameCoordination contract for ERC-8001 operations
    GameCoordination public immutable coordination;

    /// @notice ERC-20 game token for entry fees
    address public immutable gameToken;

    /// @notice Minimum entry fee (anti-spam)
    uint256 public constant MIN_ENTRY_FEE = 0.0001 ether;

    /// @notice Maximum lobby duration (prevents stale lobbies)
    uint256 public constant MAX_LOBBY_DURATION = 1 hours;

    /// @notice Minimum players per lobby
    uint256 public constant MIN_PLAYERS = 2;

    /// @notice Maximum players per lobby
    uint256 public constant MAX_PLAYERS = 16;

    /// @notice Lobby data by lobby ID (uses intent hash as ID)
    mapping(bytes32 => GameLobby) public lobbies;

    /// @notice Track lobbies by host for easy lookup
    mapping(address => bytes32[]) public hostLobbies;

    /// @notice Track which lobbies a player is invited to
    mapping(address => bytes32[]) public playerInvites;

    // ============ Events ============

    /// @notice Emitted when lobby is created
    event LobbyCreated(
        bytes32 indexed lobbyId,
        address indexed host,
        uint256 maxPlayers,
        uint256 entryFee,
        uint256 gameMode,
        bytes32 mapId
    );

    /// @notice Emitted when player joins lobby
    event PlayerJoined(
        bytes32 indexed lobbyId,
        address indexed player,
        uint256 acceptedCount,
        uint256 requiredCount
    );

    /// @notice Emitted when lobby reaches ready state
    event LobbyReady(bytes32 indexed lobbyId, uint256 playerCount);

    /// @notice Emitted when game starts
    event GameStarted(
        bytes32 indexed lobbyId,
        address indexed starter,
        uint256 timestamp
    );

    /// @notice Emitted when game ends
    event GameFinished(
        bytes32 indexed lobbyId,
        address[] finalPlayers,
        uint256 duration
    );

    /// @notice Emitted when lobby is cancelled
    event LobbyCancelled(
        bytes32 indexed lobbyId,
        address indexed canceller,
        string reason
    );

    /// @notice Emitted when entry fee is refunded
    event EntryFeeRefunded(
        bytes32 indexed lobbyId,
        address indexed player,
        uint256 amount
    );

    // ============ Errors ============

    error InvalidCoordinationContract();
    error InvalidPlayerCount();
    error InvalidEntryFee();
    error LobbyNotFound();
    error LobbyAlreadyExists();
    error NotHost();
    error NotInvitedPlayer();
    error AlreadyJoined();
    error LobbyFull();
    error LobbyExpired();
    error LobbyNotReady();
    error LobbyAlreadyStarted();
    error TransferFailed();
    error InvalidGameMode();

    // ============ Modifiers ============

    modifier lobbyExists(bytes32 lobbyId) {
        if (lobbies[lobbyId].status == LobbyStatus.None) revert LobbyNotFound();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize lobby contract
     * @param _coordination GameCoordination contract address
     * @param _gameToken Game token address for entry fees
     */
    constructor(address _coordination, address _gameToken) {
        if (_coordination == address(0)) revert InvalidCoordinationContract();
        coordination = GameCoordination(_coordination);
        gameToken = _gameToken;
    }

    // ============ Lobby Creation ============

    /**
     * @notice Create a game lobby using ERC-8001 intent
     * @dev Host proposes coordination through ERC-8001
     * @param intent Signed coordination intent (EIP-712)
     * @param signature Agent signature on intent
     * @param payload Coordination payload with game parameters
     * @param gameMode Game mode identifier
     * @param mapId Map/level identifier
     * @return lobbyId The created lobby ID (intent hash)
     * 
     * ERC-8001 FLOW:
     * - Host creates AgentIntent off-chain with EIP-712
     * - Calls proposeCoordination() → Status: Proposed
     * - Lobby is now waiting for player acceptances
     */
    function createLobby(
        AgentCoordination.AgentIntent calldata intent,
        bytes calldata signature,
        AgentCoordination.CoordinationPayload calldata payload,
        uint256 gameMode,
        bytes32 mapId
    ) external returns (bytes32 lobbyId) {
        // Validate player count
        if (intent.participants.length < MIN_PLAYERS) revert InvalidPlayerCount();
        if (intent.participants.length > MAX_PLAYERS) revert InvalidPlayerCount();

        // Validate entry fee
        if (intent.coordinationValue < MIN_ENTRY_FEE) revert InvalidEntryFee();

        // Validate host is first participant
        if (intent.participants[0] != msg.sender) revert NotHost();

        // Propose coordination through ERC-8001
        // This creates the intent hash and stores coordination state
        lobbyId = coordination.proposeCoordination(intent, signature, payload);

        // Check lobby doesn't already exist
        if (lobbies[lobbyId].status != LobbyStatus.None) revert LobbyAlreadyExists();

        // Store lobby details
        lobbies[lobbyId] = GameLobby({
            intentHash: lobbyId,
            host: msg.sender,
            players: intent.participants,
            acceptedCount: 1, // Host auto-accepts
            minPlayers: MIN_PLAYERS,
            maxPlayers: intent.participants.length,
            entryFee: intent.coordinationValue,
            gameMode: gameMode,
            mapId: mapId,
            status: LobbyStatus.Created,
            createdAt: block.timestamp
        });

        // Track host lobbies
        hostLobbies[msg.sender].push(lobbyId);

        // Track invites for all players
        for (uint256 i = 0; i < intent.participants.length; i++) {
            playerInvites[intent.participants[i]].push(lobbyId);
        }

        emit LobbyCreated(
            lobbyId,
            msg.sender,
            intent.participants.length,
            intent.coordinationValue,
            gameMode,
            mapId
        );
    }

    // ============ Join Lobby ============

    /**
     * @notice Join lobby by accepting coordination
     * @dev Player accepts coordination through ERC-8001
     * @param lobbyId Lobby to join
     * @param attestation Signed acceptance attestation (EIP-712)
     * 
     * ERC-8001 FLOW:
     * - Player creates AcceptanceAttestation off-chain
     * - Calls acceptCoordination() → adds acceptance
     * - When all accept: Status → Ready
     */
    function joinLobby(
        bytes32 lobbyId,
        AgentCoordination.AcceptanceAttestation calldata attestation
    ) external lobbyExists(lobbyId) {
        GameLobby storage lobby = lobbies[lobbyId];

        // Validate lobby state
        if (lobby.status == LobbyStatus.Starting || lobby.status == LobbyStatus.Active) {
            revert LobbyAlreadyStarted();
        }
        if (lobby.status == LobbyStatus.Finished || lobby.status == LobbyStatus.Cancelled) {
            revert LobbyAlreadyStarted();
        }
        if (block.timestamp > lobby.createdAt + MAX_LOBBY_DURATION) {
            revert LobbyExpired();
        }

        // Validate player is invited
        bool isInvited = false;
        for (uint256 i = 0; i < lobby.players.length; i++) {
            if (lobby.players[i] == msg.sender) {
                isInvited = true;
                break;
            }
        }
        if (!isInvited) revert NotInvitedPlayer();

        // Check not already joined
        if (coordination.hasAccepted(lobbyId, msg.sender)) revert AlreadyJoined();

        // Collect entry fee
        if (lobby.entryFee > 0) {
            (bool xferSuccess, ) = gameToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transferFrom(address,address,uint256)")),
                    msg.sender,
                    address(this),
                    lobby.entryFee
                )
            );
            if (!xferSuccess) revert TransferFailed();
        }

        // Accept coordination through ERC-8001
        bool allAccepted = coordination.acceptCoordination(lobbyId, attestation);

        // Update lobby state
        lobby.acceptedCount += 1;

        if (lobby.acceptedCount >= lobby.minPlayers) {
            lobby.status = LobbyStatus.Ready;
            emit LobbyReady(lobbyId, lobby.acceptedCount);
        } else {
            lobby.status = LobbyStatus.Joining;
        }

        emit PlayerJoined(
            lobbyId,
            msg.sender,
            lobby.acceptedCount,
            lobby.players.length
        );
    }

    // ============ Start Game ============

    /**
     * @notice Start game when all players accepted
     * @dev Executes coordination through ERC-8001
     * @param lobbyId Lobby to start
     * @param payload Coordination payload (must match proposed)
     * @param executionData Additional game parameters for execution
     * 
     * ERC-8001 FLOW:
     * - Calls executeCoordination() → Status: Executed
     * - Triggers _executeInternal() hook in GameCoordination
     * - Returns success/failure with result data
     */
    function startGame(
        bytes32 lobbyId,
        AgentCoordination.CoordinationPayload calldata payload,
        bytes calldata executionData
    ) external lobbyExists(lobbyId) {
        GameLobby storage lobby = lobbies[lobbyId];

        // Validate state
        if (lobby.status != LobbyStatus.Ready) revert LobbyNotReady();
        if (lobby.status == LobbyStatus.Active) revert LobbyAlreadyStarted();

        // Update status
        lobby.status = LobbyStatus.Starting;

        // Execute coordination through ERC-8001
        // This calls _executeInternal in GameCoordination
        (bool success, bytes memory result) = coordination.executeCoordination(
            lobbyId,
            payload,
            executionData
        );

        if (!success) revert TransferFailed();

        // Mark as active for off-chain tracking
        lobby.status = LobbyStatus.Active;

        emit GameStarted(lobbyId, msg.sender, block.timestamp);

        // Result can be used by off-chain systems
        // result typically contains game parameters
        (result); // Silence unused warning
    }

    // ============ Finish Game ============

    /**
     * @notice Mark game as finished
     * @dev Called by game oracle or host after off-chain game completes
     * @param lobbyId Lobby to finish
     * @param finalPlayers Array of players who completed the game
     */
    function finishGame(
        bytes32 lobbyId,
        address[] calldata finalPlayers
    ) external lobbyExists(lobbyId) {
        GameLobby storage lobby = lobbies[lobbyId];

        // Only host or coordination contract can finish
        if (msg.sender != lobby.host && msg.sender != address(coordination)) {
            revert NotHost();
        }

        if (lobby.status != LobbyStatus.Active) revert LobbyNotReady();

        lobby.status = LobbyStatus.Finished;

        uint256 duration = block.timestamp - lobby.createdAt;

        emit GameFinished(lobbyId, finalPlayers, duration);
    }

    // ============ Cancel Lobby ============

    /**
     * @notice Cancel lobby and refund entry fees
     * @dev Can be called by host or if lobby expired
     * @param lobbyId Lobby to cancel
     * @param reason Cancellation reason
     */
    function cancelLobby(
        bytes32 lobbyId,
        string calldata reason
    ) external lobbyExists(lobbyId) {
        GameLobby storage lobby = lobbies[lobbyId];

        // Only host can cancel, or anyone if expired
        bool canCancel = msg.sender == lobby.host || 
                         block.timestamp > lobby.createdAt + MAX_LOBBY_DURATION;

        if (!canCancel) revert NotHost();
        if (lobby.status == LobbyStatus.Active || lobby.status == LobbyStatus.Finished) {
            revert LobbyAlreadyStarted();
        }

        // Cancel coordination through ERC-8001
        coordination.cancelCoordination(lobbyId, reason);

        // Refund entry fees to all who paid
        for (uint256 i = 0; i < lobby.players.length; i++) {
            address player = lobby.players[i];
            if (coordination.hasAccepted(lobbyId, player) && lobby.entryFee > 0) {
                (bool xferSuccess, ) = gameToken.call(
                    abi.encodeWithSelector(
                        bytes4(keccak256("transfer(address,uint256)")),
                        player,
                        lobby.entryFee
                    )
                );
                if (xferSuccess) {
                    emit EntryFeeRefunded(lobbyId, player, lobby.entryFee);
                }
            }
        }

        lobby.status = LobbyStatus.Cancelled;

        emit LobbyCancelled(lobbyId, msg.sender, reason);
    }

    // ============ View Functions ============

    /**
     * @notice Get lobby details
     * @param lobbyId Lobby ID
     * @return Lobby details struct
     */
    function getLobby(bytes32 lobbyId) external view returns (GameLobby memory) {
        return lobbies[lobbyId];
    }

    /**
     * @notice Get ERC-8001 coordination status
     * @param lobbyId Lobby ID (intent hash)
     * @return status Coordination status from ERC-8001
     * @return proposer Address that proposed coordination
     * @return acceptedCount Number of acceptances
     * @return requiredCount Total participants required
     */
    function getCoordinationStatus(bytes32 lobbyId) external view returns (
        AgentCoordination.Status status,
        address proposer,
        uint256 acceptedCount,
        uint256 requiredCount
    ) {
        (status, proposer,,, uint256 expiry) = coordination.getCoordinationStatus(lobbyId);
        (,,,, acceptedCount, requiredCount,) = coordination.getCoordinationDetails(lobbyId);
        (expiry); // Silence warning
    }

    /**
     * @notice Check if player has accepted
     * @param lobbyId Lobby ID
     * @param player Player address
     * @return accepted True if player accepted
     */
    function hasPlayerAccepted(
        bytes32 lobbyId, 
        address player
    ) external view returns (bool accepted) {
        return coordination.hasAccepted(lobbyId, player);
    }

    /**
     * @notice Get lobbies hosted by address
     * @param host Host address
     * @return Array of lobby IDs
     */
    function getHostLobbies(address host) external view returns (bytes32[] memory) {
        return hostLobbies[host];
    }

    /**
     * @notice Get lobbies player is invited to
     * @param player Player address
     * @return Array of lobby IDs
     */
    function getPlayerInvites(address player) external view returns (bytes32[] memory) {
        return playerInvites[player];
    }

    /**
     * @notice Check if lobby is joinable
     * @param lobbyId Lobby ID
     * @return joinable True if lobby can be joined
     * @return reason Reason if not joinable
     */
    function isJoinable(bytes32 lobbyId) external view returns (bool joinable, string memory reason) {
        GameLobby storage lobby = lobbies[lobbyId];

        if (lobby.status == LobbyStatus.None) {
            return (false, "Lobby not found");
        }
        if (lobby.status == LobbyStatus.Active || lobby.status == LobbyStatus.Finished) {
            return (false, "Game already started");
        }
        if (lobby.status == LobbyStatus.Cancelled) {
            return (false, "Lobby cancelled");
        }
        if (block.timestamp > lobby.createdAt + MAX_LOBBY_DURATION) {
            return (false, "Lobby expired");
        }
        if (lobby.acceptedCount >= lobby.maxPlayers) {
            return (false, "Lobby full");
        }

        return (true, "");
    }
}

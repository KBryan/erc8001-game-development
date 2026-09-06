// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentCoordination} from "./AgentCoordination.sol";
import {Status, AgentIntent, AcceptanceAttestation, CoordinationPayload} from "./IAgentCoordination.sol";

/**
 * @title GameCoordination
 * @notice ERC-8001 extension for multiplayer game coordination
 * @dev Enables signed intents for game lobbies, tournaments, and team actions
 * 
 * ERC-8001 OVERVIEW:
 * - AgentIntent: Proposes coordination signed by agent (EIP-712 typed data)
 * - AcceptanceAttestation: Each participant accepts with their signature
 * - CoordinationPayload: The actual execution data
 * - Status: Proposed → Ready → Executed → Cancelled/Expired
 */
contract GameCoordination is AgentCoordination {

    // ============ Game-Specific Coordination Types ============

    /// @notice Tournament coordination type
    bytes32 public constant COORDINATION_TOURNAMENT = keccak256("TOURNAMENT");

    /// @notice Team staking coordination type
    bytes32 public constant COORDINATION_TEAM_STAKE = keccak256("TEAM_STAKE");

    /// @notice Battle coordination type
    bytes32 public constant COORDINATION_BATTLE = keccak256("BATTLE");

    /// @notice Loot share coordination type
    bytes32 public constant COORDINATION_LOOT_SHARE = keccak256("LOOT_SHARE");

    /// @notice Game lobby coordination type
    bytes32 public constant COORDINATION_LOBBY = keccak256("LOBBY");

    // ============ State Variables ============

    /// @notice ERC-20 token used for game economics (entry fees, rewards)
    address public immutable gameToken;

    /// @notice Minimum entry fee to prevent spam (wei)
    uint256 public constant MIN_ENTRY_FEE = 0.001 ether;

    /// @notice Maximum participants in tournaments
    uint256 public constant MAX_TOURNAMENT_PLAYERS = 64;

    // ============ Tournament State ============

    /**
     * @notice Tournament data structure
     * @param intentHash Reference to the ERC-8001 coordination
     * @param entryFee Amount each player must pay to enter
     * @param prizePool Total collected from all participants
     * @param winner Address of tournament winner (0x0 if not completed)
     * @param completed Whether tournament has been finalized
     */
    struct Tournament {
        bytes32 intentHash;
        uint256 entryFee;
        uint256 prizePool;
        address winner;
        bool completed;
    }

    /// @notice Tournament data by intent hash
    mapping(bytes32 => Tournament) public tournaments;

    /// @notice Track player entry into tournaments
    mapping(bytes32 => mapping(address => bool)) public hasEnteredTournament;

    // ============ Team Staking State ============

    /**
     * @notice Team stake data structure
     * @param intentHash Reference to the ERC-8001 coordination
     * @param totalStaked Total amount staked by all team members
     * @param rewardShare Amount each member receives (for equal splits)
     * @param active Whether stake is active and earning rewards
     * @param rewardToken Token address for rewards (0x0 for ETH)
     */
    struct TeamStake {
        bytes32 intentHash;
        uint256 totalStaked;
        uint256 rewardShare;
        bool active;
        address rewardToken;
    }

    /// @notice Team stake data by intent hash
    mapping(bytes32 => TeamStake) public teamStakes;

    /// @notice Individual contributions to team stakes
    mapping(bytes32 => mapping(address => uint256)) public teamContributions;

    // ============ Battle State ============

    /**
     * @notice Battle data structure for PvP encounters
     * @param intentHash Reference to the ERC-8001 coordination
     * @param challenger Player who initiated the battle
     * @param defender Player who accepted the challenge
     * @param wager Amount at stake
     * @param resolved Whether battle has been resolved
     * @param winner Winner address (0x0 for draw/undecided)
     */
    struct Battle {
        bytes32 intentHash;
        address challenger;
        address defender;
        uint256 wager;
        bool resolved;
        address winner;
    }

    /// @notice Battle data by intent hash
    mapping(bytes32 => Battle) public battles;

    // ============ Loot Share State ============

    /**
     * @notice Loot distribution data structure
     * @param intentHash Reference to the ERC-8001 coordination
     * @param itemIds Array of item identifiers to distribute
     * @param distributed Whether loot has been distributed
     * @param distributionType Equal (0) or Proportional (1)
     */
    struct LootDistribution {
        bytes32 intentHash;
        bytes32[] itemIds;
        bool distributed;
        uint8 distributionType; // 0 = equal, 1 = proportional
    }

    /// @notice Loot distribution data by intent hash
    mapping(bytes32 => LootDistribution) public lootDistributions;

    /// @notice Items claimed by address per distribution
    mapping(bytes32 => mapping(address => bool)) public hasClaimedLoot;

    // ============ Events ============

    /// @notice Emitted when tournament is created
    event TournamentCreated(
        bytes32 indexed intentHash, 
        uint256 entryFee, 
        uint256 playerCount,
        uint256 totalPrize
    );

    /// @notice Emitted when tournament is completed
    event TournamentCompleted(
        bytes32 indexed intentHash, 
        address indexed winner, 
        uint256 prize
    );

    /// @notice Emitted when team stake is activated
    event TeamStakeCreated(
        bytes32 indexed intentHash, 
        uint256 teamSize, 
        uint256 totalAmount,
        address rewardToken
    );

    /// @notice Emitted when team rewards are distributed
    event TeamRewardsDistributed(
        bytes32 indexed intentHash, 
        uint256 totalRewards,
        uint256 perMemberShare
    );

    /// @notice Emitted when battle is initiated
    event BattleCreated(
        bytes32 indexed intentHash,
        address indexed challenger,
        address indexed defender,
        uint256 wager
    );

    /// @notice Emitted when battle is resolved
    event BattleResolved(
        bytes32 indexed intentHash,
        address indexed winner,
        uint256 prize
    );

    /// @notice Emitted when loot is distributed
    event LootDistributed(
        bytes32 indexed intentHash,
        uint256 itemCount,
        uint8 distributionType
    );

    // ============ Errors ============

    error InvalidCoordinationType();
    error TournamentAlreadyExists();
    error TournamentNotFound();
    error InvalidEntryFee();
    error PlayerAlreadyEntered();
    error TournamentFull();
    error TransferFailed();
    error BattleNotFound();
    error BattleAlreadyResolved();
    error LootAlreadyDistributed();
    error NotAuthorized();

    // ============ Constructor ============

    /**
     * @notice Initialize GameCoordination with game token
     * @param _gameToken ERC-20 token address for game economics
     */
    constructor(address _gameToken) {
        gameToken = _gameToken;
    }

    // ============ ERC-8001 Execution Overrides ============

    /**
     * @notice Override _executeInternal to handle game-specific logic
     * @dev Routes to appropriate handler based on coordination type
     * @param intentHash The coordination intent hash
     * @param payload Coordination payload with execution data
     * @param executionData Additional game-specific parameters
     * @param state Reference to coordination state
     * @return success Whether execution succeeded
     * @return result Execution result data (encoded return values)
     */
    function _executeInternal(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData,
        CoordinationState storage state
    ) internal virtual override returns (bool success, bytes memory result) {

        // Route to appropriate game handler based on coordination type
        if (payload.coordinationType == COORDINATION_TOURNAMENT) {
            return _executeTournament(intentHash, payload, executionData, state);
        } else if (payload.coordinationType == COORDINATION_TEAM_STAKE) {
            return _executeTeamStake(intentHash, payload, executionData, state);
        } else if (payload.coordinationType == COORDINATION_BATTLE) {
            return _executeBattle(intentHash, payload, executionData, state);
        } else if (payload.coordinationType == COORDINATION_LOOT_SHARE) {
            return _executeLootShare(intentHash, payload, executionData, state);
        } else if (payload.coordinationType == COORDINATION_LOBBY) {
            return _executeLobby(intentHash, payload, executionData, state);
        }

        // Unknown coordination type - revert
        revert InvalidCoordinationType();
    }

    // ============ Tournament Execution ============

    /**
     * @notice Execute tournament coordination
     * @dev Collects entry fees from all participants
     * @param intentHash The coordination intent hash
     * @param payload Coordination payload
     * @param executionData Encoded (uint256 entryFee, uint256 maxPlayers)
     * @param state Coordination state with participants
     */
    function _executeTournament(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData,
        CoordinationState storage state
    ) internal returns (bool, bytes memory) {
        // Prevent duplicate tournaments
        if (tournaments[intentHash].intentHash != bytes32(0)) {
            revert TournamentAlreadyExists();
        }

        // Decode tournament parameters
        (uint256 entryFee, uint256 maxPlayers) = abi.decode(executionData, (uint256, uint256));

        // Validate parameters
        if (entryFee < MIN_ENTRY_FEE) revert InvalidEntryFee();
        if (maxPlayers > MAX_TOURNAMENT_PLAYERS) revert TournamentFull();
        if (state.participants.length > maxPlayers) revert TournamentFull();

        // Calculate total prize pool
        uint256 totalPrize = entryFee * state.participants.length;

        // Collect entry fees from all participants using game token
        for (uint256 i = 0; i < state.participants.length; i++) {
            address participant = state.participants[i];

            // Prevent double-entry
            if (hasEnteredTournament[intentHash][participant]) {
                revert PlayerAlreadyEntered();
            }

            // Transfer tokens from participant to this contract
            // Note: Participants must approve this contract beforehand
            (bool xferSuccess, ) = gameToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transferFrom(address,address,uint256)")),
                    participant,
                    address(this),
                    entryFee
                )
            );

            if (!xferSuccess) revert TransferFailed();

            hasEnteredTournament[intentHash][participant] = true;
        }

        // Store tournament data
        tournaments[intentHash] = Tournament({
            intentHash: intentHash,
            entryFee: entryFee,
            prizePool: totalPrize,
            winner: address(0),
            completed: false
        });

        emit TournamentCreated(
            intentHash, 
            entryFee, 
            state.participants.length,
            totalPrize
        );

        // Return total prize pool for off-chain tracking
        return (true, abi.encode(totalPrize, state.participants.length));
    }

    /**
     * @notice Complete tournament and distribute prize to winner
     * @dev Only callable after tournament coordination is executed
     * @param intentHash Tournament intent hash
     * @param winnerAddress Address of tournament winner
     */
    function completeTournament(
        bytes32 intentHash, 
        address winnerAddress
    ) external nonReentrant {
        Tournament storage tournament = tournaments[intentHash];

        if (tournament.intentHash == bytes32(0)) revert TournamentNotFound();
        if (tournament.completed) revert TournamentAlreadyExists();

        // Verify winner is a participant
        (bool isParticipant, ) = _binarySearch(getParticipants(intentHash), winnerAddress);
        if (!isParticipant) revert NotAuthorized();

        // Mark as completed
        tournament.winner = winnerAddress;
        tournament.completed = true;

        // Transfer prize pool to winner
        (bool xferSuccess, ) = gameToken.call(
            abi.encodeWithSelector(
                bytes4(keccak256("transfer(address,uint256)")),
                winnerAddress,
                tournament.prizePool
            )
        );

        if (!xferSuccess) revert TransferFailed();

        emit TournamentCompleted(intentHash, winnerAddress, tournament.prizePool);
    }

    // ============ Team Stake Execution ============

    /**
     * @notice Execute team stake coordination
     * @dev Activates staking for a team when all members accept
     * @param intentHash The coordination intent hash
     * @param payload Coordination payload
     * @param executionData Encoded (address rewardToken, bool equalSplit)
     * @param state Coordination state with participants
     */
    function _executeTeamStake(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData,
        CoordinationState storage state
    ) internal returns (bool, bytes memory) {

        // Decode parameters
        (address rewardToken, bool equalSplit) = abi.decode(executionData, (address, bool));

        // Calculate total staked from all contributions
        uint256 totalStaked = 0;
        for (uint256 i = 0; i < state.participants.length; i++) {
            totalStaked += teamContributions[intentHash][state.participants[i]];
        }

        if (totalStaked == 0) revert InvalidEntryFee();

        // Calculate reward share per member (for equal distribution)
        uint256 rewardShare = equalSplit ? totalStaked / state.participants.length : 0;

        // Store team stake data
        teamStakes[intentHash] = TeamStake({
            intentHash: intentHash,
            totalStaked: totalStaked,
            rewardShare: rewardShare,
            active: true,
            rewardToken: rewardToken
        });

        emit TeamStakeCreated(
            intentHash,
            state.participants.length,
            totalStaked,
            rewardToken
        );

        return (true, abi.encode(totalStaked, rewardShare));
    }

    /**
     * @notice Record contribution to team stake before execution
     * @dev Called by team members to commit their stake
     * @param intentHash Team stake intent hash
     * @param amount Amount to contribute
     */
    function contributeToTeamStake(bytes32 intentHash, uint256 amount) external nonReentrant {
        // Transfer tokens from contributor
        (bool xferSuccess, ) = gameToken.call(
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                msg.sender,
                address(this),
                amount
            )
        );

        if (!xferSuccess) revert TransferFailed();

        teamContributions[intentHash][msg.sender] += amount;
    }

    /**
     * @notice Distribute rewards to all team members
     * @param intentHash Team stake intent hash
     * @param totalRewards Total rewards to distribute
     */
    function distributeTeamRewards(
        bytes32 intentHash, 
        uint256 totalRewards
    ) external nonReentrant {
        TeamStake storage stake = teamStakes[intentHash];

        if (!stake.active) revert TournamentNotFound(); // Reusing error

        address[] memory participants = getParticipants(intentHash);
        uint256 perMemberShare = totalRewards / participants.length;

        for (uint256 i = 0; i < participants.length; i++) {
            (bool xferSuccess, ) = stake.rewardToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transfer(address,uint256)")),
                    participants[i],
                    perMemberShare
                )
            );

            if (!xferSuccess) revert TransferFailed();
        }

        emit TeamRewardsDistributed(intentHash, totalRewards, perMemberShare);
    }

    // ============ Battle Execution ============

    /**
     * @notice Execute battle coordination
     * @dev Sets up PvP battle between challenger and defender
     * @param intentHash The coordination intent hash
     * @param payload Coordination payload
     * @param executionData Encoded (address challenger, uint256 wager)
     * @param state Coordination state (should have 2 participants)
     */
    function _executeBattle(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData,
        CoordinationState storage state
    ) internal returns (bool, bytes memory) {

        // Decode battle parameters
        (address challenger, uint256 wager) = abi.decode(executionData, (address, uint256));

        // Battles require exactly 2 participants
        if (state.participants.length != 2) revert InvalidCoordinationType();

        // Find defender (the other participant)
        address defender = state.participants[0] == challenger 
            ? state.participants[1] 
            : state.participants[0];

        // Collect wagers from both players
        // From challenger
        (bool xfer1, ) = gameToken.call(
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                challenger,
                address(this),
                wager
            )
        );
        if (!xfer1) revert TransferFailed();

        // From defender
        (bool xfer2, ) = gameToken.call(
            abi.encodeWithSelector(
                bytes4(keccak256("transferFrom(address,address,uint256)")),
                defender,
                address(this),
                wager
            )
        );
        if (!xfer2) revert TransferFailed();

        // Store battle data
        battles[intentHash] = Battle({
            intentHash: intentHash,
            challenger: challenger,
            defender: defender,
            wager: wager,
            resolved: false,
            winner: address(0)
        });

        emit BattleCreated(intentHash, challenger, defender, wager);

        return (true, abi.encode(challenger, defender, wager * 2)); // Total prize
    }

    /**
     * @notice Resolve battle with winner
     * @param intentHash Battle intent hash
     * @param winnerAddress Winner address (0x0 for draw - returns wagers)
     */
    function resolveBattle(
        bytes32 intentHash, 
        address winnerAddress
    ) external nonReentrant {
        Battle storage battle = battles[intentHash];

        if (battle.intentHash == bytes32(0)) revert BattleNotFound();
        if (battle.resolved) revert BattleAlreadyResolved();

        battle.resolved = true;
        battle.winner = winnerAddress;

        uint256 totalPrize = battle.wager * 2;

        if (winnerAddress == address(0)) {
            // Draw - return wagers to both players
            (bool xfer1, ) = gameToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transfer(address,uint256)")),
                    battle.challenger,
                    battle.wager
                )
            );
            (bool xfer2, ) = gameToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transfer(address,uint256)")),
                    battle.defender,
                    battle.wager
                )
            );
            if (!xfer1 || !xfer2) revert TransferFailed();
        } else {
            // Winner takes all
            (bool xfer, ) = gameToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transfer(address,uint256)")),
                    winnerAddress,
                    totalPrize
                )
            );
            if (!xfer) revert TransferFailed();

            emit BattleResolved(intentHash, winnerAddress, totalPrize);
        }
    }

    // ============ Loot Share Execution ============

    /**
     * @notice Execute loot share coordination
     * @dev Sets up fair distribution of loot among participants
     * @param intentHash The coordination intent hash
     * @param payload Coordination payload containing item data
     * @param executionData Encoded (bytes32[] itemIds, uint8 distributionType)
     * @param state Coordination state with participants
     */
    function _executeLootShare(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData,
        CoordinationState storage state
    ) internal returns (bool, bytes memory) {

        // Decode loot parameters
        (bytes32[] memory itemIds, uint8 distributionType) = abi.decode(
            executionData, 
            (bytes32[], uint8)
        );

        if (itemIds.length == 0) revert InvalidCoordinationType();
        if (distributionType > 1) revert InvalidCoordinationType(); // 0 or 1 only

        // Store loot distribution data
        lootDistributions[intentHash] = LootDistribution({
            intentHash: intentHash,
            itemIds: itemIds,
            distributed: false,
            distributionType: distributionType
        });

        emit LootDistributed(intentHash, itemIds.length, distributionType);

        return (true, abi.encode(itemIds.length, state.participants.length));
    }

    /**
     * @notice Claim loot items for caller
     * @param intentHash Loot distribution intent hash
     * @param itemIndices Indices of items to claim
     */
    function claimLoot(
        bytes32 intentHash, 
        uint256[] calldata itemIndices
    ) external nonReentrant returns (bytes32[] memory claimedItems) {
        LootDistribution storage dist = lootDistributions[intentHash];

        if (dist.distributed) revert LootAlreadyDistributed();
        if (hasClaimedLoot[intentHash][msg.sender]) revert PlayerAlreadyEntered();

        address[] memory participants = getParticipants(intentHash);

        // Verify caller is participant
        (bool isParticipant, uint256 participantIndex) = _binarySearch(participants, msg.sender);
        if (!isParticipant) revert NotAuthorized();

        claimedItems = new bytes32[](itemIndices.length);

        if (dist.distributionType == 0) {
            // Equal distribution - each participant gets same number of items
            uint256 itemsPerPlayer = dist.itemIds.length / participants.length;
            uint256 startIdx = participantIndex * itemsPerPlayer;

            for (uint256 i = 0; i < itemIndices.length; i++) {
                uint256 itemIdx = startIdx + itemIndices[i];
                if (itemIdx >= startIdx + itemsPerPlayer) revert NotAuthorized();
                claimedItems[i] = dist.itemIds[itemIdx];
            }
        } else {
            // Proportional - could be based on contribution, random, etc.
            // For simplicity, first-come-first-served within allowed indices
            for (uint256 i = 0; i < itemIndices.length; i++) {
                if (itemIndices[i] >= dist.itemIds.length) revert NotAuthorized();
                claimedItems[i] = dist.itemIds[itemIndices[i]];
            }
        }

        hasClaimedLoot[intentHash][msg.sender] = true;

        return claimedItems;
    }

    // ============ Lobby Execution ============

    /**
     * @notice Execute lobby coordination
     * @dev Simple lobby creation - returns immediately for off-chain game coordination
     * @param intentHash The coordination intent hash
     * @param payload Coordination payload
     * @param executionData Encoded (uint256 gameMode, bytes32 mapId)
     * @param state Coordination state with participants
     */
    function _executeLobby(
        bytes32 intentHash,
        CoordinationPayload calldata payload,
        bytes calldata executionData,
        CoordinationState storage state
    ) internal view returns (bool, bytes memory) {

        // Decode lobby parameters (used off-chain)
        (uint256 gameMode, bytes32 mapId) = abi.decode(executionData, (uint256, bytes32));

        // Lobby is primarily an off-chain coordination signal
        // Return data for game servers to use
        return (true, abi.encode(gameMode, mapId, state.participants.length));
    }

    // ============ View Functions ============

    /**
     * @notice Get participants for a coordination
     * @param intentHash Coordination intent hash
     * @return participants Array of participant addresses
     */
    function getParticipants(bytes32 intentHash) public view returns (address[] memory participants) {
        CoordinationState storage st = states[intentHash];
        return st.participants;
    }

    /**
     * @notice Check if tournament is active
     * @param intentHash Tournament intent hash
     * @return active True if tournament exists and not completed
     */
    function isTournamentActive(bytes32 intentHash) external view returns (bool active) {
        Tournament storage t = tournaments[intentHash];
        return t.intentHash != bytes32(0) && !t.completed;
    }

    /**
     * @notice Get tournament details
     * @param intentHash Tournament intent hash
     * @return entryFee Entry fee per player
     * @return prizePool Total prize pool
     * @return playerCount Number of registered players
     * @return completed Whether tournament is finished
     */
    function getTournamentDetails(bytes32 intentHash) external view returns (
        uint256 entryFee,
        uint256 prizePool,
        uint256 playerCount,
        bool completed
    ) {
        Tournament storage t = tournaments[intentHash];
        return (t.entryFee, t.prizePool, getParticipants(intentHash).length, t.completed);
    }
}

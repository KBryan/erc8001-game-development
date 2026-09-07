// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AgentCoordination} from "../src/AgentCoordination.sol";
import {GameCoordination} from "../src/GameCoordination.sol";
import {MultiplayerGameLobby} from "../src/MultiplayerGameLobby.sol";
import {AgentIntent, AcceptanceAttestation, CoordinationPayload, Status} from "../src/IAgentCoordination.sol";

/**
 * @title MockGameToken
 * @notice Minimal ERC-20 for testing entry-fee collection and payout
 */
contract MockGameToken {
    string public constant name = "Mock Game Token";
    string public constant symbol = "MGT";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @title MultiplayerLobbyTest
 * @notice Full ERC-8001 integration test for MultiplayerGameLobby
 * @dev Exercises the complete happy path with REAL EIP-712 signatures:
 *      createLobby (proposeCoordination) → joinLobby x4 (acceptCoordination)
 *      → Ready → startGame (executeCoordination) → declareWinner (pot payout),
 *      plus host cancellation with refunds before start.
 *
 *      EIP-712 digests are built exactly as AgentCoordination computes them
 *      (same typehashes, same struct encodings, same 0x1901 prefix) rather
 *      than by calling the contract's hash helpers, so the test doubles as a
 *      reference for off-chain signers.
 */
contract MultiplayerLobbyTest is Test {

    // Replicated from AgentCoordination (must stay byte-identical)
    bytes32 constant AGENT_INTENT_TYPEHASH = keccak256(
        "AgentIntent(bytes32 payloadHash,uint64 expiry,uint64 nonce,address agentId,bytes32 coordinationType,uint256 coordinationValue,address[] participants)"
    );
    bytes32 constant ACCEPTANCE_TYPEHASH = keccak256(
        "AcceptanceAttestation(bytes32 intentHash,address participant,uint64 nonce,uint64 expiry,bytes32 conditionsHash)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256 constant PLAYER_COUNT = 4;
    uint256 constant ENTRY_FEE = 1 ether;
    uint256 constant GAME_MODE = 3;
    bytes32 constant MAP_ID = keccak256("de_dust2");

    GameCoordination coordination;
    MultiplayerGameLobby lobby;
    MockGameToken token;

    bytes32 domainSeparator;

    // Sorted ascending by address; index 0 is the host (createLobby requires
    // the caller to be participants[0], and ERC-8001 requires a sorted roster)
    address[] players;
    uint256[] playerKeys;
    address host;
    uint256 hostKey;

    function setUp() public {
        token = new MockGameToken();
        coordination = new GameCoordination(address(token));
        lobby = new MultiplayerGameLobby(address(coordination), address(token));

        // Replicate the domain separator AgentCoordination builds in its constructor
        domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("ERC-8001-Core")),
                keccak256(bytes("1")),
                block.chainid,
                address(coordination)
            )
        );
        assertEq(domainSeparator, coordination.getDomainSeparator(), "domain separator replication");

        // Create keypairs and sort ascending (ERC-8001 canonical participant order)
        for (uint256 i = 0; i < PLAYER_COUNT; i++) {
            (address addr, uint256 key) = makeAddrAndKey(string(abi.encodePacked("player", vm.toString(i))));
            players.push(addr);
            playerKeys.push(key);
        }
        for (uint256 i = 1; i < PLAYER_COUNT; i++) {
            for (uint256 j = i; j > 0 && players[j - 1] > players[j]; j--) {
                (players[j - 1], players[j]) = (players[j], players[j - 1]);
                (playerKeys[j - 1], playerKeys[j]) = (playerKeys[j], playerKeys[j - 1]);
            }
        }
        host = players[0];
        hostKey = playerKeys[0];

        // Host approves the lobby as their relayer on the coordination
        // contract — required once before the lobby may submit proposals on
        // the host's behalf (proposeCoordination rejects unapproved relayers)
        vm.prank(host);
        coordination.approveRelayer(address(lobby), true);

        // Fund every player and approve the lobby for entry fees (fees are
        // pulled from the attestation's participant, so each player approves)
        for (uint256 i = 0; i < PLAYER_COUNT; i++) {
            token.mint(players[i], 100 ether);
            vm.prank(players[i]);
            token.approve(address(lobby), type(uint256).max);
        }
    }

    // ============ EIP-712 Digest Builders (mirroring AgentCoordination) ============

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _payloadHash(CoordinationPayload memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(p.version, p.coordinationType, p.coordinationData, p.conditionsHash, p.timestamp, p.metadata)
        );
    }

    function _intentHash(AgentIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                AGENT_INTENT_TYPEHASH,
                intent.payloadHash,
                intent.expiry,
                intent.nonce,
                intent.agentId,
                intent.coordinationType,
                intent.coordinationValue,
                keccak256(abi.encodePacked(intent.participants))
            )
        );
    }

    function _acceptanceHash(AcceptanceAttestation memory att) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(ACCEPTANCE_TYPEHASH, att.intentHash, att.participant, att.nonce, att.expiry, att.conditionsHash)
        );
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============ Scenario Builders ============

    function _buildLobbyProposal()
        internal
        view
        returns (AgentIntent memory intent, bytes memory intentSig, CoordinationPayload memory payload)
    {
        payload = CoordinationPayload({
            version: 1,
            coordinationType: coordination.COORDINATION_LOBBY(),
            coordinationData: abi.encode(GAME_MODE, MAP_ID),
            conditionsHash: bytes32(0),
            timestamp: uint64(block.timestamp),
            metadata: ""
        });

        intent = AgentIntent({
            payloadHash: _payloadHash(payload),
            expiry: uint64(block.timestamp + 30 minutes),
            nonce: 1,
            agentId: host,
            coordinationType: coordination.COORDINATION_LOBBY(),
            coordinationValue: ENTRY_FEE,
            participants: players
        });

        intentSig = _sign(hostKey, _digest(_intentHash(intent)));
    }

    function _buildAttestation(uint256 index, bytes32 lobbyId)
        internal
        view
        returns (AcceptanceAttestation memory att)
    {
        att = AcceptanceAttestation({
            intentHash: lobbyId,
            participant: players[index],
            nonce: 1,
            expiry: uint64(block.timestamp + 30 minutes),
            conditionsHash: bytes32(0),
            signature: ""
        });
        att.signature = _sign(playerKeys[index], _digest(_acceptanceHash(att)));
    }

    function _joinAs(uint256 index, bytes32 lobbyId) internal {
        AcceptanceAttestation memory att = _buildAttestation(index, lobbyId);

        vm.prank(players[index]);
        lobby.joinLobby(lobbyId, att);
    }

    function _createLobby() internal returns (bytes32 lobbyId, CoordinationPayload memory payload) {
        AgentIntent memory intent;
        bytes memory intentSig;
        (intent, intentSig, payload) = _buildLobbyProposal();

        vm.prank(host);
        lobbyId = lobby.createLobby(intent, intentSig, payload, GAME_MODE, MAP_ID);
    }

    // ============ Tests ============

    /// @notice Full happy path: create → all join → Ready → start → winner paid
    function test_FullHappyPath() public {
        (bytes32 lobbyId, CoordinationPayload memory payload) = _createLobby();

        // Fresh lobby: nobody (host included) has accepted yet
        MultiplayerGameLobby.GameLobby memory created = lobby.getLobby(lobbyId);
        assertEq(created.acceptedCount, 0, "no fake host auto-accept");
        assertEq(created.minPlayers, PLAYER_COUNT, "ready requires the full roster");
        assertEq(uint8(created.status), uint8(MultiplayerGameLobby.LobbyStatus.Created));

        // Starting before everyone accepted must fail
        vm.expectRevert(MultiplayerGameLobby.LobbyNotReady.selector);
        lobby.startGame(lobbyId, payload, abi.encode(GAME_MODE, MAP_ID));

        // Everyone joins with a real signed attestation — the host too
        for (uint256 i = 0; i < PLAYER_COUNT; i++) {
            _joinAs(i, lobbyId);
            assertTrue(lobby.hasPlayerAccepted(lobbyId, players[i]));
        }

        // Lobby Ready exactly when the ERC-8001 coordination is Ready
        MultiplayerGameLobby.GameLobby memory ready = lobby.getLobby(lobbyId);
        assertEq(ready.acceptedCount, PLAYER_COUNT);
        assertEq(uint8(ready.status), uint8(MultiplayerGameLobby.LobbyStatus.Ready));
        (Status coordStatus,,,) = lobby.getCoordinationStatus(lobbyId);
        assertEq(uint8(coordStatus), uint8(Status.Ready));

        // All entry fees are held by the lobby
        assertEq(token.balanceOf(address(lobby)), ENTRY_FEE * PLAYER_COUNT);

        // Anyone can start the game once Ready
        lobby.startGame(lobbyId, payload, abi.encode(GAME_MODE, MAP_ID));
        assertEq(uint8(lobby.getLobby(lobbyId).status), uint8(MultiplayerGameLobby.LobbyStatus.Active));
        (coordStatus,,,) = lobby.getCoordinationStatus(lobbyId);
        assertEq(uint8(coordStatus), uint8(Status.Executed));

        // Host declares the winner; pot = entryFee x accepted players
        address winner = players[2];
        uint256 balanceBefore = token.balanceOf(winner);

        vm.prank(host);
        lobby.declareWinner(lobbyId, winner);

        assertEq(token.balanceOf(winner) - balanceBefore, ENTRY_FEE * PLAYER_COUNT, "winner receives full pot");
        assertEq(token.balanceOf(address(lobby)), 0, "no fees stranded in the lobby");
        assertEq(lobby.lobbyWinner(lobbyId), winner);
        assertEq(uint8(lobby.getLobby(lobbyId).status), uint8(MultiplayerGameLobby.LobbyStatus.Finished));

        // Pot pays out exactly once
        vm.prank(host);
        vm.expectRevert(MultiplayerGameLobby.PotAlreadyPaid.selector);
        lobby.declareWinner(lobbyId, winner);
    }

    /// @notice Host can cancel pre-start and every joined player is refunded
    function test_HostCancelRefundsPlayers() public {
        (bytes32 lobbyId,) = _createLobby();

        // Host and one player join (and pay)
        _joinAs(0, lobbyId);
        _joinAs(1, lobbyId);
        assertEq(token.balanceOf(address(lobby)), ENTRY_FEE * 2);

        uint256 hostBefore = token.balanceOf(players[0]);
        uint256 joinedBefore = token.balanceOf(players[1]);
        uint256 outsiderBefore = token.balanceOf(players[2]);

        // Host cancels through the lobby; the lobby relays the cancellation to
        // AgentCoordination as the submitting contract
        vm.prank(host);
        lobby.cancelLobby(lobbyId, "host changed plans");

        // Both payers refunded, non-joiner untouched, lobby holds nothing
        assertEq(token.balanceOf(players[0]) - hostBefore, ENTRY_FEE, "host refunded");
        assertEq(token.balanceOf(players[1]) - joinedBefore, ENTRY_FEE, "player refunded");
        assertEq(token.balanceOf(players[2]), outsiderBefore, "non-joiner gets nothing");
        assertEq(token.balanceOf(address(lobby)), 0);

        // Both layers agree the coordination is over
        assertEq(uint8(lobby.getLobby(lobbyId).status), uint8(MultiplayerGameLobby.LobbyStatus.Cancelled));
        (Status coordStatus,,,) = lobby.getCoordinationStatus(lobbyId);
        assertEq(uint8(coordStatus), uint8(Status.Cancelled));
    }

    /// @notice A stranger can neither cancel someone else's lobby nor declare a winner
    function test_StrangerCannotCancelOrDeclare() public {
        (bytes32 lobbyId,) = _createLobby();
        _joinAs(0, lobbyId);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(MultiplayerGameLobby.NotHost.selector);
        lobby.cancelLobby(lobbyId, "gimme");

        vm.prank(stranger);
        vm.expectRevert(MultiplayerGameLobby.NotHost.selector);
        lobby.declareWinner(lobbyId, stranger);
    }

    /// @notice Gas measurement for the book: proposeCoordination via
    ///         createLobby and one acceptCoordination via joinLobby, 4 players
    function test_GasMeasurement() public {
        AgentIntent memory intent;
        bytes memory intentSig;
        CoordinationPayload memory payload;
        (intent, intentSig, payload) = _buildLobbyProposal();

        vm.prank(host);
        uint256 gasBefore = gasleft();
        bytes32 lobbyId = lobby.createLobby(intent, intentSig, payload, GAME_MODE, MAP_ID);
        uint256 createLobbyGas = gasBefore - gasleft();

        AcceptanceAttestation memory att = AcceptanceAttestation({
            intentHash: lobbyId,
            participant: players[1],
            nonce: 1,
            expiry: uint64(block.timestamp + 30 minutes),
            conditionsHash: bytes32(0),
            signature: ""
        });
        att.signature = _sign(playerKeys[1], _digest(_acceptanceHash(att)));

        vm.prank(players[1]);
        gasBefore = gasleft();
        lobby.joinLobby(lobbyId, att);
        uint256 joinLobbyGas = gasBefore - gasleft();

        emit log_named_uint("createLobby total gas (4 players)", createLobbyGas);
        emit log_named_uint("joinLobby total gas (single accept)", joinLobbyGas);
        // Inner proposeCoordination/acceptCoordination gas comes from
        // `forge test --match-path test/MultiplayerLobbyTest.sol --gas-report`
    }

    // ============ Regression Tests (permissionless-core hardening) ============

    /// @notice proposeCoordination relayed by an address the proposer never
    ///         approved must revert — a hostile submitter can no longer
    ///         front-run a signed intent to gain the submitter role
    function test_UnapprovedRelayerCannotPropose() public {
        // Revoke the approval granted in setUp, then relay through the lobby
        vm.prank(host);
        coordination.approveRelayer(address(lobby), false);

        (AgentIntent memory intent, bytes memory intentSig, CoordinationPayload memory payload) =
            _buildLobbyProposal();

        vm.prank(host);
        vm.expectRevert(AgentCoordination.NotApprovedRelayer.selector);
        lobby.createLobby(intent, intentSig, payload, GAME_MODE, MAP_ID);

        // An unrelated EOA relaying the signed intent directly is refused too
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(AgentCoordination.NotApprovedRelayer.selector);
        coordination.proposeCoordination(intent, intentSig, payload);
    }

    /// @notice executeCoordination is submitter/proposer-gated: a stranger
    ///         calling the coordination contract directly can no longer strand
    ///         the lobby's wrapper state
    function test_StrangerCannotExecuteDirectly() public {
        (bytes32 lobbyId, CoordinationPayload memory payload) = _createLobby();
        for (uint256 i = 0; i < PLAYER_COUNT; i++) {
            _joinAs(i, lobbyId);
        }

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(AgentCoordination.NotProposerOrSubmitter.selector);
        coordination.executeCoordination(lobbyId, payload, abi.encode(GAME_MODE, MAP_ID));

        // The lobby (the submitter) still executes fine
        lobby.startGame(lobbyId, payload, abi.encode(GAME_MODE, MAP_ID));
        (Status coordStatus,,,) = lobby.getCoordinationStatus(lobbyId);
        assertEq(uint8(coordStatus), uint8(Status.Executed));
    }

    /// @notice A relayed joinLobby charges the attestation's participant, not
    ///         the relayer submitting the transaction
    function test_RelayedJoinChargesParticipantNotRelayer() public {
        (bytes32 lobbyId,) = _createLobby();

        address relayer = makeAddr("relayer");
        token.mint(relayer, 100 ether);
        vm.prank(relayer);
        token.approve(address(lobby), type(uint256).max);

        uint256 participantBefore = token.balanceOf(players[1]);
        uint256 relayerBefore = token.balanceOf(relayer);

        AcceptanceAttestation memory att = _buildAttestation(1, lobbyId);
        vm.prank(relayer);
        lobby.joinLobby(lobbyId, att);

        assertEq(participantBefore - token.balanceOf(players[1]), ENTRY_FEE, "participant pays the fee");
        assertEq(token.balanceOf(relayer), relayerBefore, "relayer pays nothing");
        assertTrue(lobby.feePaid(lobbyId, players[1]));
        assertTrue(lobby.hasPlayerAccepted(lobbyId, players[1]));
    }

    /// @notice A participant who accepted directly on the coordination
    ///         contract still pays through joinLobby, and startGame works even
    ///         though the last acceptance never passed through the lobby
    function test_DirectAcceptorStillPaysAndGameStarts() public {
        (bytes32 lobbyId, CoordinationPayload memory payload) = _createLobby();

        // Three players join through the lobby
        for (uint256 i = 0; i < 3; i++) {
            _joinAs(i, lobbyId);
        }

        // The fourth accepts DIRECTLY on the coordination contract,
        // bypassing the lobby's fee collection; coordination flips to Ready
        AcceptanceAttestation memory att = _buildAttestation(3, lobbyId);
        vm.prank(players[3]);
        coordination.acceptCoordination(lobbyId, att);
        (Status coordStatus,,,) = lobby.getCoordinationStatus(lobbyId);
        assertEq(uint8(coordStatus), uint8(Status.Ready));

        // The game cannot start on an unpaid seat
        vm.expectRevert(MultiplayerGameLobby.LobbyNotReady.selector);
        lobby.startGame(lobbyId, payload, abi.encode(GAME_MODE, MAP_ID));

        // joinLobby heals the hole: acceptance skipped, fee still collected
        uint256 before = token.balanceOf(players[3]);
        vm.prank(players[3]);
        lobby.joinLobby(lobbyId, att);
        assertEq(before - token.balanceOf(players[3]), ENTRY_FEE, "direct acceptor still pays");
        assertEq(uint8(lobby.getLobby(lobbyId).status), uint8(MultiplayerGameLobby.LobbyStatus.Ready));

        // Full pot is escrowed and the game starts
        assertEq(token.balanceOf(address(lobby)), ENTRY_FEE * PLAYER_COUNT);
        lobby.startGame(lobbyId, payload, abi.encode(GAME_MODE, MAP_ID));
        assertEq(uint8(lobby.getLobby(lobbyId).status), uint8(MultiplayerGameLobby.LobbyStatus.Active));
    }
}

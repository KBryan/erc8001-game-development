// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AgentCoordination} from "../src/AgentCoordination.sol";
import {GameCoordination} from "../src/GameCoordination.sol";
import {ERC8001LootBox} from "../src/ERC8001LootBox.sol";
import {AgentIntent, AcceptanceAttestation, CoordinationPayload, Status} from "../src/IAgentCoordination.sol";

/**
 * @title MockFeeToken
 * @notice Minimal ERC-20 for testing open-fee collection and refunds
 */
contract MockFeeToken {
    string public constant name = "Mock Fee Token";
    string public constant symbol = "MFT";
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
 * @title MockEntropy
 * @notice Minimal Pyth Entropy stand-in: hands out sequence numbers and
 *         records requests; the test triggers the callback itself, pranked as
 *         this contract, exactly as the real oracle would call in
 */
contract MockEntropy {
    uint128 public constant FEE = 0.01 ether;
    uint64 public nextSequence = 1;
    bytes32 public lastUserRandomness;

    function getRequestFee() external pure returns (uint128) {
        return FEE;
    }

    function requestWithCallback(bytes32 userRandomness) external payable returns (uint64 sequenceNumber) {
        require(msg.value >= FEE, "fee");
        lastUserRandomness = userRandomness;
        sequenceNumber = nextSequence++;
    }
}

/**
 * @title MockLootNFT
 * @notice Records mints so the test can assert item distribution
 */
contract MockLootNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bytes32) public itemOf;
    uint256 public mintCount;

    function mint(address to, uint256 tokenId, bytes32 itemHash) external {
        ownerOf[tokenId] = to;
        itemOf[tokenId] = itemHash;
        mintCount++;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return ownerOf[tokenId] != address(0);
    }
}

/**
 * @title ERC8001LootBoxTest
 * @notice Full ERC-8001 integration test for ERC8001LootBox with REAL EIP-712
 *         signatures and a mock Pyth Entropy oracle:
 *         createLootBox (proposeCoordination) → agreeToOpen x3 (fees pulled
 *         from each participant) → openLootBox (executeCoordination + entropy
 *         request) → entropyCallback (items distributed, organizer paid
 *         openFee x paid participants), plus organizer cancellation refunding
 *         only participants who actually paid.
 */
contract ERC8001LootBoxTest is Test {

    // Replicated from AgentCoordination (must stay byte-identical)
    bytes32 constant AGENT_INTENT_TYPEHASH = keccak256(
        "AgentIntent(bytes32 payloadHash,uint64 expiry,uint64 nonce,address agentId,bytes32 coordinationType,uint256 coordinationValue,address[] participants)"
    );
    bytes32 constant ACCEPTANCE_TYPEHASH = keccak256(
        "AcceptanceAttestation(bytes32 intentHash,address participant,uint64 nonce,uint64 expiry,bytes32 conditionsHash)"
    );

    uint256 constant PARTICIPANT_COUNT = 3;
    uint256 constant OPEN_FEE = 2 ether;

    GameCoordination coordination;
    ERC8001LootBox lootBox;
    MockFeeToken token;
    MockEntropy entropy;
    MockLootNFT nft;

    bytes32 domainSeparator;

    // Sorted ascending; index 0 is the organizer
    address[] participants;
    uint256[] participantKeys;
    address organizer;
    uint256 organizerKey;

    bytes32[] itemHashes;

    function setUp() public {
        token = new MockFeeToken();
        coordination = new GameCoordination(address(token));
        entropy = new MockEntropy();
        lootBox = new ERC8001LootBox(address(coordination), address(entropy), address(token));
        nft = new MockLootNFT();
        lootBox.setLootNFT(address(nft));

        domainSeparator = coordination.getDomainSeparator();

        for (uint256 i = 0; i < PARTICIPANT_COUNT; i++) {
            (address addr, uint256 key) = makeAddrAndKey(string(abi.encodePacked("opener", vm.toString(i))));
            participants.push(addr);
            participantKeys.push(key);
        }
        for (uint256 i = 1; i < PARTICIPANT_COUNT; i++) {
            for (uint256 j = i; j > 0 && participants[j - 1] > participants[j]; j--) {
                (participants[j - 1], participants[j]) = (participants[j], participants[j - 1]);
                (participantKeys[j - 1], participantKeys[j]) = (participantKeys[j], participantKeys[j - 1]);
            }
        }
        organizer = participants[0];
        organizerKey = participantKeys[0];

        // Organizer approves the loot box as their relayer — required once
        // before the box may submit proposals on the organizer's behalf
        vm.prank(organizer);
        coordination.approveRelayer(address(lootBox), true);

        // Fund fees and ETH for the entropy request
        for (uint256 i = 0; i < PARTICIPANT_COUNT; i++) {
            token.mint(participants[i], 100 ether);
            vm.prank(participants[i]);
            token.approve(address(lootBox), type(uint256).max);
            vm.deal(participants[i], 1 ether);
        }

        for (uint256 i = 0; i < 5; i++) {
            itemHashes.push(keccak256(abi.encodePacked("item", i)));
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

    function _createLootBox() internal returns (bytes32 boxId, CoordinationPayload memory payload) {
        payload = CoordinationPayload({
            version: 1,
            coordinationType: lootBox.LOOT_BOX_TYPE(),
            coordinationData: abi.encode(itemHashes.length),
            conditionsHash: bytes32(0),
            timestamp: uint64(block.timestamp),
            metadata: ""
        });

        AgentIntent memory intent = AgentIntent({
            payloadHash: _payloadHash(payload),
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1,
            agentId: organizer,
            coordinationType: lootBox.LOOT_BOX_TYPE(),
            coordinationValue: OPEN_FEE,
            participants: participants
        });

        bytes memory sig = _sign(organizerKey, _digest(_intentHash(intent)));

        vm.prank(organizer);
        boxId = lootBox.createLootBox(intent, sig, payload, itemHashes, OPEN_FEE);
    }

    function _agreeAs(uint256 index, bytes32 boxId) internal {
        AcceptanceAttestation memory att = AcceptanceAttestation({
            intentHash: boxId,
            participant: participants[index],
            nonce: 1,
            expiry: uint64(block.timestamp + 1 days),
            conditionsHash: bytes32(0),
            signature: ""
        });
        att.signature = _sign(participantKeys[index], _digest(_acceptanceHash(att)));

        vm.prank(participants[index]);
        lootBox.agreeToOpen(boxId, att);
    }

    // ============ Tests ============

    /// @notice Full happy path: create → all agree (fees escrowed) → open
    ///         (entropy requested) → callback distributes items and pays the
    ///         organizer exactly openFee x paid participants
    function test_FullHappyPath() public {
        (bytes32 boxId, CoordinationPayload memory payload) = _createLootBox();

        // Opening before everyone agreed must fail
        vm.prank(organizer);
        vm.expectRevert(ERC8001LootBox.NotAllAgreed.selector);
        lootBox.openLootBox{value: 0.01 ether}(boxId, payload, keccak256("seed"));

        // Everyone agrees and pays
        for (uint256 i = 0; i < PARTICIPANT_COUNT; i++) {
            _agreeAs(i, boxId);
            assertTrue(lootBox.feePaid(boxId, participants[i]));
        }
        assertEq(token.balanceOf(address(lootBox)), OPEN_FEE * PARTICIPANT_COUNT, "fees escrowed");
        assertEq(lootBox.paidCount(boxId), PARTICIPANT_COUNT);

        // A participant opens the box, paying the entropy fee in ETH
        vm.prank(participants[1]);
        uint64 seq = lootBox.openLootBox{value: 0.01 ether}(boxId, payload, keccak256("seed"));
        assertEq(seq, 1);
        (Status coordStatus,,,,) = coordination.getCoordinationStatus(boxId);
        assertEq(uint8(coordStatus), uint8(Status.Executed), "coordination executed");

        // The oracle calls back with randomness: items minted, organizer paid
        uint256 organizerBefore = token.balanceOf(organizer);
        vm.prank(address(entropy));
        lootBox.entropyCallback(seq, keccak256("verifiable randomness"));

        assertEq(
            token.balanceOf(organizer) - organizerBefore,
            OPEN_FEE * PARTICIPANT_COUNT,
            "organizer receives openFee x paid participants"
        );

        ERC8001LootBox.LootOutcome memory outcome = lootBox.getLootOutcome(boxId);
        assertEq(outcome.items.length, PARTICIPANT_COUNT, "one item per participant");
        assertEq(nft.mintCount(), PARTICIPANT_COUNT, "every item minted as an NFT");
        for (uint256 i = 0; i < outcome.items.length; i++) {
            assertEq(nft.ownerOf(outcome.items[i].tokenId), outcome.items[i].recipient);
        }

        assertTrue(lootBox.getLootBox(boxId).opened);

        // Callback cannot run twice
        vm.prank(address(entropy));
        vm.expectRevert(ERC8001LootBox.LootBoxNotFound.selector);
        lootBox.entropyCallback(seq, keccak256("again"));
    }

    /// @notice Cancellation refunds exactly the participants recorded as paid
    function test_CancelRefundsOnlyPayers() public {
        (bytes32 boxId,) = _createLootBox();

        // Two of three agree and pay
        _agreeAs(0, boxId);
        _agreeAs(1, boxId);
        assertEq(token.balanceOf(address(lootBox)), OPEN_FEE * 2);

        uint256 payer0Before = token.balanceOf(participants[0]);
        uint256 payer1Before = token.balanceOf(participants[1]);
        uint256 nonPayerBefore = token.balanceOf(participants[2]);

        vm.prank(organizer);
        lootBox.cancelLootBox(boxId, "changed plans");

        assertEq(token.balanceOf(participants[0]) - payer0Before, OPEN_FEE, "payer refunded");
        assertEq(token.balanceOf(participants[1]) - payer1Before, OPEN_FEE, "payer refunded");
        assertEq(token.balanceOf(participants[2]), nonPayerBefore, "non-payer gets nothing");
        assertEq(token.balanceOf(address(lootBox)), 0, "no fees stranded");

        assertTrue(lootBox.getLootBox(boxId).cancelled);
        (Status coordStatus,,,,) = coordination.getCoordinationStatus(boxId);
        assertEq(uint8(coordStatus), uint8(Status.Cancelled));
    }

    /// @notice A relayed agreeToOpen charges the attestation's participant,
    ///         not the relayer submitting the transaction
    function test_RelayedAgreementChargesParticipant() public {
        (bytes32 boxId,) = _createLootBox();

        address relayer = makeAddr("relayer");
        token.mint(relayer, 100 ether);
        vm.prank(relayer);
        token.approve(address(lootBox), type(uint256).max);

        AcceptanceAttestation memory att = AcceptanceAttestation({
            intentHash: boxId,
            participant: participants[1],
            nonce: 1,
            expiry: uint64(block.timestamp + 1 days),
            conditionsHash: bytes32(0),
            signature: ""
        });
        att.signature = _sign(participantKeys[1], _digest(_acceptanceHash(att)));

        uint256 participantBefore = token.balanceOf(participants[1]);
        uint256 relayerBefore = token.balanceOf(relayer);

        vm.prank(relayer);
        lootBox.agreeToOpen(boxId, att);

        assertEq(participantBefore - token.balanceOf(participants[1]), OPEN_FEE, "participant pays");
        assertEq(token.balanceOf(relayer), relayerBefore, "relayer pays nothing");
        assertTrue(lootBox.hasAgreed(boxId, participants[1]));
    }
}

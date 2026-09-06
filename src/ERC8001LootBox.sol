// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AgentCoordination} from "./AgentCoordination.sol";
import {AgentIntent, AcceptanceAttestation, CoordinationPayload, Status} from "./IAgentCoordination.sol";
import {GameCoordination} from "./GameCoordination.sol";

/**
 * @title IPythEntropy
 * @notice Interface for Pyth Entropy (verifiable randomness)
 * @dev Used for generating verifiable random numbers for loot box opening
 */
interface IPythEntropy {
    /// @notice Request randomness from Pyth
    /// @param userRandomness User-provided randomness
    /// @return sequenceNumber Sequence number for the request
    function requestWithCallback(bytes32 userRandomness) external payable returns (uint64 sequenceNumber);

    /// @notice Get the fee for requesting randomness
    /// @return fee Amount of ETH required
    function getRequestFee() external view returns (uint128 fee);

    /// @notice Callback interface for receiving randomness
    /// @param sequenceNumber Sequence number of the request
    /// @param randomness The generated random value
    function entropyCallback(uint64 sequenceNumber, bytes32 randomness) external;
}

/**
 * @title IERC721Loot
 * @notice Interface for loot NFTs
 */
interface IERC721Loot {
    function mint(address to, uint256 tokenId, bytes32 itemHash) external;
    function exists(uint256 tokenId) external view returns (bool);
}

/**
 * @title ERC8001LootBox
 * @notice Multi-party loot boxes using ERC-8001 coordination and Pyth Entropy
 * @dev Enables group loot opening where all participants must agree before
 *      the random outcome is determined by verifiable Pyth Entropy
 * 
 * ERC-8001 FLOW:
 * 1. Organizer creates loot box intent with participants
 * 2. Call createLootBox() → proposeCoordination() (Status: Proposed)
 * 3. All participants call agreeToOpen() → acceptCoordination()
 * 4. Anyone can openLootBox() → executeCoordination() + Pyth request
 * 5. Pyth callback reveals items based on verifiable randomness
 * 
 * PYTH ENTROPY FLOW:
 * - requestWithCallback() requests randomness (requires ETH fee)
 * - Pyth oracle calls entropyCallback() with random value
 * - Randomness determines loot outcome verifiably
 */
contract ERC8001LootBox {

    // ============ Constants ============

    /// @notice Loot box coordination type
    bytes32 public constant LOOT_BOX_TYPE = keccak256("LOOT_BOX");

    /// @notice Minimum participants for loot box
    uint256 public constant MIN_PARTICIPANTS = 2;

    /// @notice Maximum participants for loot box
    uint256 public constant MAX_PARTICIPANTS = 10;

    /// @notice Maximum items per loot box
    uint256 public constant MAX_ITEMS = 100;

    /// @notice Rarity tiers (common, uncommon, rare, epic, legendary)
    uint8 constant RARITY_COMMON = 0;
    uint8 constant RARITY_UNCOMMON = 1;
    uint8 constant RARITY_RARE = 2;
    uint8 constant RARITY_EPIC = 3;
    uint8 constant RARITY_LEGENDARY = 4;

    // ============ State Structures ============

    /**
     * @notice Loot box configuration
     * @param intentHash Reference to ERC-8001 coordination
     * @param organizer Address that created the loot box
     * @param participants Array of addresses who can open
     * @param itemHashes Hashes of potential items
     * @param openFee Fee to open (distributed or burned)
     * @param opened Whether box has been opened
     * @param cancelled Whether box was cancelled
     * @param randomness Random value from Pyth (0 if not opened)
     * @param sequenceNumber Pyth request sequence number
     * @param createdAt Block timestamp
     */
    struct LootBox {
        bytes32 intentHash;
        address organizer;
        address[] participants;
        bytes32[] itemHashes;
        uint256 openFee;
        bool opened;
        bool cancelled;
        bytes32 randomness;
        uint64 sequenceNumber;
        uint256 createdAt;
    }

    /**
     * @notice Item distribution result
     * @param itemHash Hash of the item
     * @param recipient Address that received the item
     * @param tokenId Minted token ID (0 if not minted)
     * @param rarity Rarity tier of the item
     */
    struct ItemResult {
        bytes32 itemHash;
        address recipient;
        uint256 tokenId;
        uint8 rarity;
    }

    /**
     * @notice Loot box outcome after opening
     * @param boxId Loot box ID
     * @param items Distributed items
     * @param distributedAt Block timestamp
     */
    struct LootOutcome {
        bytes32 boxId;
        ItemResult[] items;
        uint256 distributedAt;
    }

    // ============ State Variables ============

    /// @notice GameCoordination contract for ERC-8001 operations
    GameCoordination public immutable coordination;

    /// @notice Pyth Entropy contract for verifiable randomness
    IPythEntropy public immutable entropy;

    /// @notice Loot NFT contract
    IERC721Loot public lootNFT;

    /// @notice Fee token for opening
    address public immutable feeToken;

    /// @notice Next token ID for minting
    uint256 public nextTokenId;

    /// @notice Loot box by ID
    mapping(bytes32 => LootBox) public lootBoxes;

    /// @notice Loot outcome by box ID
    mapping(bytes32 => LootOutcome) public outcomes;

    /// @notice Pending Pyth requests (sequenceNumber => boxId)
    mapping(uint64 => bytes32) public pendingRequests;

    /// @notice Boxes by organizer
    mapping(address => bytes32[]) public organizerBoxes;

    /// @notice Boxes by participant
    mapping(address => bytes32[]) public participantBoxes;

    // ============ Events ============

    /// @notice Emitted when loot box is created
    event LootBoxCreated(
        bytes32 indexed boxId,
        address indexed organizer,
        uint256 participantCount,
        uint256 itemCount,
        uint256 openFee
    );

    /// @notice Emitted when participant agrees to open
    event ParticipantAgreed(
        bytes32 indexed boxId,
        address indexed participant,
        uint256 agreedCount,
        uint256 requiredCount
    );

    /// @notice Emitted when loot box opening is requested
    event LootBoxOpeningRequested(
        bytes32 indexed boxId,
        uint64 sequenceNumber,
        bytes32 userRandomness
    );

    /// @notice Emitted when loot box is opened
    event LootBoxOpened(
        bytes32 indexed boxId,
        bytes32 randomness,
        uint256 itemCount
    );

    /// @notice Emitted when item is distributed
    event ItemDistributed(
        bytes32 indexed boxId,
        address indexed recipient,
        uint256 tokenId,
        bytes32 itemHash,
        uint8 rarity
    );

    /// @notice Emitted when loot box is cancelled
    event LootBoxCancelled(
        bytes32 indexed boxId,
        address indexed canceller,
        string reason
    );

    /// @notice Emitted when open fee is refunded
    event OpenFeeRefunded(
        bytes32 indexed boxId,
        address indexed participant,
        uint256 amount
    );

    // ============ Errors ============

    error InvalidCoordinationContract();
    error InvalidEntropyContract();
    error InvalidNFTContract();
    error InvalidParticipantCount();
    error InvalidItemCount();
    error InvalidLootBoxType();
    error LootBoxNotFound();
    error LootBoxAlreadyExists();
    error LootBoxAlreadyOpened();
    error LootBoxAlreadyCancelled();
    error NotOrganizer();
    error NotParticipant();
    error AlreadyAgreed();
    error NotAllAgreed();
    error InsufficientEntropyFee();
    error TransferFailed();
    error InvalidRandomness();
    error PendingRequestExists();
    error LootNotRevealed();

    // ============ Modifiers ============

    modifier onlyOrganizer(bytes32 boxId) {
        if (lootBoxes[boxId].organizer != msg.sender) revert NotOrganizer();
        _;
    }

    modifier onlyParticipant(bytes32 boxId) {
        bool isParticipant = false;
        address[] memory parts = lootBoxes[boxId].participants;
        for (uint256 i = 0; i < parts.length; i++) {
            if (parts[i] == msg.sender) {
                isParticipant = true;
                break;
            }
        }
        if (!isParticipant) revert NotParticipant();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize loot box contract
     * @param _coordination GameCoordination contract address
     * @param _entropy Pyth Entropy contract address
     * @param _feeToken Token for opening fees
     */
    constructor(
        address _coordination,
        address _entropy,
        address _feeToken
    ) {
        if (_coordination == address(0)) revert InvalidCoordinationContract();
        if (_entropy == address(0)) revert InvalidEntropyContract();

        coordination = GameCoordination(_coordination);
        entropy = IPythEntropy(_entropy);
        feeToken = _feeToken;
        nextTokenId = 1;
    }

    /**
     * @notice Set the loot NFT contract
     * @dev Can only be called once
     * @param _lootNFT Loot NFT contract address
     */
    function setLootNFT(address _lootNFT) external {
        if (address(lootNFT) != address(0)) revert InvalidNFTContract();
        if (_lootNFT == address(0)) revert InvalidNFTContract();
        lootNFT = IERC721Loot(_lootNFT);
    }

    // ============ Loot Box Creation ============

    /**
     * @notice Create a multi-party loot box
     * @dev All participants must agree to open together
     * @param intent Signed coordination intent
     * @param signature Agent signature
     * @param payload Coordination payload
     * @param itemHashes Hashes of items that could be in the box
     * @param openFee Fee required to open (0 for free)
     * @return boxId The created loot box ID
     * 
     * ERC-8001 FLOW:
     * - proposeCoordination() → Status: Proposed
     * - Participants must accept before opening
     */
    function createLootBox(
        AgentIntent calldata intent,
        bytes calldata signature,
        CoordinationPayload calldata payload,
        bytes32[] calldata itemHashes,
        uint256 openFee
    ) external returns (bytes32 boxId) {
        // Verify coordination type
        if (intent.coordinationType != LOOT_BOX_TYPE) revert InvalidLootBoxType();

        // Validate participant count
        if (intent.participants.length < MIN_PARTICIPANTS) revert InvalidParticipantCount();
        if (intent.participants.length > MAX_PARTICIPANTS) revert InvalidParticipantCount();

        // Validate item count
        if (itemHashes.length == 0) revert InvalidItemCount();
        if (itemHashes.length > MAX_ITEMS) revert InvalidItemCount();

        // Verify organizer is first participant
        if (intent.participants[0] != msg.sender) revert NotOrganizer();

        // Create coordination through ERC-8001
        boxId = coordination.proposeCoordination(intent, signature, payload);

        if (lootBoxes[boxId].intentHash != bytes32(0)) revert LootBoxAlreadyExists();

        // Store loot box data
        lootBoxes[boxId] = LootBox({
            intentHash: boxId,
            organizer: msg.sender,
            participants: intent.participants,
            itemHashes: itemHashes,
            openFee: openFee,
            opened: false,
            cancelled: false,
            randomness: bytes32(0),
            sequenceNumber: 0,
            createdAt: block.timestamp
        });

        // Track for lookup
        organizerBoxes[msg.sender].push(boxId);
        for (uint256 i = 0; i < intent.participants.length; i++) {
            participantBoxes[intent.participants[i]].push(boxId);
        }

        emit LootBoxCreated(
            boxId,
            msg.sender,
            intent.participants.length,
            itemHashes.length,
            openFee
        );
    }

    // ============ Agree to Open ============

    /**
     * @notice Participant agrees to open the loot box
     * @dev Accepts coordination through ERC-8001
     * @param boxId Loot box ID
     * @param attestation Signed acceptance attestation
     * 
     * ERC-8001 FLOW:
     * - acceptCoordination() → adds acceptance
     * - When all accept: Status → Ready
     */
    function agreeToOpen(
        bytes32 boxId,
        AcceptanceAttestation calldata attestation
    ) external onlyParticipant(boxId) {
        LootBox storage box = lootBoxes[boxId];

        if (box.opened) revert LootBoxAlreadyOpened();
        if (box.cancelled) revert LootBoxAlreadyCancelled();
        if (coordination.hasAccepted(boxId, msg.sender)) revert AlreadyAgreed();

        // Collect open fee if required
        if (box.openFee > 0) {
            (bool xferSuccess, ) = feeToken.call(
                abi.encodeWithSelector(
                    bytes4(keccak256("transferFrom(address,address,uint256)")),
                    msg.sender,
                    address(this),
                    box.openFee
                )
            );
            if (!xferSuccess) revert TransferFailed();
        }

        // Accept coordination through ERC-8001
        coordination.acceptCoordination(boxId, attestation);

        // Get updated status
        (,,,,, uint256 acceptedCount, uint256 requiredCount,) = coordination.getCoordinationDetails(boxId);

        emit ParticipantAgreed(boxId, msg.sender, acceptedCount, requiredCount);
    }

    // ============ Open Loot Box ============

    /**
     * @notice Open loot box when all participants agreed
     * @dev Requests entropy from Pyth for verifiable randomness
     * @param boxId Loot box ID
     * @param payload Coordination payload
     * @param userRandomness User-provided randomness for Pyth
     * @return sequenceNumber Pyth request sequence number
     * 
     * ERC-8001 FLOW:
     * - executeCoordination() → Status: Executed
     * - Requests Pyth Entropy for randomness
     * 
     * PYTH FLOW:
     * - requestWithCallback() initiates randomness request
     * - Must pay entropy fee in ETH
     * - Pyth will call entropyCallback() with result
     */
    function openLootBox(
        bytes32 boxId,
        CoordinationPayload calldata payload,
        bytes32 userRandomness
    ) external payable onlyParticipant(boxId) returns (uint64 sequenceNumber) {
        LootBox storage box = lootBoxes[boxId];

        if (box.opened) revert LootBoxAlreadyOpened();
        if (box.cancelled) revert LootBoxAlreadyCancelled();

        // Check all participants agreed
        (,,,,, uint256 acceptedCount, uint256 requiredCount,) = coordination.getCoordinationDetails(boxId);
        if (acceptedCount < requiredCount) revert NotAllAgreed();

        // Get Pyth entropy fee
        uint128 entropyFee = entropy.getRequestFee();
        if (msg.value < entropyFee) revert InsufficientEntropyFee();

        // Execute coordination through ERC-8001
        (bool success, ) = coordination.executeCoordination(boxId, payload, abi.encode(userRandomness));
        if (!success) revert TransferFailed();

        // Request entropy from Pyth
        sequenceNumber = entropy.requestWithCallback{value: msg.value}(userRandomness);

        // Store pending request
        pendingRequests[sequenceNumber] = boxId;
        box.sequenceNumber = sequenceNumber;

        emit LootBoxOpeningRequested(boxId, sequenceNumber, userRandomness);
    }

    /**
     * @notice Pyth Entropy callback - reveals and distributes loot
     * @dev Called by Pyth oracle with verifiable randomness
     * @param sequenceNumber Request sequence number
     * @param randomness Verifiable random value
     */
    function entropyCallback(
        uint64 sequenceNumber,
        bytes32 randomness
    ) external {
        // Verify caller is Pyth Entropy contract
        if (msg.sender != address(entropy)) revert InvalidRandomness();

        bytes32 boxId = pendingRequests[sequenceNumber];
        if (boxId == bytes32(0)) revert LootBoxNotFound();

        LootBox storage box = lootBoxes[boxId];
        if (box.opened) revert LootBoxAlreadyOpened();

        // Mark as opened
        box.opened = true;
        box.randomness = randomness;

        // Distribute loot based on randomness
        ItemResult[] memory items = _distributeLoot(boxId, randomness);

        // Store outcome (structs with dynamic arrays must be copied field by field)
        LootOutcome storage outcome = outcomes[boxId];
        outcome.boxId = boxId;
        outcome.distributedAt = block.timestamp;
        for (uint256 i = 0; i < items.length; i++) {
            outcome.items.push(items[i]);
        }

        // Clear pending request
        delete pendingRequests[sequenceNumber];

        emit LootBoxOpened(boxId, randomness, items.length);
    }

    // ============ Internal Loot Distribution ============

    /**
     * @notice Distribute loot items based on randomness
     * @dev Uses randomness to determine item rarity and recipients
     * @param boxId Loot box ID
     * @param randomness Verifiable random value
     * @return items Array of distributed items
     */
    function _distributeLoot(
        bytes32 boxId,
        bytes32 randomness
    ) internal returns (ItemResult[] memory items) {
        LootBox storage box = lootBoxes[boxId];

        // Determine number of items to distribute (1 per participant minimum)
        uint256 itemCount = box.participants.length;
        items = new ItemResult[](itemCount);

        for (uint256 i = 0; i < itemCount; i++) {
            // Generate unique random for each item
            bytes32 itemRandom = keccak256(abi.encodePacked(randomness, i));

            // Select recipient (round-robin with randomness for fairness)
            address recipient = box.participants[
                uint256(itemRandom) % box.participants.length
            ];

            // Select item based on rarity roll
            (bytes32 itemHash, uint8 rarity) = _selectItem(box.itemHashes, itemRandom);

            // Mint NFT if loot contract is set
            uint256 tokenId = 0;
            if (address(lootNFT) != address(0)) {
                tokenId = nextTokenId++;
                lootNFT.mint(recipient, tokenId, itemHash);
            }

            items[i] = ItemResult({
                itemHash: itemHash,
                recipient: recipient,
                tokenId: tokenId,
                rarity: rarity
            });

            emit ItemDistributed(boxId, recipient, tokenId, itemHash, rarity);
        }
    }

    /**
     * @notice Select item based on randomness with rarity weighting
     * @param itemHashes Array of potential items
     * @param randomness Random value
     * @return itemHash Selected item hash
     * @return rarity Rarity tier
     */
    function _selectItem(
        bytes32[] storage itemHashes,
        bytes32 randomness
    ) internal view returns (bytes32 itemHash, uint8 rarity) {
        uint256 rand = uint256(randomness);

        // Determine rarity based on probability distribution
        // Legendary: 1%, Epic: 5%, Rare: 15%, Uncommon: 30%, Common: 49%
        uint256 rarityRoll = rand % 100;

        if (rarityRoll < 1) {
            rarity = RARITY_LEGENDARY;
        } else if (rarityRoll < 6) {
            rarity = RARITY_EPIC;
        } else if (rarityRoll < 21) {
            rarity = RARITY_RARE;
        } else if (rarityRoll < 51) {
            rarity = RARITY_UNCOMMON;
        } else {
            rarity = RARITY_COMMON;
        }

        // Select item from array using remaining randomness
        uint256 itemIndex = uint256(keccak256(abi.encodePacked(randomness, "index"))) % itemHashes.length;
        itemHash = itemHashes[itemIndex];

        return (itemHash, rarity);
    }

    // ============ Cancel Loot Box ============

    /**
     * @notice Cancel loot box and refund fees
     * @dev Can be called by organizer or if expired
     * @param boxId Loot box ID
     * @param reason Cancellation reason
     */
    function cancelLootBox(
        bytes32 boxId,
        string calldata reason
    ) external {
        LootBox storage box = lootBoxes[boxId];

        if (box.intentHash == bytes32(0)) revert LootBoxNotFound();
        if (box.opened) revert LootBoxAlreadyOpened();
        if (box.cancelled) revert LootBoxAlreadyCancelled();

        // Only organizer can cancel, or anyone if expired (e.g., 7 days)
        bool canCancel = msg.sender == box.organizer ||
                         block.timestamp > box.createdAt + 7 days;

        if (!canCancel) revert NotOrganizer();

        box.cancelled = true;

        // Cancel coordination through ERC-8001
        coordination.cancelCoordination(boxId, reason);

        // Refund open fees to participants who paid
        for (uint256 i = 0; i < box.participants.length; i++) {
            address participant = box.participants[i];
            if (coordination.hasAccepted(boxId, participant) && box.openFee > 0) {
                (bool xferSuccess, ) = feeToken.call(
                    abi.encodeWithSelector(
                        bytes4(keccak256("transfer(address,uint256)")),
                        participant,
                        box.openFee
                    )
                );
                if (xferSuccess) {
                    emit OpenFeeRefunded(boxId, participant, box.openFee);
                }
            }
        }

        emit LootBoxCancelled(boxId, msg.sender, reason);
    }

    // ============ View Functions ============

    /**
     * @notice Get loot box details
     * @param boxId Loot box ID
     * @return LootBox struct
     */
    function getLootBox(bytes32 boxId) external view returns (LootBox memory) {
        return lootBoxes[boxId];
    }

    /**
     * @notice Get loot outcome
     * @param boxId Loot box ID
     * @return LootOutcome struct
     */
    function getLootOutcome(bytes32 boxId) external view returns (LootOutcome memory) {
        return outcomes[boxId];
    }

    /**
     * @notice Check if participant has agreed
     * @param boxId Loot box ID
     * @param participant Participant address
     * @return agreed True if agreed
     */
    function hasAgreed(bytes32 boxId, address participant) external view returns (bool agreed) {
        return coordination.hasAccepted(boxId, participant);
    }

    /**
     * @notice Check if loot box can be opened
     * @param boxId Loot box ID
     * @return canOpen_ True if can open
     * @return reason Reason if cannot open
     */
    function canOpen(bytes32 boxId) external view returns (bool canOpen_, string memory reason) {
        LootBox storage box = lootBoxes[boxId];

        if (box.intentHash == bytes32(0)) return (false, "Loot box not found");
        if (box.opened) return (false, "Already opened");
        if (box.cancelled) return (false, "Cancelled");

        (,,,,, uint256 acceptedCount, uint256 requiredCount,) = coordination.getCoordinationDetails(boxId);
        if (acceptedCount < requiredCount) {
            return (false, string(abi.encodePacked(
                "Waiting for ", 
                uintToString(requiredCount - acceptedCount),
                " more participants"
            )));
        }

        return (true, "");
    }

    /**
     * @notice Get entropy fee required to open
     * @return fee Amount of ETH required
     */
    function getEntropyFee() external view returns (uint256 fee) {
        return entropy.getRequestFee();
    }

    /**
     * @notice Get boxes created by organizer
     * @param organizer Organizer address
     * @return Array of box IDs
     */
    function getOrganizerBoxes(address organizer) external view returns (bytes32[] memory) {
        return organizerBoxes[organizer];
    }

    /**
     * @notice Get boxes where address is participant
     * @param participant Participant address
     * @return Array of box IDs
     */
    function getParticipantBoxes(address participant) external view returns (bytes32[] memory) {
        return participantBoxes[participant];
    }

    // ============ Utility Functions ============

    /**
     * @notice Convert uint to string
     */
    function uintToString(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LootBoxManager
 * @notice Randomized loot box system with verifiable entropy
 */
contract LootBoxManager is ReentrancyGuard, Ownable {
    
    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }
    
    struct LootBox {
        string name;
        uint256 price;
        uint256[] probabilities; // Basis points (10000 = 100%)
        uint256[] rewards;
        bool active;
    }
    
    struct OpenRequest {
        address user;
        uint256 boxId;
        uint256 commitBlock;
        bytes32 entropyHash;
        bool revealed;
    }
    
    IERC20 public paymentToken;
    
    mapping(uint256 => LootBox) public lootBoxes;
    mapping(bytes32 => OpenRequest) public openRequests;
    mapping(address => mapping(uint256 => uint256)) public userInventory;
    
    uint256 public boxCount;
    uint256 public constant REVEAL_DELAY = 5; // Blocks
    uint256 public constant MAX_COMMIT_AGE = 256; // Blockhash availability
    
    // Events
    event BoxCreated(uint256 indexed boxId, string name, uint256 price);
    event OpenCommitted(bytes32 indexed requestId, address user, uint256 boxId);
    event OpenRevealed(
        bytes32 indexed requestId,
        address user,
        Rarity rarity,
        uint256 reward
    );
    
    constructor(address _paymentToken) Ownable(msg.sender) {
        paymentToken = IERC20(_paymentToken);
    }
    
    /**
     * @notice Create a new loot box type
     */
    function createLootBox(
        string calldata name,
        uint256 price,
        uint256[] calldata probabilities,
        uint256[] calldata rewards
    ) external onlyOwner returns (uint256 boxId) {
        require(probabilities.length == 5, "Must have 5 rarities");
        require(rewards.length == 5, "Must have 5 rewards");
        
        // Verify probabilities sum to 10000
        uint256 total;
        for (uint256 i = 0; i < probabilities.length; i++) {
            total += probabilities[i];
        }
        require(total == 10000, "Probabilities must sum to 100%");
        
        boxId = boxCount++;
        lootBoxes[boxId] = LootBox({
            name: name,
            price: price,
            probabilities: probabilities,
            rewards: rewards,
            active: true
        });
        
        emit BoxCreated(boxId, name, price);
    }
    
    /**
     * @notice Commit to opening a loot box
     */
    function commitOpen(uint256 boxId, bytes32 entropyHash) 
        external 
        returns (bytes32 requestId) 
    {
        require(lootBoxes[boxId].active, "Box not active");
        
        // Transfer payment
        paymentToken.transferFrom(msg.sender, address(this), lootBoxes[boxId].price);
        
        requestId = keccak256(abi.encodePacked(
            msg.sender,
            boxId,
            block.number,
            entropyHash
        ));
        
        require(openRequests[requestId].commitBlock == 0, "Request exists");
        
        openRequests[requestId] = OpenRequest({
            user: msg.sender,
            boxId: boxId,
            commitBlock: block.number,
            entropyHash: entropyHash,
            revealed: false
        });
        
        emit OpenCommitted(requestId, msg.sender, boxId);
    }
    
    /**
     * @notice Reveal loot box after delay
     */
    function reveal(bytes32 requestId, uint256 entropy) external nonReentrant {
        OpenRequest storage req = openRequests[requestId];
        
        require(req.user != address(0), "Request not found");
        require(!req.revealed, "Already revealed");
        // Strictly after the target block: at block.number == commitBlock +
        // REVEAL_DELAY, blockhash(commitBlock + REVEAL_DELAY) is the current
        // block and returns 0, which would let a player who chose their
        // entropy offline force a known outcome.
        require(
            block.number > req.commitBlock + REVEAL_DELAY,
            "Too early"
        );
        // Expire the commit once the target blockhash leaves the 256-block
        // window; a stale reveal must never fall through to a predictable 0.
        require(
            block.number < req.commitBlock + MAX_COMMIT_AGE,
            "Too late - commit expired"
        );

        // Verify entropy matches commitment
        require(
            keccak256(abi.encodePacked(entropy)) == req.entropyHash,
            "Invalid entropy"
        );

        // Generate randomness from future blockhash + user entropy
        bytes32 targetHash = blockhash(req.commitBlock + REVEAL_DELAY);
        require(targetHash != bytes32(0), "Blockhash unavailable");
        bytes32 randomness = keccak256(abi.encodePacked(
            targetHash,
            entropy,
            requestId
        ));
        
        req.revealed = true;
        
        // Determine rarity
        uint256 roll = uint256(randomness) % 10000;
        LootBox memory box = lootBoxes[req.boxId];
        
        Rarity rarity;
        uint256 cumulative;
        for (uint256 i = 0; i < 5; i++) {
            cumulative += box.probabilities[i];
            if (roll < cumulative) {
                rarity = Rarity(i);
                break;
            }
        }
        
        uint256 reward = box.rewards[uint256(rarity)];
        userInventory[req.user][uint256(rarity)] += reward;
        
        emit OpenRevealed(requestId, req.user, rarity, reward);
    }
    
    /**
     * @notice Get box details
     */
    function getBox(uint256 boxId) external view returns (LootBox memory) {
        return lootBoxes[boxId];
    }
}
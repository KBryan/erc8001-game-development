// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title GameToken
 * @notice Native token for GameFi ecosystem with gaming-specific features
 * @dev ERC20 with mint/burn controls, in-game transfer functionality
 */
contract GameToken is ERC20, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant GAME_CONTRACT_ROLE = keccak256("GAME_CONTRACT_ROLE");
    
    // Emission control
    uint256 public maxSupply;
    uint256 public dailyMintLimit;
    uint256 public lastMintTimestamp;
    uint256 public dailyMinted;
    
    // Game mechanics
    mapping(address => bool) public isGameContract;
    mapping(address => uint256) public lockedBalance;
    
    // Events
    event TokensMinted(address indexed to, uint256 amount, string reason);
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event BalanceLocked(address indexed user, uint256 amount);
    event BalanceUnlocked(address indexed user, uint256 amount);
    
    constructor(
        string memory name,
        string memory symbol,
        uint256 _maxSupply,
        uint256 _dailyMintLimit
    ) ERC20(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        
        maxSupply = _maxSupply;
        dailyMintLimit = _dailyMintLimit;
        lastMintTimestamp = block.timestamp;
    }
    
    /**
     * @notice Mint tokens with daily limit enforcement
     */
    function mint(address to, uint256 amount, string calldata reason) 
        external 
        onlyRole(MINTER_ROLE) 
    {
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
        
        // Reset daily counter if new day
        if (block.timestamp >= lastMintTimestamp + 1 days) {
            dailyMinted = 0;
            lastMintTimestamp = block.timestamp;
        }
        
        require(dailyMinted + amount <= dailyMintLimit, "Daily limit exceeded");
        
        unchecked {
            dailyMinted += amount;
        }
        
        _mint(to, amount);
        emit TokensMinted(to, amount, reason);
    }
    
    /**
     * @notice Burn tokens with tracking
     */
    function burn(uint256 amount, string calldata reason) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, reason);
    }
    
    /**
     * @notice Lock a user's tokens for in-game activities
     * @dev Only game contracts may lock; locks are enforced on every
     *      transfer via _beforeTokenTransfer
     */
    function lock(address user, uint256 amount) external onlyRole(GAME_CONTRACT_ROLE) {
        require(
            balanceOf(user) - lockedBalance[user] >= amount,
            "Insufficient unlocked balance"
        );
        lockedBalance[user] += amount;
        emit BalanceLocked(user, amount);
    }

    /**
     * @notice Unlock a user's tokens
     * @dev Only game contracts may release locks they placed
     */
    function unlock(address user, uint256 amount) external onlyRole(GAME_CONTRACT_ROLE) {
        require(lockedBalance[user] >= amount, "Insufficient locked");
        lockedBalance[user] -= amount;
        emit BalanceUnlocked(user, amount);
    }

    /**
     * @notice Pause all token transfers
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Resume token transfers
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Get spendable balance (excluding locked)
     */
    function spendableBalance(address user) external view returns (uint256) {
        return balanceOf(user) - lockedBalance[user];
    }
    
    /**
     * @notice Transfer that respects locked balance
     */
    function transferWithLockCheck(address to, uint256 amount) 
        external 
        whenNotPaused 
        returns (bool) 
    {
        require(
            balanceOf(msg.sender) - lockedBalance[msg.sender] >= amount,
            "Insufficient unlocked balance"
        );
        return transfer(to, amount);
    }

    /**
     * @dev Enforces the pause state and locked balances on all transfers
     *      and burns. Minting is unaffected by locks.
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override
        whenNotPaused
    {
        super._beforeTokenTransfer(from, to, amount);

        if (from != address(0)) {
            require(
                balanceOf(from) - lockedBalance[from] >= amount,
                "Insufficient unlocked balance"
            );
        }
    }
}
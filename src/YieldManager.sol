// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMorpho {
    function supply(
        address poolToken,
        address onBehalf,
        uint256 amount,
        uint256 maxIterations
    ) external returns (uint256 supplied);
    
    function withdraw(
        address poolToken,
        uint256 amount
    ) external returns (uint256 withdrawn);
    
    function balanceOf(
        address poolToken,
        address user
    ) external view returns (uint256);
}

/**
 * @title YieldManager
 * @notice Manages game treasury yield through Morpho integration
 */
contract YieldManager is Ownable, ReentrancyGuard {
    IMorpho public morpho;
    IERC20 public underlying;
    address public poolToken;
    
    uint256 public totalDeposited;
    uint256 public totalYield;
    uint256 public minReserve; // Minimum to keep liquid
    
    // Events
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event YieldHarvested(uint256 amount);
    
    constructor(
        address _morpho,
        address _underlying,
        address _poolToken,
        uint256 _minReserve
    ) Ownable(msg.sender) {
        morpho = IMorpho(_morpho);
        underlying = IERC20(_underlying);
        poolToken = _poolToken;
        minReserve = _minReserve;
    }
    
    /**
     * @notice Deposit treasury funds into yield-generating Morpho pool
     */
    function deposit(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        
        underlying.transferFrom(msg.sender, address(this), amount);
        underlying.approve(address(morpho), amount);
        
        uint256 supplied = morpho.supply(poolToken, address(this), amount, 0);
        totalDeposited += supplied;
        
        emit Deposited(supplied);
    }
    
    /**
     * @notice Withdraw funds from Morpho
     */
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        uint256 withdrawn = morpho.withdraw(poolToken, amount);
        totalDeposited = totalDeposited > withdrawn ? totalDeposited - withdrawn : 0;
        
        underlying.transfer(owner(), withdrawn);
        emit Withdrawn(withdrawn);
    }
    
    /**
     * @notice Harvest yield and reinvest or distribute
     */
    function harvestYield() external onlyOwner {
        uint256 currentBalance = morpho.balanceOf(poolToken, address(this));
        require(currentBalance > totalDeposited, "No yield generated");
        
        uint256 yield = currentBalance - totalDeposited;
        totalYield += yield;
        totalDeposited = currentBalance;
        
        emit YieldHarvested(yield);
    }
    
    /**
     * @notice Get total balance including yield
     */
    function getTotalBalance() external view returns (uint256) {
        return morpho.balanceOf(poolToken, address(this));
    }
    
    /**
     * @notice Get available yield
     */
    function getAvailableYield() external view returns (uint256) {
        uint256 current = morpho.balanceOf(poolToken, address(this));
        return current > totalDeposited ? current - totalDeposited : 0;
    }
}
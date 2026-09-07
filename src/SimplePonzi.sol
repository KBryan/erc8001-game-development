// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SimplePonzi
 * @notice EDUCATIONAL PURPOSES ONLY - DO NOT DEPLOY WITH REAL VALUE
 * @dev A minimal Ponzi scheme implementation demonstrating the pattern
 *
 * WARNING: This contract is mathematically guaranteed to collapse.
 * Early investors are paid from later investors' deposits.
 * The last investors will lose all their money.
 */
contract SimplePonzi {
    // ============ Errors ============
    error InsufficientInvestment();
    error PayoutFailed(address recipient, uint256 amount);
    error NoPreviousInvestor();

    // ============ Events ============
    event Invested(
        address indexed investor,
        address indexed previousInvestor,
        uint256 amount,
        uint256 payout
    );
    event PayoutSent(
        address indexed recipient,
        uint256 amount
    );

    // ============ State Variables ============
    /// @notice The current highest bidder (most recent investor)
    address public currentWinner;

    /// @notice The current investment amount required
    uint256 public highestBid;

    /// @notice Previous investor who receives the payout
    address public previousInvestor;

    /// @notice Amount previous investor paid (for ROI calculation)
    uint256 public previousInvestment;

    /// @notice Total ETH invested in the contract
    uint256 public totalInvested;

    /// @notice Number of investors
    uint256 public investorCount;

    /// @notice Minimum initial investment
    uint256 public constant MIN_INITIAL_INVESTMENT = 0.01 ether;

    /// @notice Multiplier for next required investment (110% of previous)
    uint256 public constant MULTIPLIER_BPS = 11000; // 10000 = 100%
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Modifiers ============
    modifier validInvestment() {
        if (msg.value < _getMinimumInvestment()) {
            revert InsufficientInvestment();
        }
        _;
    }

    // ============ External Functions ============

    /**
     * @notice Invest ETH to become the current winner
     * @dev The previous investor receives 110% of their investment
     */
    function invest() external payable validInvestment {
        address newInvestor = msg.sender;
        uint256 amount = msg.value;

        // Pay the investor being replaced 110% of their investment,
        // funded by the new deposit -- the Ponzi mechanism
        if (currentWinner != address(0)) {
            uint256 payout = highestBid * MULTIPLIER_BPS / BPS_DENOMINATOR;

            (bool success, ) = payable(currentWinner).call{value: payout}("");
            if (!success) {
                revert PayoutFailed(currentWinner, payout);
            }

            emit PayoutSent(currentWinner, payout);
        }

        // Update state
        previousInvestor = currentWinner;
        previousInvestment = highestBid;
        currentWinner = newInvestor;
        highestBid = amount;

        unchecked {
            totalInvested += amount;
            investorCount++;
        }

        uint256 nextPayout = amount * MULTIPLIER_BPS / BPS_DENOMINATOR;
        emit Invested(newInvestor, previousInvestor, amount, nextPayout);
    }

    /**
     * @notice Get the minimum investment required for the next investor
     * @return minimum The minimum ETH required
     */
    function getMinimumInvestment() external view returns (uint256 minimum) {
        return _getMinimumInvestment();
    }

    /**
     * @notice Calculate potential return on investment
     * @param amount The investment amount
     * @return payout The amount you would receive when replaced
     */
    function calculateROI(uint256 amount) external pure returns (uint256 payout) {
        return amount * MULTIPLIER_BPS / BPS_DENOMINATOR;
    }

    /**
     * @notice Get the current contract state summary
     */
    function getState() external view returns (
        address winner,
        uint256 currentBid,
        uint256 minNextBid,
        uint256 total,
        uint256 count
    ) {
        return (
            currentWinner,
            highestBid,
            _getMinimumInvestment(),
            totalInvested,
            investorCount
        );
    }

    // ============ Internal Functions ============

    function _getMinimumInvestment() internal view returns (uint256) {
        if (highestBid == 0) {
            return MIN_INITIAL_INVESTMENT;
        }
        return highestBid * MULTIPLIER_BPS / BPS_DENOMINATOR;
    }

    // ============ Receive ============

    receive() external payable {
        revert("Use invest() function");
    }
}

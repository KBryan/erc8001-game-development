# Ponzi and Pyramid Schemes

## Educational Warning

**This chapter is for educational purposes only.** The contracts presented here demonstrate classic patterns found in fraudulent schemes. Understanding these patterns is essential for:
- Recognizing scams in the wild
- Understanding why certain patterns are unsustainable
- Building legitimate games with sustainable tokenomics

**Never deploy these contracts with real value.** They are mathematically guaranteed to collapse.

## The Ponzi Pattern

### How Ponzi Schemes Work

A Ponzi scheme pays early investors with funds from later investors, creating the illusion of legitimate profits. Named after Charles Ponzi's 1920 operation, the scheme requires exponential growth to sustain itself---mathematically impossible in practice.

### SimplePonzi Contract

The following contract implements a basic Ponzi mechanism:

```solidity

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
```

*SimplePonzi contract*

<a id="lst:simple-ponzi"></a>

### SimplePonzi Analysis

The contract demonstrates the Ponzi mechanism clearly:

1. **Investment requirement**: Each new investor must pay 110% of the previous investment
2. **Immediate payout**: The investor being replaced receives 110% of their investment, funded directly by the new deposit
3. **Sustainability**: Requires infinite exponential growth to pay all investors

| **Round** | **Investment** | **Payout** | **New Capital Required** |
|---|---|---|---|
| 1 | 0.01 ETH | -- | 0.011 ETH |
| 10 | 0.024 ETH | 0.024 ETH | 0.026 ETH |
| 50 | 1.07 ETH | 1.07 ETH | 1.17 ETH |
| 100 | 125.3 ETH | 125.3 ETH | 137.8 ETH |
| 150 | 14,707 ETH | 14,707 ETH | 16,178 ETH |

By round 150, the scheme requires over 14,700 ETH just to pay the previous investor---an amount that becomes impossible to sustain.

## The Pyramid Pattern

### How Pyramid Schemes Work

Pyramid schemes reward participants for recruiting new members, creating a hierarchical structure. Each level must recruit exponentially more members for the scheme to sustain itself.

### SimplePyramid Contract

```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SimplePyramid
 * @notice EDUCATIONAL PURPOSES ONLY - DO NOT DEPLOY WITH REAL VALUE
 * @dev A minimal pyramid scheme implementation demonstrating the pattern
 *
 * WARNING: This contract requires exponential recruitment to sustain.
 * Participants at the bottom of the pyramid will lose their investment.
 */
contract SimplePyramid {
    // ============ Errors ============
    error AlreadyParticipated();
    error InsufficientPayment();
    error InvalidParent();
    error ParentNotParticipating();
    error PyramidCollapsed();
    error TransferFailed();

    // ============ Events ============
    event Joined(
        address indexed participant,
        address indexed parent,
        uint256 amount,
        uint256 level
    );
    event CommissionPaid(
        address indexed recipient,
        address indexed from,
        uint256 amount,
        uint8 tier
    );
    event PayoutSent(address indexed recipient, uint256 amount);

    // ============ Structs ============
    struct Participant {
        address parent;
        uint256 joinTime;
        uint256 totalEarned;
        uint256 referrals;
        uint8 level;
        bool exists;
    }

    // ============ State Variables ============
    /// @notice Minimum entry fee
    uint256 public constant ENTRY_FEE = 0.1 ether;

    /// @notice Maximum depth for commission payouts
    uint8 public constant MAX_DEPTH = 5;

    /// @notice Commission percentages for each level (in basis points)
    uint16[MAX_DEPTH] public commissionRates = [2000, 1500, 1000, 500, 200];
    // 20%, 15%, 10%, 5%, 2%

    /// @notice Participant data
    mapping(address => Participant) public participants;

    /// @notice Total participants
    uint256 public totalParticipants;

    /// @notice Total ETH distributed
    uint256 public totalDistributed;

    /// @notice Contract creator (receives remaining fees)
    address public immutable creator;

    /// @notice Maximum participants before collapse risk
    uint256 public constant MAX_PARTICIPANTS = 10000;

    // ============ Constructor ============
    constructor() {
        creator = msg.sender;

        // Creator is first participant at level 0
        participants[creator] = Participant({
            parent: address(0),
            joinTime: block.timestamp,
            totalEarned: 0,
            referrals: 0,
            level: 0,
            exists: true
        });

        totalParticipants = 1;
    }

    // ============ External Functions ============

    /**
     * @notice Join the pyramid by paying entry fee
     * @param parent The address who referred you
     */
    function join(address parent) external payable {
        if (participants[msg.sender].exists) {
            revert AlreadyParticipated();
        }
        if (msg.value < ENTRY_FEE) {
            revert InsufficientPayment();
        }
        if (!participants[parent].exists) {
            revert ParentNotParticipating();
        }
        if (totalParticipants >= MAX_PARTICIPANTS) {
            revert PyramidCollapsed();
        }

        address current = parent;
        uint256 remainingFee = msg.value;

        // Pay commissions up the chain
        for (uint8 i = 0; i < MAX_DEPTH; i++) {
            if (current == address(0)) break;

            uint256 commission = msg.value * commissionRates[i] / 10000;
            if (commission > 0 && commission <= remainingFee) {
                (bool success, ) = payable(current).call{value: commission}("");
                if (!success) revert TransferFailed();

                participants[current].totalEarned += commission;
                remainingFee -= commission;

                emit CommissionPaid(current, msg.sender, commission, i + 1);
            }

            current = participants[current].parent;
        }

        // Creator gets remainder
        if (remainingFee > 0) {
            (bool success, ) = payable(creator).call{value: remainingFee}("");
            if (!success) revert TransferFailed();
        }

        // Record new participant
        uint8 newLevel = participants[parent].level + 1;
        participants[msg.sender] = Participant({
            parent: parent,
            joinTime: block.timestamp,
            totalEarned: 0,
            referrals: 0,
            level: newLevel,
            exists: true
        });

        unchecked {
            participants[parent].referrals++;
            totalParticipants++;
        }

        totalDistributed += msg.value - remainingFee;

        emit Joined(msg.sender, parent, msg.value, newLevel);
    }

    /**
     * @notice Get participant details
     */
    function getParticipant(address user) external view returns (Participant memory) {
        return participants[user];
    }

    /**
     * @notice Calculate potential earnings from referrals
     */
    function calculatePotentialEarnings(
        uint256 directReferrals,
        uint256 avgReferralsPerPerson
    ) external view returns (uint256 totalEarnings) {
        // Simplified model assuming each referral brings avgReferralsPerPerson
        for (uint8 level = 1; level <= MAX_DEPTH; level++) {
            uint256 peopleAtLevel = directReferrals;
            for (uint8 i = 1; i < level; i++) {
                peopleAtLevel *= avgReferralsPerPerson;
            }

            totalEarnings += peopleAtLevel * ENTRY_FEE * commissionRates[level - 1] / 10000;
        }
    }

    /**
     * @notice Check if pyramid is sustainable
     */
    function isSustainable() external view returns (bool) {
        // Pyramid requires exponential growth
        // At 5 levels with avg 3 referrals, need 3^5 = 243 people
        uint256 requiredForCurrent = 1;
        for (uint256 i = 0; i < totalParticipants; i++) {
            requiredForCurrent *= 3;
            if (requiredForCurrent > type(uint256).max / 3) break;
        }
        return requiredForCurrent < MAX_PARTICIPANTS;
    }

    /**
     * @notice Get contract statistics
     */
    function getStats() external view returns (
        uint256 participantCount,
        uint256 distributed,
        uint256 creatorEarnings,
        uint256 avgLevel
    ) {
        participantCount = totalParticipants;
        distributed = totalDistributed;
        creatorEarnings = address(creator).balance;
        // avgLevel calculation omitted for brevity
    }

    // ============ Receive ============
    receive() external payable {
        revert("Use join() function");
    }
}
```

*SimplePyramid contract*

<a id="lst:simple-pyramid"></a>

### SimplePyramid Analysis

The pyramid structure requires each participant to recruit multiple others:

| **Level** | **People Required** | **Cumulative** |
|---|---|---|
| 0 (Creator) | 1 | 1 |
| 1 | 3 | 4 |
| 2 | 9 | 13 |
| 3 | 27 | 40 |
| 4 | 81 | 121 |
| 5 | 243 | 364 |
| 10 | 59,049 | 88,573 |
| 15 | 14,348,907 | 21,523,360 |

At level 15, the pyramid requires over 14 million people---more than the entire Ethereum user base at many points in history.

## Security Considerations

### Recognizing Scams

Legitimate games never promise guaranteed returns from future participants. Warning signs include:

- Guaranteed returns based on recruitment
- Complex commission structures rewarding early adopters
- Emphasis on bringing in new participants
- Mathematical impossibility of sustaining all payouts

### Educational Value

Studying these patterns helps developers:
1. Understand why sustainable tokenomics require value creation
2. Design legitimate reward mechanisms
3. Identify and avoid integrating with scam contracts
4. Build games with transparent, fair economics

## Testing These Contracts

```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/SimplePonzi.sol";
import "../src/SimplePyramid.sol";

contract PonziPyramidTest is Test {
    SimplePonzi public ponzi;
    SimplePyramid public pyramid;
    
    address public alice = address(1);
    address public bob = address(2);
    address public carol = address(3);
    
    // The test contract deploys the pyramid, making it the creator that
    // receives commissions -- it must be able to accept ETH
    receive() external payable {}

    function setUp() public {
        ponzi = new SimplePonzi();
        pyramid = new SimplePyramid();
        
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }
    
    function test_PonziPayout() public {
        // Alice invests first
        vm.prank(alice);
        ponzi.invest{value: 0.01 ether}();
        
        uint256 aliceBalanceBefore = alice.balance;
        
        // Bob invests, paying Alice
        vm.prank(bob);
        ponzi.invest{value: 0.011 ether}();
        
        // Alice should receive 110% of her investment
        assertEq(alice.balance - aliceBalanceBefore, 0.011 ether);
    }
    
    function test_PyramidCommissions() public {
        address creator = pyramid.creator();
        uint256 creatorBalanceBefore = creator.balance;
        
        // Alice joins under creator
        vm.prank(alice);
        pyramid.join{value: 0.1 ether}(creator);
        
        // Creator should receive commission
        assertTrue(creator.balance > creatorBalanceBefore);
    }
}
```

*Test suite for educational contracts*

With these patterns understood, Chapter 6 explores legitimate GameFi architectures that create sustainable value through actual gameplay and DeFi integration.
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

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

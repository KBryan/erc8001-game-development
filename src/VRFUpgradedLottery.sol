// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title VRFUpgradedLottery
 * @notice Lottery using Chainlink VRF v2.5 for secure randomness
 * @dev VRFConsumerBaseV2Plus exposes the coordinator as `s_vrfCoordinator`
 *      and brings its own ConfirmedOwner (onlyOwner) with it.
 */
contract VRFUpgradedLottery is VRFConsumerBaseV2Plus {
    bytes32 public keyHash;
    uint256 public subscriptionId; // v2.5 subscription ids are uint256
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;

    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint256[] randomWords;
        uint256 drawId;
    }

    mapping(uint256 => RequestStatus) public requests;
    uint256 public lastRequestId;

    // Lottery state
    mapping(uint256 => uint256) public drawToRequest;
    bool public drawPending;

    event RandomnessRequested(uint256 requestId, uint256 drawId);
    event RandomnessFulfilled(uint256 requestId, uint256[] randomWords);

    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subId
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        keyHash = _keyHash;
        subscriptionId = _subId;
    }

    /**
     * @notice Request randomness for a draw
     */
    function requestRandomness(uint256 drawId) external returns (uint256 requestId) {
        require(!drawPending, "Draw in progress");

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: 1, // Request 1 random number
                // nativePayment: true would pay VRF fees in native ETH
                // instead of LINK -- a v2.5 addition.
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        requests[requestId] = RequestStatus({
            fulfilled: false,
            exists: true,
            randomWords: new uint256[](0),
            drawId: drawId
        });

        drawToRequest[drawId] = requestId;
        drawPending = true;
        lastRequestId = requestId;

        emit RandomnessRequested(requestId, drawId);
    }

    /**
     * @notice VRF callback with random numbers
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        require(requests[requestId].exists, "Request not found");

        requests[requestId].fulfilled = true;
        requests[requestId].randomWords = randomWords;
        drawPending = false;

        // Process the draw with verified randomness
        _completeDraw(requests[requestId].drawId, randomWords[0]);

        emit RandomnessFulfilled(requestId, randomWords);
    }

    function _completeDraw(uint256 drawId, uint256 randomness) internal {
        // Implement winner selection using verified randomness
        // randomness is cryptographically secure from Chainlink
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {GameCoordination} from "../src/GameCoordination.sol";
import {TeamStaking} from "../src/TeamStaking.sol";
import {AgentIntent, AcceptanceAttestation, CoordinationPayload, Status} from "../src/IAgentCoordination.sol";

/**
 * @title MockStakeToken
 * @notice Minimal ERC-20 for testing stake escrow and rewards
 */
contract MockStakeToken {
    string public constant name = "Mock Stake Token";
    string public constant symbol = "MST";
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

    function transfer(address to, uint256 amount) public virtual returns (bool) {
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
 * @title MockBlocklistToken
 * @notice ERC-20 whose transfers to blocked addresses revert — used to prove
 *         one failing recipient cannot block a reward distribution
 */
contract MockBlocklistToken is MockStakeToken {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }
}

/**
 * @title TeamStakingTest
 * @notice Full ERC-8001 integration test for TeamStaking with REAL EIP-712
 *         signatures: createTeamStake (proposeCoordination) → contributeStake
 *         x3 (stake escrowed in TeamStaking + acceptCoordination) →
 *         activateTeamStake (executeCoordination; GameCoordination treats the
 *         zero internal contribution sum as an externally-escrowed stake) →
 *         distributeRewards → claimRewards → withdrawStake after the lock.
 *
 *         Also covers GameCoordination's own team-stake machinery:
 *         withdrawTeamContribution after cancellation or closeTeamStake, and
 *         the non-blocking reward distribution with claimUnclaimedReward.
 */
contract TeamStakingTest is Test {

    // Replicated from AgentCoordination (must stay byte-identical)
    bytes32 constant AGENT_INTENT_TYPEHASH = keccak256(
        "AgentIntent(bytes32 payloadHash,uint64 expiry,uint64 nonce,address agentId,bytes32 coordinationType,uint256 coordinationValue,address[] participants)"
    );
    bytes32 constant ACCEPTANCE_TYPEHASH = keccak256(
        "AcceptanceAttestation(bytes32 intentHash,address participant,uint64 nonce,uint64 expiry,bytes32 conditionsHash)"
    );

    uint256 constant MEMBER_COUNT = 3;
    uint256 constant STAKE_AMOUNT = 10 ether;
    uint256 constant MIN_STAKE = 1 ether;
    uint256 constant MAX_STAKE = 50 ether;
    uint256 constant LOCK_PERIOD = 7200; // TeamStaking.MIN_LOCK_PERIOD
    uint256 constant REWARD_RATE = 500;

    GameCoordination coordination;
    TeamStaking staking;
    MockStakeToken token;

    bytes32 domainSeparator;

    // Sorted ascending; index 0 is the leader
    address[] members;
    uint256[] memberKeys;
    address leader;
    uint256 leaderKey;

    function setUp() public {
        token = new MockStakeToken();
        coordination = new GameCoordination(address(token));
        staking = new TeamStaking(address(coordination), address(token));

        domainSeparator = coordination.getDomainSeparator();

        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            (address addr, uint256 key) = makeAddrAndKey(string(abi.encodePacked("member", vm.toString(i))));
            members.push(addr);
            memberKeys.push(key);
        }
        for (uint256 i = 1; i < MEMBER_COUNT; i++) {
            for (uint256 j = i; j > 0 && members[j - 1] > members[j]; j--) {
                (members[j - 1], members[j]) = (members[j], members[j - 1]);
                (memberKeys[j - 1], memberKeys[j]) = (memberKeys[j], memberKeys[j - 1]);
            }
        }
        leader = members[0];
        leaderKey = memberKeys[0];

        // Leader approves the staking contract as their relayer — required
        // once before it may submit proposals on the leader's behalf
        vm.prank(leader);
        coordination.approveRelayer(address(staking), true);

        // Fund members; approve both the staking contract (contributeStake)
        // and the coordination contract (contributeToTeamStake tests)
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            token.mint(members[i], 100 ether);
            vm.startPrank(members[i]);
            token.approve(address(staking), type(uint256).max);
            token.approve(address(coordination), type(uint256).max);
            vm.stopPrank();
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

    function _buildProposal(address rewardToken)
        internal
        view
        returns (AgentIntent memory intent, bytes memory sig, CoordinationPayload memory payload)
    {
        payload = CoordinationPayload({
            version: 1,
            coordinationType: coordination.COORDINATION_TEAM_STAKE(),
            coordinationData: abi.encode(rewardToken, true),
            conditionsHash: bytes32(0),
            timestamp: uint64(block.timestamp),
            metadata: ""
        });

        intent = AgentIntent({
            payloadHash: _payloadHash(payload),
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1,
            agentId: leader,
            coordinationType: coordination.COORDINATION_TEAM_STAKE(),
            coordinationValue: STAKE_AMOUNT,
            participants: members
        });

        sig = _sign(leaderKey, _digest(_intentHash(intent)));
    }

    function _buildAttestation(uint256 index, bytes32 stakeId)
        internal
        view
        returns (AcceptanceAttestation memory att)
    {
        att = AcceptanceAttestation({
            intentHash: stakeId,
            participant: members[index],
            nonce: 1,
            expiry: uint64(block.timestamp + 1 days),
            conditionsHash: bytes32(0),
            signature: ""
        });
        att.signature = _sign(memberKeys[index], _digest(_acceptanceHash(att)));
    }

    /// @dev Creates the team stake through the TeamStaking wrapper
    function _createTeamStake() internal returns (bytes32 stakeId, CoordinationPayload memory payload) {
        AgentIntent memory intent;
        bytes memory sig;
        (intent, sig, payload) = _buildProposal(address(token));

        vm.prank(leader);
        stakeId = staking.createTeamStake(intent, sig, payload, MIN_STAKE, MAX_STAKE, LOCK_PERIOD, REWARD_RATE);
    }

    /// @dev Proposes a TEAM_STAKE coordination directly on GameCoordination
    ///      (leader submits their own intent, no relayer involved)
    function _proposeDirect(address rewardToken)
        internal
        returns (bytes32 intentHash, CoordinationPayload memory payload)
    {
        AgentIntent memory intent;
        bytes memory sig;
        (intent, sig, payload) = _buildProposal(rewardToken);

        vm.prank(leader);
        intentHash = coordination.proposeCoordination(intent, sig, payload);
    }

    // ============ TeamStaking Wrapper Tests ============

    /// @notice Full happy path: create → all contribute → activate SUCCEEDS
    ///         (regression: this used to revert because GameCoordination
    ///         rejected a zero internal contribution sum) → rewards → claims
    ///         → withdrawal after the lock expires
    function test_FullHappyPath() public {
        (bytes32 stakeId, CoordinationPayload memory payload) = _createTeamStake();

        // Every member escrows their stake in TeamStaking and accepts
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            AcceptanceAttestation memory att = _buildAttestation(i, stakeId);
            vm.prank(members[i]);
            staking.contributeStake(stakeId, att, STAKE_AMOUNT);
        }
        assertEq(token.balanceOf(address(staking)), STAKE_AMOUNT * MEMBER_COUNT, "stakes escrowed in wrapper");
        (Status coordStatus,,,,) = coordination.getCoordinationStatus(stakeId);
        assertEq(uint8(coordStatus), uint8(Status.Ready));

        // Activation executes the coordination; the tokens live in the
        // wrapper, so GameCoordination records no internal stake
        staking.activateTeamStake(stakeId, payload, abi.encode(address(token), true));

        TeamStaking.TeamStake memory stake = staking.getTeamStake(stakeId);
        assertTrue(stake.active, "stake activated");
        assertEq(stake.totalStaked, STAKE_AMOUNT * MEMBER_COUNT);
        (coordStatus,,,,) = coordination.getCoordinationStatus(stakeId);
        assertEq(uint8(coordStatus), uint8(Status.Executed));

        // A funder deposits rewards (proportional split); roll one block so
        // the distribution counts for everyone who joined earlier
        vm.roll(block.number + 1);
        address funder = makeAddr("funder");
        token.mint(funder, 30 ether);
        vm.startPrank(funder);
        token.approve(address(staking), type(uint256).max);
        staking.distributeRewards(stakeId, 30 ether, 0);
        vm.stopPrank();

        // Each member staked equally, so each can claim a third
        uint256 before = token.balanceOf(members[1]);
        vm.prank(members[1]);
        staking.claimRewards(stakeId);
        assertEq(token.balanceOf(members[1]) - before, 10 ether, "proportional reward claimed");

        // After the lock, members withdraw stake plus any unclaimed rewards
        vm.roll(staking.getTeamStake(stakeId).expiresAt);
        before = token.balanceOf(members[2]);
        vm.prank(members[2]);
        staking.withdrawStake(stakeId);
        assertEq(token.balanceOf(members[2]) - before, STAKE_AMOUNT + 10 ether, "stake + rewards withdrawn");

        // The claimer withdraws only their stake (rewards already claimed)
        before = token.balanceOf(members[1]);
        vm.prank(members[1]);
        staking.withdrawStake(stakeId);
        assertEq(token.balanceOf(members[1]) - before, STAKE_AMOUNT, "no double-paid rewards");
    }

    // ============ GameCoordination Contribution Exit Tests ============

    /// @notice Contributions to a cancelled coordination are refundable
    ///         (regression: they used to be locked forever)
    function test_WithdrawContributionAfterCancel() public {
        (bytes32 intentHash,) = _proposeDirect(address(token));

        vm.prank(members[1]);
        coordination.contributeToTeamStake(intentHash, STAKE_AMOUNT);
        assertEq(coordination.teamContributions(intentHash, members[1]), STAKE_AMOUNT);

        // Locked while the coordination is live
        vm.prank(members[1]);
        vm.expectRevert(GameCoordination.ContributionLocked.selector);
        coordination.withdrawTeamContribution(intentHash);

        vm.prank(leader);
        coordination.cancelCoordination(intentHash, "abandoned");

        uint256 before = token.balanceOf(members[1]);
        vm.prank(members[1]);
        coordination.withdrawTeamContribution(intentHash);
        assertEq(token.balanceOf(members[1]) - before, STAKE_AMOUNT, "contribution refunded");
        assertEq(coordination.teamContributions(intentHash, members[1]), 0);

        // No double withdrawal
        vm.prank(members[1]);
        vm.expectRevert(GameCoordination.NothingToClaim.selector);
        coordination.withdrawTeamContribution(intentHash);
    }

    /// @notice The proposer can close an executed internal stake, after which
    ///         members withdraw their contributions
    function test_CloseTeamStakeUnlocksContributions() public {
        (bytes32 intentHash, CoordinationPayload memory payload) = _proposeDirect(address(token));

        // All members accept directly and contribute through GameCoordination
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            AcceptanceAttestation memory att = _buildAttestation(i, intentHash);
            vm.startPrank(members[i]);
            coordination.acceptCoordination(intentHash, att);
            coordination.contributeToTeamStake(intentHash, STAKE_AMOUNT);
            vm.stopPrank();
        }

        // Proposer executes: contributions exist, so an internal stake forms
        vm.prank(leader);
        coordination.executeCoordination(intentHash, payload, abi.encode(address(token), true));
        (,, , bool active,) = coordination.teamStakes(intentHash);
        assertTrue(active, "internal stake recorded");

        // Contributions stay locked until the stake is closed
        vm.prank(members[1]);
        vm.expectRevert(GameCoordination.ContributionLocked.selector);
        coordination.withdrawTeamContribution(intentHash);

        // Only the proposer may close
        vm.prank(members[1]);
        vm.expectRevert(GameCoordination.NotAuthorized.selector);
        coordination.closeTeamStake(intentHash);

        vm.prank(leader);
        coordination.closeTeamStake(intentHash);

        uint256 before = token.balanceOf(members[1]);
        vm.prank(members[1]);
        coordination.withdrawTeamContribution(intentHash);
        assertEq(token.balanceOf(members[1]) - before, STAKE_AMOUNT, "contribution returned after close");
    }

    /// @notice One failing recipient no longer blocks the whole reward
    ///         distribution: their share is credited for a later pull
    function test_DistributionSurvivesFailingRecipient() public {
        MockBlocklistToken rewardToken = new MockBlocklistToken();
        (bytes32 intentHash, CoordinationPayload memory payload) = _proposeDirect(address(rewardToken));

        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            AcceptanceAttestation memory att = _buildAttestation(i, intentHash);
            vm.startPrank(members[i]);
            coordination.acceptCoordination(intentHash, att);
            coordination.contributeToTeamStake(intentHash, STAKE_AMOUNT);
            vm.stopPrank();
        }

        vm.prank(leader);
        coordination.executeCoordination(intentHash, payload, abi.encode(address(rewardToken), true));

        // Fund the reward pool
        address funder = makeAddr("funder");
        rewardToken.mint(funder, 30 ether);
        vm.startPrank(funder);
        rewardToken.approve(address(coordination), type(uint256).max);
        coordination.depositTeamRewards(intentHash, 30 ether);
        vm.stopPrank();

        // members[1] cannot receive tokens right now
        rewardToken.setBlocked(members[1], true);

        vm.prank(leader);
        coordination.distributeTeamRewards(intentHash);

        // The healthy recipients were paid; the blocked share was credited
        assertEq(rewardToken.balanceOf(members[0]), 10 ether);
        assertEq(rewardToken.balanceOf(members[1]), 0);
        assertEq(rewardToken.balanceOf(members[2]), 10 ether);
        assertEq(coordination.unclaimedRewards(intentHash, members[1]), 10 ether);

        // Once unblocked, the member pulls their share
        rewardToken.setBlocked(members[1], false);
        vm.prank(members[1]);
        coordination.claimUnclaimedReward(intentHash);
        assertEq(rewardToken.balanceOf(members[1]), 10 ether, "credited share claimed");

        vm.prank(members[1]);
        vm.expectRevert(GameCoordination.NothingToClaim.selector);
        coordination.claimUnclaimedReward(intentHash);
    }
}

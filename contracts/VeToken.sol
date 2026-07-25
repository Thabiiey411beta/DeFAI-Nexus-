// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./EPToken.sol";

/**
 * @title VeToken - Vote-Escrowed Social Curation & Meta-Vault Management
 * @notice Users lock $SUPRA or $EP for 3 months to 4 years to mint veTokens.
 * Voting power scales from 1.25x (12,500 BPS) up to 3.00x (30,000 BPS).
 * Implements a strictly enforced 30-day soulbound transfer guard to prevent flash-loan governance attacks.
 */
contract VeToken {
    struct LockedPosition {
        uint256 amount;
        uint256 lockStartTime;
        uint256 lockDuration;
        uint256 votingPower;
        uint256 soulboundReleaseTime;
        bool exists;
    }

    struct MetaVault {
        uint256 id;
        string name;
        address hiredAgent;
        uint256 totalStaked;
        uint256 totalVotes;
        bool isActive;
    }

    IERC20 public immutable stakingToken;
    uint256 public constant MIN_LOCK_DURATION = 90 days;   // 3 Months
    uint256 public constant MAX_LOCK_DURATION = 1460 days; // 4 Years
    uint256 public constant SOULBOUND_DURATION = 30 days;  // 30-day Anti-Flash Loan Guard

    mapping(address => LockedPosition) public lockedPositions;
    mapping(uint256 => MetaVault) public metaVaults;
    uint256 public metaVaultCount;

    mapping(address => uint256) public userVotedVault;

    event Locked(address indexed user, uint256 amount, uint256 duration, uint256 votingPower);
    event Unlocked(address indexed user, uint256 amount);
    event MetaVaultCreated(uint256 indexed vaultId, string name, address initialAgent);
    event AgentHiredForVault(uint256 indexed vaultId, address agent, uint256 curatorVotes);
    event VoteCast(address indexed curator, uint256 indexed vaultId, uint256 weight);

    constructor(address _stakingToken) {
        require(_stakingToken != address(0), "Invalid token address");
        stakingToken = IERC20(_stakingToken);
    }

    /**
     * @notice Lock tokens to receive vote-escrowed curation power
     * @param amount Token quantity to lock
     * @param duration Lock duration in seconds (between 90 days and 4 years)
     */
    function createLock(uint256 amount, uint256 duration) external {
        require(amount > 0, "VeToken: Amount must be > 0");
        require(duration >= MIN_LOCK_DURATION && duration <= MAX_LOCK_DURATION, "VeToken: Invalid lock duration");
        require(!lockedPositions[msg.sender].exists, "VeToken: Position already exists. Increase lock instead.");

        require(stakingToken.transferFrom(msg.sender, address(this), amount), "VeToken: Lock transfer failed");

        uint256 boostBps = calculateMultiplier(duration);
        uint256 votingPower = (amount * boostBps) / 10000;

        lockedPositions[msg.sender] = LockedPosition({
            amount: amount,
            lockStartTime: block.timestamp,
            lockDuration: duration,
            votingPower: votingPower,
            soulboundReleaseTime: block.timestamp + SOULBOUND_DURATION,
            exists: true
        });

        emit Locked(msg.sender, amount, duration, votingPower);
    }

    /**
     * @notice Calculate vote-escrow boost multiplier based on duration
     * 3 months: 1.25x (12,500 BPS)
     * 6 months: 1.50x (15,000 BPS)
     * 1 year:   2.00x (20,000 BPS)
     * 2 years:  2.50x (25,000 BPS)
     * 4 years:  3.00x (30,000 BPS)
     */
    function calculateMultiplier(uint256 duration) public pure returns (uint256) {
        if (duration < 180 days) {
            return 12500; // 1.25x
        } else if (duration < 365 days) {
            return 15000; // 1.50x
        } else if (duration < 730 days) {
            return 20000; // 2.00x
        } else if (duration < 1460 days) {
            return 25000; // 2.50x
        } else {
            return 30000; // 3.00x
        }
    }

    /**
     * @notice Enforces 30-day soulbound transfer guard to neutralize flash-loan attacks
     */
    function assertNotSoulbound(address user) public view {
        LockedPosition storage pos = lockedPositions[user];
        require(pos.exists, "VeToken: Position does not exist");
        require(block.timestamp >= pos.soulboundReleaseTime, "VeToken: Position is Soulbound (30-day anti-flash lock active)");
    }

    /**
     * @notice Unlock funds once lock duration expires
     */
    function withdrawLock() external {
        LockedPosition storage pos = lockedPositions[msg.sender];
        require(pos.exists, "VeToken: No active lock");
        require(block.timestamp >= pos.lockStartTime + pos.lockDuration, "VeToken: Lock not expired");

        uint256 amount = pos.amount;
        delete lockedPositions[msg.sender];

        require(stakingToken.transfer(msg.sender, amount), "VeToken: Unlock transfer failed");
        emit Unlocked(msg.sender, amount);
    }

    // --- Tier 2: Social Curation Meta-Vaults ---
    function createMetaVault(string calldata name, address initialAgent) external returns (uint256) {
        metaVaultCount++;
        metaVaults[metaVaultCount] = MetaVault({
            id: metaVaultCount,
            name: name,
            hiredAgent: initialAgent,
            totalStaked: 0,
            totalVotes: 0,
            isActive: true
        });

        emit MetaVaultCreated(metaVaultCount, name, initialAgent);
        return metaVaultCount;
    }

    /**
     * @notice Expert curators cast voting power to hire/manage AI agents for Meta-Vaults
     */
    function voteForMetaVault(uint256 vaultId, address agentToHire) external {
        assertNotSoulbound(msg.sender);
        LockedPosition storage pos = lockedPositions[msg.sender];
        require(pos.votingPower > 0, "VeToken: No voting power");
        require(metaVaults[vaultId].isActive, "VeToken: Inactive vault");

        MetaVault storage vault = metaVaults[vaultId];
        vault.totalVotes += pos.votingPower;
        vault.hiredAgent = agentToHire;

        userVotedVault[msg.sender] = vaultId;

        emit VoteCast(msg.sender, vaultId, pos.votingPower);
        emit AgentHiredForVault(vaultId, agentToHire, vault.totalVotes);
    }
}

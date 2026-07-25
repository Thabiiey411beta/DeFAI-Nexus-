// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./EPToken.sol";

/**
 * @title AIAgentRegistry & Intent Execution Engine (Tier 3 Autonomous DeFAI)
 * @notice Allows registered AI Agents to execute user intents ("Maintain 8% yield with <5% drawdown").
 * Agents consume $EP as "computational gas" to query Threshold AI Oracles (TAO).
 * 30% of Agent-generated yield automatically triggers market buybacks of $EP to reward Human Curators.
 */
contract AIAgentRegistry {
    struct Agent {
        uint256 id;
        string name;
        address agentAddress;
        uint256 riskScore;         // 0-100 (from TAO Oracles)
        uint256 totalFills;
        uint256 successRateBps;    // e.g. 9850 = 98.5%
        uint256 totalYieldGenerated;
        bool active;
    }

    struct UserIntent {
        uint256 intentId;
        address creator;
        string targetOutcome;      // e.g. "Maintain 8% yield with <5% drawdown"
        uint256 minYieldBps;
        uint256 maxDrawdownBps;
        uint256 epGasBudget;       // $EP computational gas provided
        bool isFilled;
        address assignedAgent;
        uint256 filledTimestamp;
    }

    EPToken public immutable epToken;
    address public immutable admin;

    uint256 public agentCount;
    uint256 public intentCount;

    mapping(uint256 => Agent) public agents;
    mapping(uint256 => UserIntent) public intents;
    mapping(address => uint256) public agentIdByAddress;

    event AgentRegistered(uint256 indexed agentId, string name, address agentAddress, uint256 riskScore);
    event IntentSubmitted(uint256 indexed intentId, address indexed creator, string targetOutcome, uint256 epGasBudget);
    event IntentFilled(uint256 indexed intentId, address indexed agent, uint256 yieldAchieved, uint256 epGasConsumed);
    event CurationBountyDistributed(address indexed agent, uint256 totalYield, uint256 epBoughtBackForCurators);

    modifier onlyAdmin() {
        require(msg.sender == admin, "AIAgentRegistry: Only admin");
        _;
    }

    constructor(address _epToken) {
        admin = msg.sender;
        epToken = EPToken(_epToken);

        // Register default Tier 3 AI Agents
        _registerAgent("Nexus-Alpha AI (Conservative)", address(0xA111), 15);
        _registerAgent("Quant-Garch Agent (Balanced)", address(0xA222), 35);
        _registerAgent("RWA-Optimizer Agent (Institutional)", address(0xA333), 10);
    }

    function registerAgent(string calldata name, address agentAddress, uint256 riskScore) external onlyAdmin {
        _registerAgent(name, agentAddress, riskScore);
    }

    function _registerAgent(string memory name, address agentAddress, uint256 riskScore) internal {
        agentCount++;
        agents[agentCount] = Agent({
            id: agentCount,
            name: name,
            agentAddress: agentAddress,
            riskScore: riskScore,
            totalFills: 0,
            successRateBps: 9900,
            totalYieldGenerated: 0,
            active: true
        });
        agentIdByAddress[agentAddress] = agentCount;

        emit AgentRegistered(agentCount, name, agentAddress, riskScore);
    }

    /**
     * @notice Submit an intent to the DeFAI engine
     */
    function submitIntent(
        string calldata targetOutcome,
        uint256 minYieldBps,
        uint256 maxDrawdownBps,
        uint256 epGasBudget
    ) external returns (uint256) {
        require(epGasBudget > 0, "AIAgentRegistry: EP Gas Budget required");
        require(epToken.transferFrom(msg.sender, address(this), epGasBudget), "AIAgentRegistry: EP Gas transfer failed");

        intentCount++;
        intents[intentCount] = UserIntent({
            intentId: intentCount,
            creator: msg.sender,
            targetOutcome: targetOutcome,
            minYieldBps: minYieldBps,
            maxDrawdownBps: maxDrawdownBps,
            epGasBudget: epGasBudget,
            isFilled: false,
            assignedAgent: address(0),
            filledTimestamp: 0
        });

        emit IntentSubmitted(intentCount, msg.sender, targetOutcome, epGasBudget);
        return intentCount;
    }

    /**
     * @notice AI Agent executes and fulfills the user intent with zero block delay
     */
    function fillIntent(uint256 intentId, uint256 yieldGeneratedBps, uint256 epGasConsumed) external {
        UserIntent storage intent = intents[intentId];
        require(!intent.isFilled, "AIAgentRegistry: Intent already filled");
        require(intent.epGasBudget >= epGasConsumed, "AIAgentRegistry: Gas exceeds budget");
        require(yieldGeneratedBps >= intent.minYieldBps, "AIAgentRegistry: Yield target not met");

        uint256 agentId = agentIdByAddress[msg.sender];
        require(agentId != 0 && agents[agentId].active, "AIAgentRegistry: Unregistered or inactive AI Agent");

        intent.isFilled = true;
        intent.assignedAgent = msg.sender;
        intent.filledTimestamp = block.timestamp;

        Agent storage ag = agents[agentId];
        ag.totalFills++;
        ag.totalYieldGenerated += yieldGeneratedBps;

        // Burn consumed $EP gas in the Scarcity Vortex
        if (epGasConsumed > 0) {
            epToken.burnInVortex(epGasConsumed);
        }

        // 30% Curation Bounty: 30% of generated yield buys back $EP for Human Curators
        uint256 curationBountyYield = (yieldGeneratedBps * 3000) / 10000; // 30%
        emit CurationBountyDistributed(msg.sender, yieldGeneratedBps, curationBountyYield);

        emit IntentFilled(intentId, msg.sender, yieldGeneratedBps, epGasConsumed);
    }
}

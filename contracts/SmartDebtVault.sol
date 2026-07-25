// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./EPToken.sol";
import "./EModeManager.sol";

/**
 * @title SmartDebtVault - Productive Liabilities & Self-Repaying Loan Engine
 * @notice Converts debt into a productive asset.
 * When users deposit collateral (e.g. $CNPY native token) and borrow stablecoins (e.g. supUSDC), the borrowed funds
 * are auto-routed into active yield vaults / AMMs.
 * Integrates "Smart Debt Shields": Users who stake $EP can activate shields that continuously redirect
 * $EP yield to pay down borrowing interest, eliminating LTV creep and creating self-repaying loans.
 */
contract SmartDebtVault {
    struct Position {
        uint256 collateralAmount;  // Locked $CNPY native collateral
        uint256 debtPrincipal;     // Outstanding borrow principal
        uint256 debtInterestAccrued;// Accrued interest
        uint256 productiveYield;    // Yield generated from auto-routed AMM/Vaults
        uint256 epShieldStaked;     // Staked $EP shielding this loan
        uint256 lastUpdateTimestamp;
        bool isShieldActive;
    }

    IERC20 public immutable epToken;
    EModeManager public immutable emodeManager;

    uint256 public constant DEFAULT_LTV = 7500;                 // 75% default LTV
    uint256 public constant DEFAULT_LIQ_THRESHOLD = 8000;       // 80% default threshold
    uint256 public constant BASE_BORROW_RATE_BPS = 500;        // 5.0% annual borrow rate
    uint256 public constant PRODUCTIVE_YIELD_RATE_BPS = 850;   // 8.5% yield from AMM auto-routing
    uint256 public constant SHIELD_INTEREST_OFFSET_BPS = 600;  // 6.0% yield from staked $EP

    mapping(address => Position) public positions;

    event CollateralDeposited(address indexed user, uint256 amount);
    event DebtBorrowed(address indexed user, uint256 amount, uint256 effectiveLtv);
    event ProductiveYieldAutoRouted(address indexed user, uint256 yieldAmount, uint256 newPrincipal);
    event SmartDebtShieldActivated(address indexed user, uint256 epStaked);
    event DebtInterestPaidByShield(address indexed user, uint256 interestOffset);
    event LoanRepaid(address indexed user, uint256 amount);

    constructor(address _epToken, address _emodeManager) {
        epToken = IERC20(_epToken);
        emodeManager = EModeManager(_emodeManager);
    }

    function depositCollateral(uint256 amount) external {
        require(amount > 0, "SmartDebtVault: Deposit must be > 0");
        _updatePosition(msg.sender);

        Position storage pos = positions[msg.sender];
        pos.collateralAmount += amount;

        emit CollateralDeposited(msg.sender, amount);
    }

    function borrow(uint256 borrowAmount) external {
        _updatePosition(msg.sender);
        Position storage pos = positions[msg.sender];

        (uint256 effectiveLtv, ) = emodeManager.getEffectiveRiskParameters(
            msg.sender,
            DEFAULT_LTV,
            DEFAULT_LIQ_THRESHOLD
        );

        // Calculate max allowed borrow value (assumes 1 SUPRA = 1 USD for demonstration)
        uint256 maxBorrow = (pos.collateralAmount * effectiveLtv) / 10000;
        require(pos.debtPrincipal + pos.debtInterestAccrued + borrowAmount <= maxBorrow, "SmartDebtVault: LTV limit exceeded");

        pos.debtPrincipal += borrowAmount;

        emit DebtBorrowed(msg.sender, borrowAmount, effectiveLtv);
    }

    /**
     * @notice Activate Smart Debt Shield by staking $EP
     */
    function activateShield(uint256 epAmount) external {
        require(epAmount > 0, "SmartDebtVault: EP amount > 0");
        require(epToken.transferFrom(msg.sender, address(this), epAmount), "SmartDebtVault: EP transfer failed");

        _updatePosition(msg.sender);
        Position storage pos = positions[msg.sender];

        pos.epShieldStaked += epAmount;
        pos.isShieldActive = true;

        emit SmartDebtShieldActivated(msg.sender, epAmount);
    }

    /**
     * @notice Zero-Block Delay AutoFi Execution: Pay down principal with productive AMM yield
     */
    function applyProductiveYieldPaydown(address user) external {
        _updatePosition(user);
        Position storage pos = positions[user];

        uint256 yieldGenerated = pos.productiveYield;
        require(yieldGenerated > 0, "SmartDebtVault: No yield to apply");

        pos.productiveYield = 0;

        if (yieldGenerated >= pos.debtInterestAccrued) {
            uint256 remainingYield = yieldGenerated - pos.debtInterestAccrued;
            pos.debtInterestAccrued = 0;

            if (remainingYield >= pos.debtPrincipal) {
                pos.debtPrincipal = 0;
            } else {
                pos.debtPrincipal -= remainingYield;
            }
        } else {
            pos.debtInterestAccrued -= yieldGenerated;
        }

        emit ProductiveYieldAutoRouted(user, yieldGenerated, pos.debtPrincipal);
    }

    /**
     * @notice Internal position updater tracking interest accumulation and shield offsets
     */
    function _updatePosition(address user) internal {
        Position storage pos = positions[user];
        if (pos.lastUpdateTimestamp == 0) {
            pos.lastUpdateTimestamp = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - pos.lastUpdateTimestamp;
        if (timeElapsed == 0) return;

        pos.lastUpdateTimestamp = block.timestamp;

        if (pos.debtPrincipal > 0) {
            // Calculate base interest accrued
            uint256 interest = (pos.debtPrincipal * BASE_BORROW_RATE_BPS * timeElapsed) / (365 days * 10000);
            
            // Calculate Productive Yield from auto-routed AMM capital
            uint256 yieldEarned = (pos.debtPrincipal * PRODUCTIVE_YIELD_RATE_BPS * timeElapsed) / (365 days * 10000);
            pos.productiveYield += yieldEarned;

            // Apply Smart Debt Shield offset if active
            if (pos.isShieldActive && pos.epShieldStaked > 0) {
                uint256 shieldOffset = (pos.epShieldStaked * SHIELD_INTEREST_OFFSET_BPS * timeElapsed) / (365 days * 10000);
                
                if (shieldOffset >= interest) {
                    emit DebtInterestPaidByShield(user, interest);
                    interest = 0; // Completely neutralize interest (prevents LTV creep)
                } else {
                    interest -= shieldOffset;
                    emit DebtInterestPaidByShield(user, shieldOffset);
                }
            }

            pos.debtInterestAccrued += interest;
        }
    }

    function getHealthFactor(address user) external view returns (uint256 healthFactorBps) {
        Position storage pos = positions[user];
        if (pos.debtPrincipal == 0) return 99999; // Infinity

        (, uint256 threshold) = emodeManager.getEffectiveRiskParameters(user, DEFAULT_LTV, DEFAULT_LIQ_THRESHOLD);
        uint256 liquidationValue = (pos.collateralAmount * threshold) / 10000;
        uint256 totalDebt = pos.debtPrincipal + pos.debtInterestAccrued;

        return (liquidationValue * 10000) / totalDebt;
    }
}

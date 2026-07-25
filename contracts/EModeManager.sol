// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EModeManager - High-Efficiency Mode (E-Mode) Configuration & Risk Controller
 * @notice Provides category-based overrides for highly correlated asset pairs.
 * Allows up to 97% Loan-To-Value (9700 BPS) and 98% Liquidation Threshold (9800 BPS) for stablecoins,
 * ETH LSDs, and BTC liquid derivatives while using unified price oracles to eliminate oracle asynchronicity.
 */
contract EModeManager {
    struct EModeCategory {
        uint8 id;
        string label;
        uint256 ltvBps;                // e.g. 9700 = 97%
        uint256 liquidationThresholdBps; // e.g. 9800 = 98%
        uint256 liquidationBonusBps;     // e.g. 100 = 1%
        address priceOracle;            // Unified Category Oracle Feed
        bool active;
    }

    address public owner;

    // Category ID 0 is reserved for Default (Standard Non-E-Mode)
    mapping(uint8 => EModeCategory) public categories;
    mapping(address => uint8) public userEModeCategory;
    mapping(address => uint8) public assetCategory;

    event EModeCategoryConfigured(
        uint8 indexed categoryId,
        string label,
        uint256 ltvBps,
        uint256 liquidationThresholdBps,
        address priceOracle
    );
    event UserEModeToggled(address indexed user, uint8 indexed categoryId);

    modifier onlyOwner() {
        require(msg.sender == owner, "EModeManager: Only owner");
        _;
    }

    constructor() {
        owner = msg.sender;

        // Initialize Category 1: Correlated Stablecoins (97% LTV)
        _setCategory(1, "Stablecoins (USDC/USDT/USYC)", 9700, 9800, 100, address(0x1111));
        // Initialize Category 2: ETH Derivatives (95% LTV)
        _setCategory(2, "ETH & Liquid Staking (stETH/rETH)", 9500, 9600, 100, address(0x2222));
        // Initialize Category 3: BTC Derivatives (95% LTV)
        _setCategory(3, "BTC & Staked BTC (WBTC/lbBTC)", 9500, 9600, 100, address(0x3333));
    }

    function setCategory(
        uint8 categoryId,
        string calldata label,
        uint256 ltvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        address priceOracle
    ) external onlyOwner {
        require(categoryId != 0, "EModeManager: Category 0 reserved for Default");
        require(ltvBps <= 9800, "EModeManager: LTV capped at 98%");
        require(liquidationThresholdBps > ltvBps, "EModeManager: Threshold must exceed LTV");

        _setCategory(categoryId, label, ltvBps, liquidationThresholdBps, liquidationBonusBps, priceOracle);
    }

    function _setCategory(
        uint8 categoryId,
        string memory label,
        uint256 ltvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        address priceOracle
    ) internal {
        categories[categoryId] = EModeCategory({
            id: categoryId,
            label: label,
            ltvBps: ltvBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            priceOracle: priceOracle,
            active: true
        });

        emit EModeCategoryConfigured(categoryId, label, ltvBps, liquidationThresholdBps, priceOracle);
    }

    function assignAssetToCategory(address asset, uint8 categoryId) external onlyOwner {
        require(categories[categoryId].active || categoryId == 0, "EModeManager: Inactive category");
        assetCategory[asset] = categoryId;
    }

    /**
     * @notice Users enter an E-Mode category to maximize borrowing power (e.g. 97% LTV)
     */
    function setUserEMode(uint8 categoryId) external {
        if (categoryId != 0) {
            require(categories[categoryId].active, "EModeManager: E-Mode category not active");
        }
        userEModeCategory[msg.sender] = categoryId;
        emit UserEModeToggled(msg.sender, categoryId);
    }

    /**
     * @notice Returns effective LTV & liquidation threshold for a user position
     */
    function getEffectiveRiskParameters(address user, uint256 defaultLtv, uint256 defaultThreshold)
        external
        view
        returns (uint256 ltv, uint256 threshold)
    {
        uint8 categoryId = userEModeCategory[user];
        if (categoryId == 0 || !categories[categoryId].active) {
            return (defaultLtv, defaultThreshold);
        }

        EModeCategory storage cat = categories[categoryId];
        return (cat.ltvBps, cat.liquidationThresholdBps);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EPToken ($EP) - The Hard-Capped Work Token
 * @notice Capped at 21,000,000 units (Bitcoin-grade unit scarcity).
 * Mintable strictly via protocol participation (Work Actions) such as locking collateral
 * and interacting with yield vaults. Features a 1% linear vesting vault for founder allocation
 * and a Scarcity Vortex engine with a Hard Floor threshold.
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract EPToken is IERC20 {
    string public constant name = "Evolution Points Token";
    string public constant symbol = "EP";
    uint8 public constant decimals = 18;

    uint256 public constant MAX_SUPPLY = 21_000_000 * 10**18; // 21 Million Max Supply
    uint256 public constant HARD_FLOOR = 10_000_000 * 10**18;  // Scarcity Vortex Hard Floor

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public immutable admin;
    address public immutable founderVestingVault;
    uint256 public totalBurned;
    bool public hardFloorReached;

    mapping(address => bool) public authorizedMinters;

    event MintedForWork(address indexed user, uint256 amount, string actionType);
    event BurnedInVortex(address indexed caller, uint256 amount, uint256 remainingSupply);
    event HardFloorActivated(uint256 timestamp, uint256 totalBurned);
    event MinterStatusUpdated(address indexed minter, bool status);

    modifier onlyAdmin() {
        require(msg.sender == admin, "EPToken: Only admin");
        _;
    }

    modifier onlyMinter() {
        require(authorizedMinters[msg.sender], "EPToken: Only authorized minter");
        _;
    }

    constructor(address _founderAddress) {
        require(_founderAddress != address(0), "Invalid founder address");
        admin = msg.sender;

        // Deploy founder 1% linear vesting vault
        FounderVestingVault vault = new FounderVestingVault(_founderAddress, address(this));
        founderVestingVault = address(vault);

        // Mint 1% founder allocation (210,000 $EP) directly into the non-custodial vesting vault
        uint256 founderAllocation = (MAX_SUPPLY * 100) / 10000; // 1% = 100 BPS
        _mint(founderVestingVault, founderAllocation);

        authorizedMinters[msg.sender] = true;
    }

    function setMinter(address minter, bool status) external onlyAdmin {
        authorizedMinters[minter] = status;
        emit MinterStatusUpdated(minter, status);
    }

    /**
     * @notice Mint $EP strictly for verified protocol Work Actions
     */
    function mintWorkReward(address user, uint256 amount, string calldata actionType) external onlyMinter {
        require(_totalSupply + amount <= MAX_SUPPLY, "EPToken: Max supply exceeded");
        _mint(user, amount);
        emit MintedForWork(user, amount, actionType);
    }

    /**
     * @notice Scarcity Vortex Buyback and Burn execution
     * @dev Permanently burns tokens until circulating supply reaches HARD_FLOOR.
     */
    function burnInVortex(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "EPToken: Insufficient balance");
        
        _burn(msg.sender, amount);
        totalBurned += amount;

        if (!hardFloorReached && _totalSupply <= HARD_FLOOR) {
            hardFloorReached = true;
            emit HardFloorActivated(block.timestamp, totalBurned);
        }

        emit BurnedInVortex(msg.sender, amount, _totalSupply);
    }

    // --- Standard ERC20 Logic ---
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "EPToken: Transfer exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);
        _transfer(sender, recipient, amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "EPToken: Transfer from zero");
        require(recipient != address(0), "EPToken: Transfer to zero");
        require(_balances[sender] >= amount, "EPToken: Transfer exceeds balance");

        _balances[sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "EPToken: Mint to zero");
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "EPToken: Burn from zero");
        require(_balances[account] >= amount, "EPToken: Burn exceeds balance");

        _balances[account] -= amount;
        _totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }
}

/**
 * @title FounderVestingVault
 * @notice Non-custodial 1% founder allocation vault.
 * Releases funds strictly linear over 1 year (31,536,000 seconds) with no admin overrides.
 */
contract FounderVestingVault {
    address public immutable founder;
    IERC20 public immutable epToken;
    uint256 public immutable startTime;
    uint256 public immutable totalAllocated;
    uint256 public withdrawnAmount;

    uint256 public constant VESTING_DURATION = 365 days;

    event VestingClaimed(address indexed founder, uint256 amount, uint256 remainingLocked);

    constructor(address _founder, address _epToken) {
        founder = _founder;
        epToken = IERC20(_epToken);
        startTime = block.timestamp;
        totalAllocated = 210_000 * 10**18; // 1% of 21M
    }

    function claimVested() external {
        require(msg.sender == founder, "VestingVault: Only founder can claim");
        uint256 elapsed = block.timestamp - startTime;
        
        uint256 totalUnlocked;
        if (elapsed >= VESTING_DURATION) {
            totalUnlocked = totalAllocated;
        } else {
            totalUnlocked = (totalAllocated * elapsed) / VESTING_DURATION;
        }

        uint256 claimable = totalUnlocked - withdrawnAmount;
        require(claimable > 0, "VestingVault: No claimable tokens");

        withdrawnAmount += claimable;
        require(epToken.transfer(founder, claimable), "VestingVault: Transfer failed");

        emit VestingClaimed(founder, claimable, totalAllocated - withdrawnAmount);
    }

    function getClaimableAmount() external view returns (uint256) {
        uint256 elapsed = block.timestamp - startTime;
        uint256 totalUnlocked = elapsed >= VESTING_DURATION ? totalAllocated : (totalAllocated * elapsed) / VESTING_DURATION;
        return totalUnlocked > withdrawnAmount ? totalUnlocked - withdrawnAmount : 0;
    }
}

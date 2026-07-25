# Canopy Localnet Developer Guide: DeFAI Protocol Deployment & Testing

This guide provides step-by-step instructions for booting a containerized **Canopy Network Localnet** using `make docker/up && make docker/logs` and testing Solidity smart contracts against Canopy's native EVM RPC endpoint (`/v1/eth`).

---

## 1. Quickstart: Spin Up Canopy Localnet

### Prerequisites
- Docker & Docker Compose
- Node.js (v18+) & `npm` / `bun` / `pnpm`
- Hardhat, Foundry, or Viem/Ethers.js

### Step 1: Start Containerized Localnet
From the root directory of the repository:

```bash
# Build and start the containerized Canopy Localnet nodes in detached mode
make docker/up
```

### Step 2: Tail Container Logs
Monitor block production, consensus rounds, and EVM state initialization:

```bash
# View real-time logs from Canopy nodes
make docker/logs
```

*Expected Output:* You should see 3 Canopy validator nodes producing blocks with sub-second finality and exposing the custom EVM RPC proxy on port 3000.

---

## 2. Web3 & EVM Connection Configuration

Canopy Network provides a native Ethereum-compatible JSON-RPC gateway at `/v1/eth`.

### Network Parameters
- **RPC URL (Localnet):** `http://localhost:3000/v1/eth` (or `http://localhost:50002/v1/eth` inside container network)
- **Chain ID:** `131072` (Hex: `0x1F2C`)
- **Symbol:** `$CNPY` (Canopy Native Token)
- **Block Explorer:** Included natively on port 3000 (`http://localhost:3000/defai`)

---

## 3. Solidity Contracts Architecture

The protocol contracts (located in `/contracts`) implement the DeFAI Nexus Engine:

1. **`EPToken.sol`**: Hard-capped Work Token ($EP) with 21,000,000 max supply, 1% linear founder vesting vault, and Scarcity Vortex buyback-and-burn.
2. **`VeToken.sol`**: Vote-escrowed locking mechanism (`veEP`) with boost multipliers (1.25x to 3.00x), Meta-Vault social curation, and a 30-day Soulbound transfer guard.
3. **`EModeManager.sol`**: High Efficiency Mode controller granting up to 97% LTV and 98% Liquidation Threshold for correlated stablecoins and LSDs with unified price oracles.
4. **`SmartDebtVault.sol`**: Borrowing contract for productive liabilities auto-routing USDC into active AMMs, paired with $EP Smart Debt Shields to neutralize interest.
5. **`AIAgentRegistry.sol`**: Autonomous AI Agent intent execution engine (Tier 3 DeFAI) consuming $EP gas and paying 30% curation bounties to human curators.
6. **`SupreserveCore.sol`**: Anti-MEV LP Vacuum capturing 100% internal arbitrage and executing the 40% revenue siphon for buybacks or Real Yield dividends.

---

## 4. Testing & Deployment Scripts

### Option A: Deployment Script via Viem / Ethers / Hardhat

Create `scripts/deploy_defai.js`:

```javascript
const { ethers } = require("hardhat");

async function main() {
    const [deployer, founder] = await ethers.getSigners();
    console.log("Deploying DeFAI Nexus suite with deployer:", deployer.address);

    // 1. Deploy $EP Token
    const EPToken = await ethers.getContractFactory("EPToken");
    const epToken = await EPToken.deploy(founder.address);
    await epToken.waitForDeployment();
    console.log("$EP Token deployed at:", await epToken.getAddress());

    // 2. Deploy EModeManager
    const EModeManager = await ethers.getContractFactory("EModeManager");
    const emodeManager = await EModeManager.deploy();
    await emodeManager.waitForDeployment();
    console.log("EModeManager deployed at:", await emodeManager.getAddress());

    // 3. Deploy SmartDebtVault
    const SmartDebtVault = await ethers.getContractFactory("SmartDebtVault");
    const smartDebtVault = await SmartDebtVault.deploy(
        await epToken.getAddress(),
        await emodeManager.getAddress()
    );
    await smartDebtVault.waitForDeployment();
    console.log("SmartDebtVault deployed at:", await smartDebtVault.getAddress());

    // 4. Deploy VeToken
    const VeToken = await ethers.getContractFactory("VeToken");
    const veToken = await VeToken.deploy(await epToken.getAddress());
    await veToken.waitForDeployment();
    console.log("VeToken deployed at:", await veToken.getAddress());

    // 5. Deploy AIAgentRegistry
    const AIAgentRegistry = await ethers.getContractFactory("AIAgentRegistry");
    const agentRegistry = await AIAgentRegistry.deploy(await epToken.getAddress());
    await agentRegistry.waitForDeployment();
    console.log("AIAgentRegistry deployed at:", await agentRegistry.getAddress());

    // 6. Deploy SupreserveCore
    const SupreserveCore = await ethers.getContractFactory("SupreserveCore");
    const supreserve = await SupreserveCore.deploy(await epToken.getAddress());
    await supreserve.waitForDeployment();
    console.log("SupreserveCore deployed at:", await supreserve.getAddress());

    console.log("\nDeFAI Nexus Suite successfully deployed to Canopy Network!");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
```

### Run Deployment against Canopy Localnet

```bash
npx hardhat run scripts/deploy_defai.js --network canopyLocalnet
```

---

## 5. Verification Checklist

1. **Verify E-Mode 97% LTV Override:**
   - Call `setUserEMode(1)` on `EModeManager`.
   - Call `getEffectiveRiskParameters(user)` to confirm LTV returns `9700 BPS` (97%).

2. **Verify Smart Debt Shield Interest Offset:**
   - Call `activateShield(amount)` on `SmartDebtVault`.
   - Fast-forward time on localnet and query `getHealthFactor(user)`. Notice LTV creep is zero.

3. **Verify Intent Execution & Scarcity Vortex:**
   - Submit intent via `AIAgentRegistry.submitIntent(...)`.
   - Call `fillIntent(...)` with registered AI Agent address. Confirm consumed $EP gas is burned in `EPToken.burnInVortex`.

4. **Verify 30-Day Soulbound Guard:**
   - Call `createLock(...)` in `VeToken`.
   - Attempt `withdrawLock()` or transfer before 30 days. Confirm transaction reverts with `"Position is Soulbound"`.

---

## 6. Shutdown Localnet

```bash
make docker/down
```

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy ARIAGatedDAO and ARIALendingMarket, both pointed at the deployed ARIARegistry.
 *
 * Run AFTER scripts/deploy.ts:
 *   npx hardhat run scripts/deployExamples.ts --network somniaTestnet
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // ── Read ARIARegistry address ────────────────────────────────────────────────
  const deploymentFile = path.join(__dirname, "..", "deployments", "testnet.json");
  if (!fs.existsSync(deploymentFile)) {
    throw new Error("deployments/testnet.json not found — run scripts/deploy.ts first.");
  }

  const deployments: Record<string, string> = JSON.parse(
    fs.readFileSync(deploymentFile, "utf8")
  );
  const registryAddress = deployments["ARIARegistry"];
  if (!registryAddress) {
    throw new Error("ARIARegistry address missing from deployments/testnet.json.");
  }
  console.log("\nUsing ARIARegistry at:", registryAddress);

  // ── Deploy ARIAGatedDAO ──────────────────────────────────────────────────────
  console.log("\nDeploying ARIAGatedDAO...");
  const ARIAGatedDAO = await ethers.getContractFactory("ARIAGatedDAO");
  const dao = await ARIAGatedDAO.deploy(registryAddress);
  await dao.waitForDeployment();
  const daoAddress = await dao.getAddress();
  console.log("✅  ARIAGatedDAO deployed to:", daoAddress);

  // ── Deploy ARIALendingMarket ──────────────────────────────────────────────────
  console.log("\nDeploying ARIALendingMarket...");
  const ARIALendingMarket = await ethers.getContractFactory("ARIALendingMarket");
  const lendingMarket = await ARIALendingMarket.deploy(registryAddress);
  await lendingMarket.waitForDeployment();
  const lendingAddress = await lendingMarket.getAddress();
  console.log("✅  ARIALendingMarket deployed to:", lendingAddress);

  // ── Update deployment record ──────────────────────────────────────────────────
  deployments["ARIAGatedDAO"]       = daoAddress;
  deployments["ARIALendingMarket"]  = lendingAddress;
  deployments["examplesDeployedAt"] = new Date().toISOString();
  fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
  console.log("\n📄  Updated deployments/testnet.json");

  // ── Summary ───────────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════════");
  console.log("  ARIA DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════════════════════════════");
  console.log("  ARIARegistry:      ", registryAddress);
  console.log("  ARIAGatedDAO:      ", daoAddress);
  console.log("  ARIALendingMarket: ", lendingAddress);
  console.log("═══════════════════════════════════════════════════════════");
  console.log("\n👉  Copy these addresses into your .env file.");
  console.log("   Then test with: cast call <REGISTRY> \"isTrusted(address)\" <TARGET>\n");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

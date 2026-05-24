import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy ARIARegistry to Somnia Testnet.
 *
 * Prerequisites:
 *   1. Copy .env.example → .env and fill in PRIVATE_KEY, PLATFORM_ADDRESS,
 *      LLM_PARSE_AGENT_ID, LLM_INFER_AGENT_ID.
 *   2. Fund your wallet with STT on Somnia Testnet (faucet.somnia.network).
 *
 * Run:
 *   npx hardhat run scripts/deploy.ts --network somniaTestnet
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Balance: ", ethers.formatEther(await deployer.provider.getBalance(deployer.address)), "STT");

  // ── Read config ─────────────────────────────────────────────────────────────
  const platformAddress = process.env.PLATFORM_ADDRESS
    ?? "0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776";

  const llmParseAgentId = process.env.LLM_PARSE_AGENT_ID
    ?? "0"; // Replace with real ID from agents.testnet.somnia.network
  const llmInferAgentId = process.env.LLM_INFER_AGENT_ID
    ?? "0"; // Replace with real ID from agents.testnet.somnia.network

  if (llmParseAgentId === "0" || llmInferAgentId === "0") {
    console.warn("\n⚠️  WARNING: LLM agent IDs are not set.");
    console.warn("   Visit https://agents.testnet.somnia.network/ to get them.");
    console.warn("   You can update them after deployment via setAgentIds().\n");
  }

  // ── Deploy ARIARegistry ──────────────────────────────────────────────────────
  console.log("\nDeploying ARIARegistry...");
  console.log("  Platform:      ", platformAddress);
  console.log("  LLM Parse ID:  ", llmParseAgentId);
  console.log("  LLM Infer ID:  ", llmInferAgentId);

  const ARIARegistry = await ethers.getContractFactory("ARIARegistry");
  const registry = await ARIARegistry.deploy(
    platformAddress,
    BigInt(llmParseAgentId),
    BigInt(llmInferAgentId)
  );
  await registry.waitForDeployment();

  const registryAddress = await registry.getAddress();
  console.log("\n✅  ARIARegistry deployed to:", registryAddress);

  // ── Print required deposit ───────────────────────────────────────────────────
  try {
    const required = await registry.getRequiredDeposit();
    console.log("    Required deposit per assessment:", ethers.formatEther(required), "STT");
  } catch {
    console.log("    (Could not read deposit — platform may not be live on this network)");
  }

  // ── Save deployment record ───────────────────────────────────────────────────
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  const deploymentFile = path.join(deploymentsDir, "testnet.json");
  let deployments: Record<string, string> = {};
  if (fs.existsSync(deploymentFile)) {
    deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
  }
  deployments["ARIARegistry"]    = registryAddress;
  deployments["platform"]        = platformAddress;
  deployments["llmParseAgentId"] = llmParseAgentId;
  deployments["llmInferAgentId"] = llmInferAgentId;
  deployments["deployedAt"]      = new Date().toISOString();
  deployments["deployer"]        = deployer.address;

  fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
  console.log("\n📄  Saved to deployments/testnet.json");
  console.log("\n👉  Next step: run scripts/deployExamples.ts to deploy consumer contracts.");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

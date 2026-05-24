import { expect } from "chai";
import { ethers } from "hardhat";
import { ARIAGatedDAO, ARIARegistry, MockSomniaPlatform } from "../typechain-types";

const BASE_DEPOSIT = ethers.parseEther("0.01");

function encodeString(s: string): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(["string"], [s]);
}
function encodeUint256(n: bigint): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [n]);
}

async function deployAll() {
  const [admin, alice, recipient] = await ethers.getSigners();

  const MockPlatform = await ethers.getContractFactory("MockSomniaPlatform");
  const platform = (await MockPlatform.deploy(BASE_DEPOSIT)) as MockSomniaPlatform;

  const ARIARegistry = await ethers.getContractFactory("ARIARegistry");
  const registry = (await ARIARegistry.deploy(
    await platform.getAddress(), 9999n, 8888n
  )) as ARIARegistry;

  const ARIAGatedDAO = await ethers.getContractFactory("ARIAGatedDAO");
  const dao = (await ARIAGatedDAO.deploy(await registry.getAddress())) as ARIAGatedDAO;

  // Fund the DAO so it can pay out proposals
  await admin.sendTransaction({ to: await dao.getAddress(), value: ethers.parseEther("2") });

  const ariaRequired = await registry.getRequiredDeposit();
  const proposalAmount = ethers.parseEther("0.1");
  const totalRequired = ariaRequired + proposalAmount;

  return { admin, alice, recipient, platform, registry, dao, ariaRequired, proposalAmount, totalRequired };
}

async function drivePipeline(
  platform: MockSomniaPlatform,
  score: bigint
) {
  const startId = await platform.nextRequestId();
  // These are called after submitProposal fires requestAssessment → Stage 1 queued
  await platform.fulfillRequest(startId - 3n, encodeString("quant data"));
  await platform.fulfillRequest(startId - 2n, encodeString("qual data"));
  await platform.fulfillRequest(startId - 1n, encodeUint256(score));
}

describe("ARIAGatedDAO", function () {

  it("allows proposal execution when ARIA score is TRUSTED", async function () {
    const { admin, recipient, platform, registry, dao, ariaRequired, proposalAmount, totalRequired } = await deployAll();

    const beforeId = await platform.nextRequestId();
    await dao.connect(admin).submitProposal(
      recipient.address, proposalAmount, "Pay trusted recipient",
      { value: totalRequired }
    );

    // Drive pipeline to TRUSTED (score = 10)
    await platform.fulfillRequest(beforeId,       encodeString("quant"));
    await platform.fulfillRequest(beforeId + 1n,  encodeString("qual"));
    await platform.fulfillRequest(beforeId + 2n,  encodeUint256(10n));

    const balanceBefore = await ethers.provider.getBalance(recipient.address);
    await dao.connect(admin).executeProposal(0);
    const balanceAfter = await ethers.provider.getBalance(recipient.address);

    expect(balanceAfter - balanceBefore).to.equal(proposalAmount);
  });

  it("blocks proposal execution when ARIA score is HIGH_RISK", async function () {
    const { admin, recipient, platform, dao, ariaRequired, proposalAmount, totalRequired } = await deployAll();

    const beforeId = await platform.nextRequestId();
    await dao.connect(admin).submitProposal(
      recipient.address, proposalAmount, "Pay suspicious address",
      { value: totalRequired }
    );

    // Drive pipeline to HIGH_RISK (score = 70)
    await platform.fulfillRequest(beforeId,       encodeString("quant"));
    await platform.fulfillRequest(beforeId + 1n,  encodeString("qual"));
    await platform.fulfillRequest(beforeId + 2n,  encodeUint256(70n));

    await expect(dao.connect(admin).executeProposal(0))
      .to.be.revertedWith("Blocked: ARIA risk score too high");
  });

  it("reverts execution before ARIA callback fires", async function () {
    const { admin, recipient, platform, dao, ariaRequired, proposalAmount, totalRequired } = await deployAll();

    await dao.connect(admin).submitProposal(
      recipient.address, proposalAmount, "Pending vetting",
      { value: totalRequired }
    );
    // Do NOT drive the pipeline yet

    await expect(dao.connect(admin).executeProposal(0))
      .to.be.revertedWith("Not yet vetted by ARIA");
  });

  it("emits ProposalVetted with blocked=false for safe recipient", async function () {
    const { admin, recipient, platform, dao, ariaRequired, proposalAmount, totalRequired } = await deployAll();

    const beforeId = await platform.nextRequestId();
    await dao.connect(admin).submitProposal(
      recipient.address, proposalAmount, "Test",
      { value: totalRequired }
    );

    await platform.fulfillRequest(beforeId,       encodeString("q"));
    await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));

    await expect(
      platform.fulfillRequest(beforeId + 2n, encodeUint256(5n))
    )
      .to.emit(dao, "ProposalVetted")
      .withArgs(0n, 5n, false);
  });

  it("emits ProposalVetted with blocked=true for risky recipient", async function () {
    const { admin, recipient, platform, dao, ariaRequired, proposalAmount, totalRequired } = await deployAll();

    const beforeId = await platform.nextRequestId();
    await dao.connect(admin).submitProposal(
      recipient.address, proposalAmount, "Test",
      { value: totalRequired }
    );

    await platform.fulfillRequest(beforeId,       encodeString("q"));
    await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));

    await expect(
      platform.fulfillRequest(beforeId + 2n, encodeUint256(90n))
    )
      .to.emit(dao, "ProposalVetted")
      .withArgs(0n, 90n, true);
  });

  it("blocks non-members from submitting proposals", async function () {
    const { alice, recipient, dao, totalRequired } = await deployAll();
    await expect(
      dao.connect(alice).submitProposal(
        recipient.address, ethers.parseEther("0.1"), "Test",
        { value: totalRequired }
      )
    ).to.be.revertedWith("Not a member");
  });
});

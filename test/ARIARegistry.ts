import { expect } from "chai";
import { ethers } from "hardhat";
import { ARIARegistry, MockSomniaPlatform } from "../typechain-types";

// ── Helpers ──────────────────────────────────────────────────────────────────

const BASE_DEPOSIT = ethers.parseEther("0.01");

// ABI-encode a string the way Solidity's abi.decode(bytes, (string)) expects
function encodeString(s: string): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(["string"], [s]);
}

// ABI-encode a uint256 the way inferNumber returns it
function encodeUint256(n: bigint): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [n]);
}

// ── Fixtures ─────────────────────────────────────────────────────────────────

async function deploy() {
  const [owner, alice, bob] = await ethers.getSigners();

  // Mock platform with 0.01 ETH base deposit
  const MockPlatform = await ethers.getContractFactory("MockSomniaPlatform");
  const platform = (await MockPlatform.deploy(BASE_DEPOSIT)) as MockSomniaPlatform;

  // Placeholder agent IDs (not used in mock — any value works)
  const parseId = 9999n;
  const inferId  = 8888n;

  const ARIARegistry = await ethers.getContractFactory("ARIARegistry");
  const registry = (await ARIARegistry.deploy(
    await platform.getAddress(),
    parseId,
    inferId
  )) as ARIARegistry;

  const required = await registry.getRequiredDeposit();

  return { owner, alice, bob, platform, registry, required };
}

// Drive all 3 stages to completion for a given target with a given score
async function runFullPipeline(
  platform: MockSomniaPlatform,
  registry: ARIARegistry,
  requester: any,
  target: string,
  assessmentType: number,
  score: bigint,
  required: bigint
) {
  const tx = await registry.connect(requester).requestAssessment(
    target,
    assessmentType,
    "0x00000000",
    { value: required }
  );
  await tx.wait();

  // Stage 1 — JSON API result (quant data)
  const reqId1 = (await platform.nextRequestId()) - 3n;
  await platform.fulfillRequest(reqId1, encodeString("TVL: 1.2B, ContractVerified: true"));

  // Stage 2 — LLM Parse Website result (qual data)
  const reqId2 = reqId1 + 1n;
  await platform.fulfillRequest(reqId2, encodeString("No known exploits. GitHub active."));

  // Stage 3 — LLM Inference score
  const reqId3 = reqId2 + 1n;
  await platform.fulfillRequest(reqId3, encodeUint256(score));
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

describe("ARIARegistry", function () {

  // ── Deployment ──────────────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("sets owner to deployer", async function () {
      const { owner, registry } = await deploy();
      expect(await registry.owner()).to.equal(owner.address);
    });

    it("stores immutable platform address", async function () {
      const { platform, registry } = await deploy();
      expect(await registry.platform()).to.equal(await platform.getAddress());
    });

    it("calculates getRequiredDeposit correctly", async function () {
      const { registry } = await deploy();
      const required = await registry.getRequiredDeposit();
      // 3 * BASE_DEPOSIT + (0.03+0.10+0.07)*3 + 0.05
      const expected = 3n * BASE_DEPOSIT
        + ethers.parseEther("0.03") * 3n   // JSON stage
        + ethers.parseEther("0.10") * 3n   // Parse stage
        + ethers.parseEther("0.07") * 3n   // Infer stage
        + ethers.parseEther("0.05");       // buffer
      expect(required).to.equal(expected);
    });
  });

  // ── Score label mapping ─────────────────────────────────────────────────────

  describe("_scoreToLabel (via full pipeline)", function () {
    const cases = [
      { score: 0n,   label: 0 }, // TRUSTED
      { score: 25n,  label: 0 }, // TRUSTED
      { score: 26n,  label: 1 }, // CAUTION
      { score: 55n,  label: 1 }, // CAUTION
      { score: 56n,  label: 2 }, // HIGH_RISK
      { score: 79n,  label: 2 }, // HIGH_RISK
      { score: 80n,  label: 3 }, // UNVERIFIED
      { score: 100n, label: 3 }, // UNVERIFIED
    ];

    for (const { score, label } of cases) {
      it(`score ${score} → label ${label}`, async function () {
        const { alice, platform, registry, required } = await deploy();
        // Use a unique address per test case (derive from score)
        const target = ethers.getAddress(
          "0x" + score.toString().padStart(40, "0").slice(-40)
        );

        // Run pipeline — need sequential IDs
        const beforeId = await platform.nextRequestId();
        await registry.connect(alice).requestAssessment(
          target, 0, "0x00000000", { value: required }
        );
        await platform.fulfillRequest(beforeId, encodeString("data"));
        await platform.fulfillRequest(beforeId + 1n, encodeString("data"));
        await platform.fulfillRequest(beforeId + 2n, encodeUint256(score));

        const [, lbl] = await registry.getAssessment(target);
        expect(lbl).to.equal(label);
      });
    }
  });

  // ── Full pipeline happy path ─────────────────────────────────────────────────

  describe("Full pipeline", function () {
    it("stores TRUSTED assessment after 3-stage completion", async function () {
      const { alice, platform, registry, required } = await deploy();
      const target = alice.address;

      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        target, 0, "0x00000000", { value: required }
      );

      await platform.fulfillRequest(beforeId,       encodeString("TVL: 500M, verified: true"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("No exploits. Active GitHub."));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(15n));

      const [score, label, , , fresh] = await registry.getAssessment(target);
      expect(score).to.equal(15n);
      expect(label).to.equal(0); // TRUSTED
      expect(fresh).to.be.true;
    });

    it("emits AssessmentComplete event", async function () {
      const { alice, platform, registry, required } = await deploy();
      const target = alice.address;

      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        target, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("quant"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("qual"));

      await expect(
        platform.fulfillRequest(beforeId + 2n, encodeUint256(20n))
      )
        .to.emit(registry, "AssessmentComplete")
        .withArgs(target, 20n, 0n, 0n); // label=TRUSTED, jobId=0
    });

    it("stores evidenceSummary as quant | qual concatenation", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("QUANT_DATA"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("QUAL_DATA"));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(10n));

      const evidence = await registry.getEvidenceSummary(alice.address);
      expect(evidence).to.equal("QUANT_DATA | QUAL_DATA");
    });

    it("clamps out-of-range scores to 100", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("q"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));
      // Send 999 — should be clamped to 100
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(999n));

      const [score] = await registry.getAssessment(alice.address);
      expect(score).to.equal(100n);
    });
  });

  // ── Cache behaviour ─────────────────────────────────────────────────────────

  describe("Cache / TTL", function () {
    it("returns sentinel max uint256 for a cached assessment", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("q"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(10n));

      // Second call — should serve from cache
      const tx = await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      const receipt = await tx.wait();
      // Returned job ID should be type(uint256).max (cached sentinel)
      // We verify by confirming no new PipelineAdvanced events were emitted
      const events = receipt?.logs.filter(
        l => l.topics[0] === registry.interface.getEvent("PipelineAdvanced").topicHash
      );
      expect(events?.length).to.equal(0);
    });

    it("refunds full msg.value on cache hit", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("q"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(10n));

      const balanceBefore = await ethers.provider.getBalance(alice.address);
      const cacheTx = await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      const cacheReceipt = await cacheTx.wait();
      const gasUsed = cacheReceipt!.gasUsed * cacheReceipt!.gasPrice;
      const balanceAfter = await ethers.provider.getBalance(alice.address);

      // Net change should only be gas (full value refunded)
      const netLoss = balanceBefore - balanceAfter;
      expect(netLoss).to.equal(gasUsed);
    });
  });

  // ── Failure handling ────────────────────────────────────────────────────────

  describe("Failure handling", function () {
    it("stores UNVERIFIED on Stage 1 failure", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.failRequest(beforeId);

      const [score, label] = await registry.getAssessment(alice.address);
      expect(score).to.equal(100n);
      expect(label).to.equal(3); // UNVERIFIED
    });

    it("stores UNVERIFIED on Stage 2 timeout", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId, encodeString("quant data"));
      await platform.timeoutRequest(beforeId + 1n);

      const [, label] = await registry.getAssessment(alice.address);
      expect(label).to.equal(3); // UNVERIFIED
    });

    it("emits AssessmentFailed on pipeline failure", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await expect(platform.failRequest(beforeId))
        .to.emit(registry, "AssessmentFailed")
        .withArgs(alice.address, 0n);
    });

    it("reverts when deposit is insufficient", async function () {
      const { alice, registry, required } = await deploy();
      await expect(
        registry.connect(alice).requestAssessment(
          alice.address, 0, "0x00000000", { value: required - 1n }
        )
      ).to.be.revertedWithCustomError(registry, "InsufficientDeposit");
    });

    it("reverts handleResponse from non-platform caller", async function () {
      const { alice, bob, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      // bob tries to call handleResponse directly
      await expect(
        registry.connect(bob).handleResponse(beforeId, [], 0, {
          agentId: 0n,
          callbackContract: ethers.ZeroAddress,
          callbackSelector: "0x00000000",
          payload: "0x",
        })
      ).to.be.revertedWithCustomError(registry, "NotPlatform");
    });
  });

  // ── Read helpers ────────────────────────────────────────────────────────────

  describe("isHighRisk / isTrusted", function () {
    it("isTrusted returns true for score <= 25", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("q"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(20n));

      expect(await registry.isTrusted(alice.address)).to.be.true;
      expect(await registry.isHighRisk(alice.address)).to.be.false;
    });

    it("isHighRisk returns true for score >= 56", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("q"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(70n));

      expect(await registry.isHighRisk(alice.address)).to.be.true;
      expect(await registry.isTrusted(alice.address)).to.be.false;
    });

    it("isHighRisk returns true for UNVERIFIED (score >= 80)", async function () {
      const { alice, platform, registry, required } = await deploy();
      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        alice.address, 0, "0x00000000", { value: required }
      );
      await platform.fulfillRequest(beforeId,       encodeString("q"));
      await platform.fulfillRequest(beforeId + 1n,  encodeString("q"));
      await platform.fulfillRequest(beforeId + 2n,  encodeUint256(95n));

      expect(await registry.isHighRisk(alice.address)).to.be.true;
    });

    it("returns false for unassessed address", async function () {
      const { alice, registry } = await deploy();
      expect(await registry.isTrusted(alice.address)).to.be.false;
      expect(await registry.isHighRisk(alice.address)).to.be.false;
    });
  });

  // ── Admin ───────────────────────────────────────────────────────────────────

  describe("Admin", function () {
    it("owner can update agent IDs", async function () {
      const { registry } = await deploy();
      await expect(registry.setAgentIds(111n, 222n))
        .to.emit(registry, "AgentIdsUpdated")
        .withArgs(111n, 222n);
      expect(await registry.llmParseAgentId()).to.equal(111n);
      expect(await registry.llmInferAgentId()).to.equal(222n);
    });

    it("non-owner cannot update agent IDs", async function () {
      const { alice, registry } = await deploy();
      await expect(registry.connect(alice).setAgentIds(1n, 2n))
        .to.be.revertedWithCustomError(registry, "NotOwner");
    });

    it("owner can transfer ownership", async function () {
      const { owner, alice, registry } = await deploy();
      await registry.connect(owner).transferOwnership(alice.address);
      expect(await registry.owner()).to.equal(alice.address);
    });
  });

  // ── _toHexString correctness ────────────────────────────────────────────────
  // Regression for off-by-two bug where the loop started at i=39 instead of i=41,
  // causing the two most-significant nibbles of the address to be dropped from URLs.

  describe("_toHexString (via Stage1 URL payload)", function () {
    it("encodes leading non-zero bytes — 0x1F98... produces correct URL", async function () {
      // Use address 0x1F98431c8aD98523631AE4a59f267346ea31F984 as target (PROTOCOL type)
      // The platform createRequest payload will contain the Etherscan URL.
      // We check that the URL substring contains the full 42-char address.
      const { alice, platform, registry, required } = await deploy();
      const target = "0x1F98431c8aD98523631AE4a59f267346ea31F984";

      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        target, 1 /* PROTOCOL */, "0x00000000", { value: required }
      );

      // Read back the payload that was sent to the platform
      const req = await platform.pendingRequests(beforeId);
      const payloadHex: string = req.payload;

      // Decode payload as fetchString(string url, string selector)
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["string", "string"],
        // Strip the 4-byte function selector
        "0x" + payloadHex.slice(10)
      );
      const url: string = decoded[0];

      // The URL must contain the full 42-char checksummed address (case-insensitive)
      expect(url.toLowerCase()).to.include(target.toLowerCase());
    });

    it("encodes leading zero bytes — 0x0000...dead address is complete", async function () {
      const { alice, platform, registry, required } = await deploy();
      const target = "0x000000000000000000000000000000000000dEaD";

      const beforeId = await platform.nextRequestId();
      await registry.connect(alice).requestAssessment(
        target, 0 /* WALLET */, "0x00000000", { value: required }
      );

      const req = await platform.pendingRequests(beforeId);
      const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        ["string", "string"],
        "0x" + req.payload.slice(10)
      );
      const url: string = decoded[0];
      expect(url.toLowerCase()).to.include(target.toLowerCase());
    });
  });
});

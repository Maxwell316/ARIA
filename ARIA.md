# ARIA — Autonomous Risk Intelligence & Attestation Protocol
### Deep Technical Architecture, Product Requirements & Step-by-Step Build Guide
> Built on Somnia Agentic L1 | Somnia Agentathon Submission

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Product Requirements](#3-product-requirements)
4. [System Architecture](#4-system-architecture)
5. [Smart Contract Design](#5-smart-contract-design)
6. [Agent Pipeline Design](#6-agent-pipeline-design)
7. [Data Models](#7-data-models)
8. [API & External Data Sources](#8-api--external-data-sources)
9. [Frontend Architecture](#9-frontend-architecture)
10. [Step-by-Step Build Guide](#10-step-by-step-build-guide)
11. [Testing Strategy](#11-testing-strategy)
12. [Demo Script](#12-demo-script)
13. [Deployment Checklist](#13-deployment-checklist)

---

## 1. Executive Summary

ARIA is a **decentralized, composable due diligence registry** that any smart contract can call to get a verified, on-chain risk assessment of wallets, protocols, or projects — before executing a consequential transaction.

Today, DAO treasuries, lending markets, and launchpads do their due diligence manually, off-chain, and unverifiably. The result is rugs, exploits, and bad actors slipping through. ARIA replaces that human process with a three-stage autonomous agent pipeline — quantitative data aggregation, qualitative web intelligence, and LLM-synthesized scoring — all executed by Somnia validators and verified by consensus.

**The core value proposition:** Once an assessment is stored on-chain for a target address or protocol, any other smart contract can read it. ARIA is middleware. The registry becomes more valuable with every assessment added.

---

## 2. Problem Statement

### 2.1 The Due Diligence Gap

| Context | Current Process | Failure Mode |
|---|---|---|
| DAO treasury allocation | Multisig members vote after manual research | Research is off-chain, unverifiable, biased |
| Lending market credit | Static on-chain metrics (collateral ratio) | Ignores off-chain reputation & audit history |
| Launchpad vetting | Team reads whitepaper, checks GitHub | Easily gamed, no immutable record |
| Cross-protocol integration | Developer Googles the target protocol | No standard, no audit trail |

### 2.2 Why Existing Oracles Don't Solve This

- **Chainlink / Pyth:** Price feeds. Not risk analysis.
- **Proof of Humanity:** Identity, not protocol risk.
- **Nexus Mutual:** Insurance against risk, not assessment of it.
- **Manual multisig oracles:** Centralized trust, no reasoning trail.

### 2.3 What ARIA Provides That Doesn't Exist

1. **Composable on-chain risk scores** — readable by any contract
2. **Verifiable reasoning trail** — the evidence behind every score is stored
3. **Multi-source intelligence** — APIs + web scraping + LLM synthesis
4. **Deterministic reproducibility** — same inputs → same output, always

---

## 3. Product Requirements

### 3.1 Functional Requirements

| ID | Requirement | Priority |
|---|---|---|
| FR-01 | Any contract can call `requestAssessment(target, type)` | P0 |
| FR-02 | Assessment triggers a 3-stage agent pipeline | P0 |
| FR-03 | Results stored permanently on-chain with full evidence trail | P0 |
| FR-04 | Any contract can read stored assessments via `getAssessment(target)` | P0 |
| FR-05 | Consumer contracts receive callback on assessment completion | P0 |
| FR-06 | Assessments expire and can be refreshed after TTL | P1 |
| FR-07 | Assessment types: WALLET, PROTOCOL, TOKEN | P1 |
| FR-08 | Frontend dashboard to browse assessments | P1 |
| FR-09 | SDK for easy consumer contract integration | P2 |
| FR-10 | Governance to update scoring weights | P2 |

### 3.2 Non-Functional Requirements

| ID | Requirement | Target |
|---|---|---|
| NFR-01 | Assessment pipeline completion time | < 60 seconds |
| NFR-02 | Score reproducibility | 100% deterministic |
| NFR-03 | Uptime of registry reads | 100% (on-chain) |
| NFR-04 | Assessment cost to consumer | < 0.5 STT |
| NFR-05 | Evidence data stored and queryable forever | ✓ |

### 3.3 Assessment Types

```
WALLET   → Risk profile of an EOA or multisig
PROTOCOL → Risk profile of a deployed smart contract / protocol
TOKEN    → Risk profile of an ERC-20 token
```

### 3.4 Score Schema

```
Score:     0–100  (0 = lowest risk, 100 = highest risk)
Label:     TRUSTED | CAUTION | HIGH_RISK | UNVERIFIED
Confidence: LOW | MEDIUM | HIGH  (based on data availability)
```

---

## 4. System Architecture

### 4.1 High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      CONSUMER LAYER                          │
│  DAO Contract │ Lending Market │ Launchpad │ Any Protocol   │
└───────────────────────┬─────────────────────────────────────┘
                        │ requestAssessment()
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                    ARIA REGISTRY CONTRACT                     │
│  - Stores assessments[]                                      │
│  - Manages pending requests                                  │
│  - Routes callbacks to consumer contracts                    │
│  - Expiry & refresh logic                                    │
└───────────────────────┬─────────────────────────────────────┘
                        │ createRequest()
                        ▼
┌─────────────────────────────────────────────────────────────┐
│               SOMNIA PLATFORM CONTRACT                        │
│         (0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776)        │
└───────┬───────────────────────────────┬──────────────────────┘
        │                               │
        ▼                               ▼
┌───────────────┐               ┌───────────────┐
│  JSON API     │               │  LLM Parse    │
│  AGENT        │               │  Website      │
│  Stage 1      │               │  Agent        │
│  (Quant Data) │               │  Stage 2      │
└───────┬───────┘               └───────┬───────┘
        │                               │
        └──────────────┬────────────────┘
                       ▼
               ┌───────────────┐
               │  LLM Inference│
               │  Agent        │
               │  Stage 3      │
               │  (Synthesis)  │
               └───────┬───────┘
                       │
                       ▼  handleResponse()
┌─────────────────────────────────────────────────────────────┐
│                    ARIA REGISTRY CONTRACT                     │
│  Stores: Assessment { score, label, evidence, timestamp }   │
│  Emits:  AssessmentComplete(target, score, label)           │
│  Calls:  consumer.onAssessmentComplete(target, score, label)│
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Multi-Stage Pipeline Detail

Because Somnia agents are asynchronous (one `createRequest` per call), ARIA chains them using a **pipeline state machine**:

```
State: PENDING_STAGE_1
  → Stage 1 callback received
State: PENDING_STAGE_2
  → Stage 2 callback received
State: PENDING_STAGE_3
  → Stage 3 callback received
State: COMPLETE
  → Consumer callback fired
```

Each `requestId` maps to a `PipelineJob` that tracks which stage is active and accumulates data.

### 4.3 Data Flow Per Stage

```
Stage 1 (JSON API) Input:
  - DeFiLlama API    → TVL, chain presence, age
  - CoinGecko API    → token liquidity, volume, market cap
  - Etherscan API    → contract age, tx count, verified source

Stage 1 Output:
  - Struct: QuantData { tvl, age, txCount, liquidity, hasVerifiedSource }
  - Stored in: pipelineJobs[jobId].quantData

Stage 2 (LLM Parse Website) Input:
  - GitHub URL       → commit activity, contributor count, last commit date
  - Rekt.news        → search for protocol name in exploit database
  - Audit DB URLs    → Certik / Hacken / Code4rena results pages

Stage 2 Output:
  - String: qualEvidence (structured summary from LLM extraction)
  - Stored in: pipelineJobs[jobId].qualData

Stage 3 (LLM Inference) Input:
  - Combined: quantData + qualData + assessmentType
  - System prompt: risk analyst persona
  - Output constraints: score 0-100, label from allowedValues

Stage 3 Output:
  - uint256 score
  - string label
  - Triggers: storeAssessment() + consumerCallback()
```

---

## 5. Smart Contract Design

### 5.1 Contract Structure

```
contracts/
├── ARIARegistry.sol          # Core registry & pipeline orchestrator
├── ARIAConsumerBase.sol      # Base contract for easy integration
├── interfaces/
│   ├── IARIARegistry.sol     # Public interface for consumers
│   ├── IAgentRequester.sol   # Somnia platform interface
│   └── IJsonApiAgent.sol     # JSON API agent interface
├── libraries/
│   ├── AssessmentLib.sol     # Assessment struct & helpers
│   └── ScoringLib.sol        # Score → label conversion
└── examples/
    ├── ARIAGatedDAO.sol       # DAO that gates treasury via ARIA
    ├── ARIALendingMarket.sol  # Lending market with ARIA credit scoring
    └── ARIALaunchpad.sol      # Launchpad with ARIA vetting
```

### 5.2 Core Registry Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAgentRequester.sol";
import "./interfaces/IARIARegistry.sol";
import "./libraries/AssessmentLib.sol";

contract ARIARegistry is IAgentRequesterHandler {

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant JSON_API_AGENT_ID    = 13174292974160097713;
    uint256 public constant LLM_PARSE_AGENT_ID   = /* agent ID from docs */;
    uint256 public constant LLM_INFER_AGENT_ID   = /* agent ID from docs */;

    uint256 public constant SUBCOMMITTEE_SIZE     = 3;
    uint256 public constant JSON_PRICE_PER_AGENT  = 0.03 ether;
    uint256 public constant PARSE_PRICE_PER_AGENT = 0.10 ether;
    uint256 public constant INFER_PRICE_PER_AGENT = 0.07 ether;

    uint256 public constant ASSESSMENT_TTL        = 7 days;

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum AssessmentType  { WALLET, PROTOCOL, TOKEN }
    enum PipelineStage   { STAGE_1_QUANT, STAGE_2_QUAL, STAGE_3_SYNTH, COMPLETE }
    enum RiskLabel       { TRUSTED, CAUTION, HIGH_RISK, UNVERIFIED }
    enum ResponseStatus  { Success, Failed, TimedOut }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Assessment {
        address     target;
        uint256     score;           // 0-100
        RiskLabel   label;
        uint256     timestamp;
        uint256     expiry;
        string      evidenceSummary; // LLM-generated text stored on-chain
        uint256[]   requestIds;      // All Somnia request IDs for audit
        bool        exists;
    }

    struct PipelineJob {
        address         target;
        AssessmentType  assessmentType;
        address         requester;       // who called requestAssessment()
        bytes4          callbackSelector; // consumer's callback function
        PipelineStage   stage;
        string          quantData;       // accumulated from Stage 1
        string          qualData;        // accumulated from Stage 2
        uint256[]       requestIds;
        bool            active;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    IAgentRequester public immutable platform;

    // target → Assessment
    mapping(address => Assessment) public assessments;

    // Somnia requestId → jobId
    mapping(uint256 => uint256) public requestToJob;

    // jobId → PipelineJob
    mapping(uint256 => PipelineJob) public pipelineJobs;

    uint256 public nextJobId;

    // ─── Events ───────────────────────────────────────────────────────────────

    event AssessmentRequested(
        uint256 indexed jobId,
        address indexed target,
        address indexed requester
    );
    event PipelineStageComplete(
        uint256 indexed jobId,
        PipelineStage stage,
        uint256 requestId
    );
    event AssessmentComplete(
        address indexed target,
        uint256 score,
        RiskLabel label,
        uint256 jobId
    );

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address platform_) {
        platform = IAgentRequester(platform_);
    }

    // ─── External: Request Assessment ─────────────────────────────────────────

    /**
     * @notice Request a risk assessment for a target address.
     * @param target         The address to assess (wallet, protocol, or token).
     * @param assessmentType WALLET | PROTOCOL | TOKEN
     * @param callbackSelector  4-byte selector of consumer's callback function.
     *                          Pass bytes4(0) if no callback needed.
     */
    function requestAssessment(
        address        target,
        AssessmentType assessmentType,
        bytes4         callbackSelector
    ) external payable returns (uint256 jobId) {
        // If a fresh, unexpired assessment exists, return early
        Assessment storage existing = assessments[target];
        if (existing.exists && block.timestamp < existing.expiry) {
            if (callbackSelector != bytes4(0)) {
                // Fire callback immediately with cached result
                _fireConsumerCallback(
                    msg.sender, callbackSelector, target,
                    existing.score, existing.label
                );
            }
            return type(uint256).max; // sentinel: cached
        }

        // Stage 1 deposit calculation
        uint256 stage1Cost = platform.getRequestDeposit()
                           + JSON_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE;
        require(msg.value >= stage1Cost * 3 + 0.05 ether, "Underfunded");

        // Create pipeline job
        jobId = nextJobId++;
        pipelineJobs[jobId] = PipelineJob({
            target:           target,
            assessmentType:   assessmentType,
            requester:        msg.sender,
            callbackSelector: callbackSelector,
            stage:            PipelineStage.STAGE_1_QUANT,
            quantData:        "",
            qualData:         "",
            requestIds:       new uint256[](0),
            active:           true
        });

        emit AssessmentRequested(jobId, target, msg.sender);

        // Kick off Stage 1
        _launchStage1(jobId, target, assessmentType, stage1Cost);
    }

    // ─── Internal: Stage Launchers ────────────────────────────────────────────

    function _launchStage1(
        uint256 jobId,
        address target,
        AssessmentType aType,
        uint256 deposit
    ) internal {
        // Build URL and selector based on assessment type
        (string memory url, string memory selector) = _buildStage1Query(target, aType);

        bytes memory payload = abi.encodeWithSignature(
            "fetchString(string,string)",
            url,
            selector
        );

        uint256 requestId = platform.createRequest{value: deposit}(
            JSON_API_AGENT_ID,
            address(this),
            this.handleResponse.selector,
            payload
        );

        requestToJob[requestId] = jobId;
        pipelineJobs[jobId].requestIds.push(requestId);

        emit PipelineStageComplete(jobId, PipelineStage.STAGE_1_QUANT, requestId);
    }

    function _launchStage2(uint256 jobId) internal {
        PipelineJob storage job = pipelineJobs[jobId];
        uint256 deposit = platform.getRequestDeposit()
                        + PARSE_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE;

        string memory githubUrl = _buildGithubUrl(job.target);
        string memory query     = string(abi.encodePacked(
            "Extract: lastCommitDate, contributorCount, openIssues, repoAge"
        ));

        bytes memory payload = abi.encodeWithSignature(
            "searchAndExtract(string,string)",
            githubUrl,
            query
        );

        uint256 requestId = platform.createRequest{value: deposit}(
            LLM_PARSE_AGENT_ID,
            address(this),
            this.handleResponse.selector,
            payload
        );

        requestToJob[requestId] = jobId;
        job.requestIds.push(requestId);
        job.stage = PipelineStage.STAGE_2_QUAL;
    }

    function _launchStage3(uint256 jobId) internal {
        PipelineJob storage job = pipelineJobs[jobId];
        uint256 deposit = platform.getRequestDeposit()
                        + INFER_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE;

        string memory prompt = string(abi.encodePacked(
            "Quantitative data: ", job.quantData,
            "\nQualitative data: ", job.qualData,
            "\nAssessment type: ", _aTypeToString(job.assessmentType),
            "\nTarget: ", _toHexString(job.target),
            "\nScore this entity from 0 (lowest risk) to 100 (highest risk). ",
            "Return a JSON object with fields: score (integer), label (one of: ",
            "TRUSTED, CAUTION, HIGH_RISK, UNVERIFIED), evidence (2-3 sentence summary)."
        ));

        // Use inferNumber for score, then inferString for label in same callback
        bytes memory payload = abi.encodeWithSignature(
            "inferNumber(string,string,int256,int256)",
            "You are a blockchain risk analyst. Score precisely based on provided data.",
            prompt,
            int256(0),
            int256(100)
        );

        uint256 requestId = platform.createRequest{value: deposit}(
            LLM_INFER_AGENT_ID,
            address(this),
            this.handleResponse.selector,
            payload
        );

        requestToJob[requestId] = jobId;
        job.requestIds.push(requestId);
        job.stage = PipelineStage.STAGE_3_SYNTH;
    }

    // ─── Callback Handler ─────────────────────────────────────────────────────

    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory /* details */
    ) external override {
        require(msg.sender == address(platform), "Only platform");

        uint256 jobId = requestToJob[requestId];
        require(jobId != 0 || requestToJob[requestId] == 0, "Unknown request");

        PipelineJob storage job = pipelineJobs[jobId];
        require(job.active, "Job not active");

        if (status != ResponseStatus.Success || responses.length == 0) {
            // On failure, store UNVERIFIED assessment and notify consumer
            _storeFailedAssessment(jobId);
            return;
        }

        if (job.stage == PipelineStage.STAGE_1_QUANT) {
            job.quantData = abi.decode(responses[0].result, (string));
            _launchStage2(jobId);

        } else if (job.stage == PipelineStage.STAGE_2_QUAL) {
            job.qualData = abi.decode(responses[0].result, (string));
            _launchStage3(jobId);

        } else if (job.stage == PipelineStage.STAGE_3_SYNTH) {
            uint256 score = abi.decode(responses[0].result, (uint256));
            RiskLabel label = _scoreToLabel(score);

            _storeAssessment(jobId, score, label);
        }
    }

    // ─── Internal: Storage & Callbacks ───────────────────────────────────────

    function _storeAssessment(
        uint256 jobId,
        uint256 score,
        RiskLabel label
    ) internal {
        PipelineJob storage job = pipelineJobs[jobId];

        assessments[job.target] = Assessment({
            target:          job.target,
            score:           score,
            label:           label,
            timestamp:       block.timestamp,
            expiry:          block.timestamp + ASSESSMENT_TTL,
            evidenceSummary: string(abi.encodePacked(job.quantData, " | ", job.qualData)),
            requestIds:      job.requestIds,
            exists:          true
        });

        job.active = false;
        job.stage  = PipelineStage.COMPLETE;

        emit AssessmentComplete(job.target, score, label, jobId);

        if (job.callbackSelector != bytes4(0)) {
            _fireConsumerCallback(
                job.requester, job.callbackSelector,
                job.target, score, label
            );
        }
    }

    function _fireConsumerCallback(
        address consumer,
        bytes4  selector,
        address target,
        uint256 score,
        RiskLabel label
    ) internal {
        bytes memory data = abi.encodeWithSelector(
            selector,
            target,
            score,
            uint8(label)
        );
        (bool ok, ) = consumer.call(data);
        // Non-reverting: consumer callback failure doesn't block registry
        if (!ok) emit CallbackFailed(consumer, target);
    }

    // ─── External: Read Assessment ────────────────────────────────────────────

    function getAssessment(address target)
        external view
        returns (
            uint256 score,
            uint8   label,
            uint256 timestamp,
            uint256 expiry,
            bool    fresh
        )
    {
        Assessment storage a = assessments[target];
        return (
            a.score,
            uint8(a.label),
            a.timestamp,
            a.expiry,
            a.exists && block.timestamp < a.expiry
        );
    }

    function isHighRisk(address target) external view returns (bool) {
        Assessment storage a = assessments[target];
        return a.exists && a.label == RiskLabel.HIGH_RISK;
    }

    function isTrusted(address target) external view returns (bool) {
        Assessment storage a = assessments[target];
        return a.exists && a.label == RiskLabel.TRUSTED && block.timestamp < a.expiry;
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _scoreToLabel(uint256 score) internal pure returns (RiskLabel) {
        if (score <= 25) return RiskLabel.TRUSTED;
        if (score <= 55) return RiskLabel.CAUTION;
        if (score <= 79) return RiskLabel.HIGH_RISK;
        return RiskLabel.UNVERIFIED;
    }

    function _buildStage1Query(address target, AssessmentType aType)
        internal pure
        returns (string memory url, string memory selector)
    {
        if (aType == AssessmentType.PROTOCOL) {
            url      = string(abi.encodePacked(
                "https://api.llama.fi/protocol/", _toHexString(target)
            ));
            selector = "tvl";
        } else if (aType == AssessmentType.TOKEN) {
            url      = "https://api.coingecko.com/api/v3/coins/ethereum";
            selector = "market_data.total_volume.usd";
        } else {
            url      = string(abi.encodePacked(
                "https://api.etherscan.io/api?module=account&action=txlist&address=",
                _toHexString(target)
            ));
            selector = "result.0.timeStamp";
        }
    }

    receive() external payable {}
    event CallbackFailed(address consumer, address target);
}
```

### 5.3 Consumer Base Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IARIARegistry.sol";

/**
 * @notice Inherit this to integrate ARIA in one line.
 */
abstract contract ARIAConsumerBase {

    IARIARegistry public immutable ariaRegistry;

    constructor(address registry_) {
        ariaRegistry = IARIARegistry(registry_);
    }

    /**
     * @notice Override this to handle ARIA callbacks.
     */
    function onAssessmentComplete(
        address target,
        uint256 score,
        uint8   label
    ) external virtual {
        require(msg.sender == address(ariaRegistry), "Only ARIA");
        _onAssessmentComplete(target, score, label);
    }

    function _onAssessmentComplete(
        address target,
        uint256 score,
        uint8   label
    ) internal virtual;

    /**
     * @notice Reverts if target is not TRUSTED by ARIA.
     */
    modifier onlyTrusted(address target) {
        require(ariaRegistry.isTrusted(target), "ARIA: target not trusted");
        _;
    }

    /**
     * @notice Reverts if target is HIGH_RISK by ARIA.
     */
    modifier notHighRisk(address target) {
        require(!ariaRegistry.isHighRisk(target), "ARIA: target is high risk");
        _;
    }
}
```

### 5.4 Example Consumer: DAO Treasury Guard

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ARIAConsumerBase.sol";

contract ARIAGatedDAO is ARIAConsumerBase {

    struct Proposal {
        address recipient;
        uint256 amount;
        string  description;
        uint256 votes;
        bool    vetted;
        bool    executed;
        bool    blocked;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(address => bool)     public members;
    uint256 public nextProposalId;
    uint256 public constant RISK_THRESHOLD = 60; // block if score > 60

    event ProposalVetted(uint256 indexed id, uint256 ariaScore, bool blocked);

    constructor(address registry_) ARIAConsumerBase(registry_) {}

    function submitProposal(address recipient, uint256 amount, string calldata desc)
        external payable
        returns (uint256 id)
    {
        id = nextProposalId++;
        proposals[id] = Proposal(recipient, amount, desc, 0, false, false, false);

        // Immediately request ARIA assessment of the recipient
        ariaRegistry.requestAssessment{value: msg.value}(
            recipient,
            IARIARegistry.AssessmentType.WALLET,
            this.onAssessmentComplete.selector
        );
    }

    function _onAssessmentComplete(
        address target,
        uint256 score,
        uint8   /* label */
    ) internal override {
        // Find the proposal for this recipient
        for (uint256 i = 0; i < nextProposalId; i++) {
            if (proposals[i].recipient == target && !proposals[i].vetted) {
                proposals[i].vetted  = true;
                proposals[i].blocked = score > RISK_THRESHOLD;
                emit ProposalVetted(i, score, proposals[i].blocked);
                break;
            }
        }
    }

    function executeProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(p.vetted,    "Not vetted by ARIA yet");
        require(!p.blocked,  "Blocked: high ARIA risk score");
        require(!p.executed, "Already executed");
        p.executed = true;
        payable(p.recipient).transfer(p.amount);
    }

    receive() external payable {}
}
```

---

## 6. Agent Pipeline Design

### 6.1 Stage 1 — JSON API Queries (Per Assessment Type)

**PROTOCOL assessment — 3 parallel conceptual queries:**

```
Query 1: DeFiLlama
  URL:      https://api.llama.fi/protocol/{slug}
  Extract:  tvl, audits[].name, category, chains[]

Query 2: Etherscan
  URL:      https://api.etherscan.io/api?module=contract&action=getsourcecode&address={target}
  Extract:  SourceCode (non-empty = verified), ContractName

Query 3: CoinGecko (if token)
  URL:      https://api.coingecko.com/api/v3/coins/{id}
  Extract:  market_data.market_cap.usd, market_data.total_volume.usd
```

> **Note:** Somnia's JSON API agent handles one URL per `createRequest`. Chain multiple calls in the pipeline, or encode the most critical one for Stage 1.

### 6.2 Stage 2 — LLM Parse Website Queries

```
Query 1: GitHub Activity
  Mode:    direct
  URL:     https://github.com/{org}/{repo}
  Extract: lastCommitDate, contributorCount, openIssues, stars, forks

Query 2: Rekt Database
  Mode:    search
  Domain:  rekt.news
  Query:   "{protocol name} exploit hack"
  Extract: title, date, amount_lost (if any results found)

Query 3: Audit Reports
  Mode:    search
  Domain:  certik.com OR hacken.io
  Query:   "{protocol name} audit report"
  Extract: auditDate, critical_findings, medium_findings, auditor
```

### 6.3 Stage 3 — LLM Inference Synthesis

**System Prompt:**
```
You are a senior DeFi risk analyst with expertise in smart contract security,
protocol economics, and on-chain forensics. You produce objective, evidence-based
risk scores. You never speculate beyond the provided data. You penalize heavily
for: unverified contracts, recent exploits, anonymous teams with no GitHub
activity, and very low liquidity. You reward: long track records, multiple
audits from reputable firms, high TVL stability, active development.
```

**User Prompt Structure:**
```
TARGET: {address}
TYPE: {WALLET | PROTOCOL | TOKEN}

=== QUANTITATIVE DATA (Stage 1) ===
{quantData string}

=== QUALITATIVE DATA (Stage 2) ===
{qualData string}

=== SCORING TASK ===
Produce a risk score from 0 to 100 where:
  0-25:  TRUSTED   (established, audited, long track record)
  26-55: CAUTION   (mixed signals, limited history, or minor concerns)
  56-79: HIGH_RISK (unverified, exploited, or very new with no audits)
  80-100: UNVERIFIED (no meaningful data found)

Return ONLY a single integer representing the score.
```

### 6.4 inferToolsChat for Autonomous Edge Cases

When Stage 3 returns score in the 40–60 range (ambiguous), ARIA optionally triggers a `Stage 3b` using `inferToolsChat`:

```solidity
// Stage 3b: Autonomous deep-dive on ambiguous scores
bytes memory toolsPayload = abi.encodeWithSignature(
    "inferToolsChat(string,string,string[])",
    systemPrompt,
    string(abi.encodePacked(
        "Score was ", Strings.toString(score), "/100 - AMBIGUOUS. ",
        "Autonomously investigate further. You may fetch additional URLs ",
        "to resolve uncertainty. Provide final score with higher confidence."
    )),
    additionalTools
);
```

The model autonomously decides what to look up, fetches it, and returns a higher-confidence score. **This is the autonomy moment** — the agent self-directs its investigation.

---

## 7. Data Models

### 7.1 On-Chain Structs (Solidity)

```
Assessment {
    address  target           // assessed address
    uint256  score            // 0-100
    RiskLabel label           // TRUSTED|CAUTION|HIGH_RISK|UNVERIFIED
    uint256  timestamp        // when assessed
    uint256  expiry           // timestamp + TTL
    string   evidenceSummary  // LLM-generated explanation (stored on-chain)
    uint256[] requestIds      // all Somnia request IDs (full audit trail)
    bool     exists
}

PipelineJob {
    address        target
    AssessmentType assessmentType
    address        requester
    bytes4         callbackSelector
    PipelineStage  stage
    string         quantData
    string         qualData
    uint256[]      requestIds
    bool           active
}
```

### 7.2 Off-Chain Frontend Data (TypeScript)

```typescript
interface AssessmentDisplay {
  target: string;
  score: number;
  label: 'TRUSTED' | 'CAUTION' | 'HIGH_RISK' | 'UNVERIFIED';
  timestamp: number;
  expiry: number;
  evidenceSummary: string;
  requestIds: string[];
  isFresh: boolean;
}

interface PipelineStatus {
  jobId: string;
  target: string;
  stage: 'STAGE_1' | 'STAGE_2' | 'STAGE_3' | 'COMPLETE';
  progress: number; // 0-100
}
```

---

## 8. API & External Data Sources

| Source | Purpose | Endpoint | Free Tier |
|---|---|---|---|
| DeFiLlama | Protocol TVL | `https://api.llama.fi/protocol/{slug}` | ✅ Unlimited |
| Etherscan | Contract verification | `https://api.etherscan.io/api` | ✅ 5 req/s |
| CoinGecko | Token market data | `https://api.coingecko.com/api/v3` | ✅ 30 req/min |
| GitHub | Repo activity | `https://api.github.com/repos/{org}/{repo}` | ✅ 60 req/hr |
| Rekt.news | Exploit history | Scrape via LLM Parse Website | ✅ |
| Certik | Audit reports | Scrape via LLM Parse Website | ✅ |
| Code4rena | Audit contests | Scrape via LLM Parse Website | ✅ |

---

## 9. Frontend Architecture

### 9.1 Stack

```
Next.js 14 (App Router)
Wagmi v2 + Viem         ← contract interaction
TailwindCSS             ← styling
shadcn/ui               ← components
ethers.js               ← event listening
Somnia Testnet RPC      ← https://dream-rpc.somnia.network
```

### 9.2 Pages

```
/                        → Landing + search bar
/assess/{address}        → Live assessment page (shows pipeline progress)
/registry                → Browse all stored assessments
/integrate               → Integration guide + code snippets
```

### 9.3 Key Component: Live Pipeline Progress

```typescript
// hooks/usePipelineStatus.ts
export function usePipelineStatus(jobId: bigint) {
  const [stage, setStage] = useState<PipelineStage>('STAGE_1');

  useEffect(() => {
    const unwatch = watchContractEvent({
      address: ARIA_REGISTRY_ADDRESS,
      abi: ARIARegistryABI,
      eventName: 'PipelineStageComplete',
      onLogs: (logs) => {
        const relevant = logs.find(l => l.args.jobId === jobId);
        if (relevant) setStage(relevant.args.stage);
      }
    });
    return () => unwatch();
  }, [jobId]);

  return stage;
}
```

---

## 10. Step-by-Step Build Guide

### Prerequisites

```bash
node >= 18
foundry (forge, cast, anvil)
git
An STT-funded wallet on Somnia Testnet
Somnia Testnet RPC: https://dream-rpc.somnia.network
Platform contract: 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776
```

---

### Day 1 — Foundation: Single-Stage Pipeline Working End-to-End

**Step 1.1 — Initialize project**
```bash
mkdir aria-protocol && cd aria-protocol
forge init --no-commit
mkdir -p src/interfaces src/libraries src/examples frontend
```

**Step 1.2 — Install dependencies**
```bash
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std
```

**Step 1.3 — Copy Somnia interfaces**

Create `src/interfaces/IAgentRequester.sol` with the full Somnia interface from their docs. You need:
```solidity
struct Response { bytes result; uint256 validatorId; }
struct Request  { uint256 agentId; address callbackContract; bytes4 callbackSelector; }
enum ResponseStatus { Success, Failed, TimedOut }

interface IAgentRequester {
    function createRequest(uint256 agentId, address callbackContract,
                           bytes4 callbackSelector, bytes calldata payload)
        external payable returns (uint256 requestId);
    function getRequestDeposit() external view returns (uint256);
}

interface IAgentRequesterHandler {
    function handleResponse(uint256 requestId, Response[] memory responses,
                            ResponseStatus status, Request memory details) external;
}
```

**Step 1.4 — Build the simplest possible version first**

Create `src/ARIAv1Simple.sol` — just Stage 1 (JSON API) with one query:
```solidity
// Single stage: fetch TVL for a protocol and store it
// This is your "does the callback work" proof before building the full pipeline
```

**Step 1.5 — Deploy to testnet**
```bash
# In your .env:
PRIVATE_KEY=0x...
RPC_URL=https://dream-rpc.somnia.network
PLATFORM=0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776

source .env
forge script script/DeployARIAv1Simple.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast
```

**Step 1.6 — Test Stage 1 callback**
```bash
cast send $ARIA_V1_ADDR \
    "requestAssessment(address,uint8,bytes4)" \
    0xSomeProtocolAddress 1 0x00000000 \
    --value 0.15ether \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL
```

Watch for the `AssessmentComplete` event using:
```bash
cast logs --address $ARIA_V1_ADDR \
    --from-block latest \
    --rpc-url $RPC_URL
```

**✅ Day 1 Goal:** See a `requestId` returned and a callback with quantitative data. One working loop.

---

### Day 2 — Stage 2: Add LLM Parse Website

**Step 2.1 — Add LLM Parse Website agent ID**

Check Somnia Testnet Agent Explorer at `https://agents.testnet.somnia.network/` and get the agent ID for LLM Parse Website.

**Step 2.2 — Add pipeline state machine to ARIARegistry.sol**

Add the `PipelineJob` struct, `pipelineJobs` mapping, `requestToJob` mapping, and the stage enum. This is the core orchestration logic.

**Step 2.3 — Implement `_launchStage2`**

In `handleResponse`, when `stage == STAGE_1_QUANT`:
1. Decode and store `quantData`
2. Call `_launchStage2(jobId)`

**Step 2.4 — Test two-stage pipeline**
```bash
# Fund contract more heavily (Stage 1 + Stage 2 costs)
cast send $ARIA_ADDR "requestAssessment(address,uint8,bytes4)" \
    0xUniswapV3Address 1 0x00000000 \
    --value 0.5ether \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL
```

Check that `pipelineJobs[jobId].qualData` is populated after both callbacks fire.

**✅ Day 2 Goal:** `quantData` and `qualData` both populated on-chain for a protocol address.

---

### Day 3 — Stage 3: LLM Synthesis → Risk Score

**Step 3.1 — Implement `_launchStage3`**

Build the combined prompt string from `quantData + qualData` and call `inferNumber` with range 0–100.

**Step 3.2 — Implement `_storeAssessment`**

On Stage 3 callback: decode the score, call `_scoreToLabel()`, write the `Assessment` struct, emit `AssessmentComplete`.

**Step 3.3 — Implement `getAssessment` and `isTrusted`/`isHighRisk` read functions**

These are the public-facing registry reads that consumer contracts use.

**Step 3.4 — Full pipeline test**
```bash
# Watch all three PipelineStageComplete events fire sequentially
cast logs --address $ARIA_ADDR --rpc-url $RPC_URL

# Read the stored assessment
cast call $ARIA_ADDR \
    "getAssessment(address)" \
    0xUniswapV3Address \
    --rpc-url $RPC_URL
```

**✅ Day 3 Goal:** Full 3-stage pipeline storing a score + label on-chain. The core product works.

---

### Day 4 — Consumer Contracts & Composability Demo

**Step 4.1 — Deploy ARIAConsumerBase.sol**

**Step 4.2 — Deploy ARIAGatedDAO.sol**

```bash
forge script script/DeployARIAGatedDAO.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast
```

**Step 4.3 — Test the DAO flow**
```bash
# Submit proposal for a HIGH_RISK target
cast send $DAO_ADDR \
    "submitProposal(address,uint256,string)" \
    0xSuspiciousAddress 1000000000000000000 "Pay this protocol" \
    --value 0.5ether \
    --private-key $PRIVATE_KEY \
    --rpc-url $RPC_URL

# Wait for ARIA callback (~30s)
# Try to execute — should revert with "Blocked: high ARIA risk score"
cast send $DAO_ADDR "executeProposal(uint256)" 0 \
    --private-key $PRIVATE_KEY --rpc-url $RPC_URL
# Expected: revert "Blocked: high ARIA risk score"
```

**Step 4.4 — Deploy ARIALendingMarket.sol (stretch)**

Lending market that offers 80% LTV to TRUSTED addresses, 60% to CAUTION, and blocks HIGH_RISK borrowers.

**✅ Day 4 Goal:** Two consumer contracts working. The composability story is live.

---

### Day 5 — Frontend, Polish & Demo Video

**Step 5.1 — Bootstrap frontend**
```bash
cd frontend
npx create-next-app@latest . --typescript --tailwind --app
npm install wagmi viem @tanstack/react-query
npm install @shadcn/ui
```

**Step 5.2 — Configure Somnia Testnet in Wagmi**
```typescript
// lib/wagmi.ts
import { createConfig, http } from 'wagmi';
import { defineChain } from 'viem';

const somniaTestnet = defineChain({
  id: 50312,
  name: 'Somnia Testnet',
  nativeCurrency: { name: 'STT', symbol: 'STT', decimals: 18 },
  rpcUrls: { default: { http: ['https://dream-rpc.somnia.network'] } },
});

export const config = createConfig({
  chains: [somniaTestnet],
  transports: { [somniaTestnet.id]: http() },
});
```

**Step 5.3 — Build search + assessment UI**

Key views:
- Search bar → enter any address
- Pipeline progress bar (Stage 1 → 2 → 3)
- Score display with color coding (green/yellow/red)
- Evidence summary from on-chain `evidenceSummary`
- Links to Somnia explorer for each `requestId`

**Step 5.4 — Record demo video (2-5 min)**

Script:
1. (00:00–00:30) Problem statement: "DAOs lose millions because due diligence is manual and unverifiable."
2. (00:30–01:30) Demo 1: Submit a TRUSTED protocol → ARIA approves → DAO executes
3. (01:30–02:30) Demo 2: Submit HIGH_RISK protocol → ARIA blocks → DAO reverts
4. (02:30–03:30) Show on-chain evidence trail in Somnia explorer
5. (03:30–04:00) "Any contract can read this registry — this is composable DeFi risk infrastructure."
6. (04:00–04:30) Real-world angle: "Emerging market DeFi users most exposed to rugs — ARIA levels the playing field."

---

## 11. Testing Strategy

### Unit Tests (Foundry)

```bash
# Run all tests
forge test -vvv

# Test files:
test/ARIARegistry.t.sol       # core pipeline logic
test/ARIAGatedDAO.t.sol       # consumer integration
test/ScoringLib.t.sol         # score → label conversion
```

**Key test cases:**
```solidity
// Test 1: Fresh assessment bypasses pipeline
function test_cachedAssessmentFiresCallbackImmediately() { ... }

// Test 2: Callback gating
function test_onlyPlatformCanCallback() { ... }

// Test 3: Score labeling boundaries
function test_scoreLabelBoundaries() {
    assertEq(_scoreToLabel(0),   RiskLabel.TRUSTED);
    assertEq(_scoreToLabel(25),  RiskLabel.TRUSTED);
    assertEq(_scoreToLabel(26),  RiskLabel.CAUTION);
    assertEq(_scoreToLabel(55),  RiskLabel.CAUTION);
    assertEq(_scoreToLabel(56),  RiskLabel.HIGH_RISK);
    assertEq(_scoreToLabel(79),  RiskLabel.HIGH_RISK);
    assertEq(_scoreToLabel(80),  RiskLabel.UNVERIFIED);
}

// Test 4: DAO blocks high-risk recipient
function test_DAOBlocksHighRiskProposal() { ... }

// Test 5: Pipeline handles TimedOut gracefully
function test_pipelineHandlesTimeout() { ... }
```

---

## 12. Demo Script

### Demo 1: DAO Treasury Guard (Lead with this)

| Step | Action | Expected |
|---|---|---|
| 1 | Submit proposal: recipient = Uniswap V3 (trusted protocol) | `AssessmentRequested` event |
| 2 | Wait ~30s for pipeline | `AssessmentComplete` event: score ~15, TRUSTED |
| 3 | Call `executeProposal(0)` | ✅ Transfer executes |
| 4 | Submit proposal: recipient = fresh wallet, 1 day old, no code | `AssessmentRequested` event |
| 5 | Wait ~30s | `AssessmentComplete`: score ~80, HIGH_RISK |
| 6 | Call `executeProposal(1)` | ❌ Reverts: "Blocked: high ARIA risk score" |

### Demo 2: Composability

```bash
# Show any address can query the registry for free
cast call $ARIA_ADDR "getAssessment(address)(uint256,uint8,uint256,uint256,bool)" \
    0xUniswapV3Address --rpc-url $RPC_URL
# Returns: score=15, label=0 (TRUSTED), timestamp=..., fresh=true
```

### Demo 3: On-Chain Audit Trail

Open Somnia Testnet explorer. Show:
- The `handleResponse` transaction for each stage
- The `evidenceSummary` string stored on-chain
- All three `requestId` values in the `Assessment` struct

---

## 13. Deployment Checklist

```
□ ARIARegistry deployed to Somnia Testnet
□ ARIAGatedDAO deployed, pointed at ARIARegistry
□ ARIALendingMarket deployed (stretch)
□ Frontend deployed (Vercel)
□ GitHub repo public with:
  □ README.md with architecture diagram
  □ .env.example (no private keys)
  □ All contracts in /contracts
  □ Deployment addresses in /deployments/testnet.json
  □ Frontend in /frontend
□ Demo video uploaded (YouTube unlisted or Loom)
□ Demo video link in README
□ Somnia Testnet explorer links for:
  □ ARIARegistry contract
  □ A completed assessment transaction
  □ A blocked DAO proposal
```

---

## Repository Structure

```
aria-protocol/
├── README.md
├── foundry.toml
├── .env.example
├── contracts/
│   ├── src/
│   │   ├── ARIARegistry.sol
│   │   ├── ARIAConsumerBase.sol
│   │   ├── interfaces/
│   │   │   ├── IARIARegistry.sol
│   │   │   └── IAgentRequester.sol
│   │   ├── libraries/
│   │   │   └── ScoringLib.sol
│   │   └── examples/
│   │       ├── ARIAGatedDAO.sol
│   │       └── ARIALendingMarket.sol
│   ├── test/
│   │   ├── ARIARegistry.t.sol
│   │   └── ARIAGatedDAO.t.sol
│   └── script/
│       ├── DeployARIA.s.sol
│       └── DeployExamples.s.sol
├── frontend/
│   ├── app/
│   │   ├── page.tsx
│   │   ├── assess/[address]/page.tsx
│   │   └── registry/page.tsx
│   ├── components/
│   │   ├── ScoreBadge.tsx
│   │   ├── PipelineProgress.tsx
│   │   └── AssessmentCard.tsx
│   ├── hooks/
│   │   ├── useRequestAssessment.ts
│   │   └── usePipelineStatus.ts
│   └── lib/
│       ├── wagmi.ts
│       └── aria.ts
└── deployments/
    └── testnet.json
```

---

*ARIA — Built for the Somnia Agentathon. Making DeFi due diligence trustless, verifiable, and composable.*

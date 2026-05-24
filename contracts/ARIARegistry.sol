// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAgentRequester.sol";
import "./interfaces/IARIARegistry.sol";

/// @title ARIARegistry
/// @notice Decentralized risk assessment registry built on Somnia Agentic L1.
///
///   Flow:
///     1. Consumer calls requestAssessment(target, type, callback) with ETH.
///     2. Registry launches Stage 1 (JSON API agent) via Somnia platform.
///     3. On Stage 1 callback → launches Stage 2 (LLM Parse Website agent).
///     4. On Stage 2 callback → launches Stage 3 (LLM Inference agent).
///     5. On Stage 3 callback → stores Assessment on-chain, fires consumer callback.
///
///   Any contract can read stored assessments for free via getAssessment().
///   Assessments expire after ASSESSMENT_TTL (7 days) and can be refreshed.
contract ARIARegistry is IARIARegistry, IAgentRequesterHandler {

    // ─── Agent IDs (Somnia testnet) ───────────────────────────────────────────
    // JSON API agent ID — fetches external API data
    uint256 public constant JSON_API_AGENT_ID = 13174292974160097713;
    // LLM Parse Website and LLM Inference IDs are set at deploy time (see agents.testnet.somnia.network)
    uint256 public llmParseAgentId;
    uint256 public llmInferAgentId;

    // ─── Pricing constants ────────────────────────────────────────────────────
    uint256 public constant SUBCOMMITTEE_SIZE     = 3;
    uint256 public constant JSON_PRICE_PER_AGENT  = 0.03 ether;
    uint256 public constant PARSE_PRICE_PER_AGENT = 0.10 ether;
    uint256 public constant INFER_PRICE_PER_AGENT = 0.07 ether;
    uint256 public constant DEPOSIT_BUFFER        = 0.05 ether;

    // ─── Assessment TTL ───────────────────────────────────────────────────────
    uint256 public constant ASSESSMENT_TTL = 7 days;

    // ─── Internal pipeline stage (not exposed in interface) ───────────────────
    enum PipelineStage { STAGE_1_QUANT, STAGE_2_QUAL, STAGE_3_SYNTH, COMPLETE }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct Assessment {
        address   target;
        uint256   score;           // 0 = lowest risk, 100 = highest risk
        RiskLabel label;
        uint256   timestamp;
        uint256   expiry;
        string    evidenceSummary; // concatenated Stage 1 + Stage 2 data
        uint256[] requestIds;      // all Somnia requestIds for this assessment
        bool      exists;
    }

    struct PipelineJob {
        address        target;
        AssessmentType assessmentType;
        address        requester;
        bytes4         callbackSelector;
        PipelineStage  stage;
        string         quantData;    // accumulated from Stage 1
        string         qualData;     // accumulated from Stage 2
        uint256[]      requestIds;
        uint256        balance;      // remaining ETH allocated to this job
        bool           active;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    IAgentRequester public immutable platform;
    address         public           owner;

    mapping(address => Assessment)  public assessments;
    mapping(uint256 => PipelineJob) public pipelineJobs;
    mapping(uint256 => uint256)     public requestToJob;      // requestId → jobId
    mapping(uint256 => bool)        internal requestRegistered;

    uint256 public nextJobId;

    // ─── Events ───────────────────────────────────────────────────────────────

    event PipelineAdvanced(uint256 indexed jobId, PipelineStage stage, uint256 requestId);
    event AssessmentFailed(address indexed target, uint256 jobId);
    event CallbackFailed(address indexed consumer, address indexed target);
    event AgentIdsUpdated(uint256 parseAgentId, uint256 inferAgentId);
    event OwnershipTransferred(address indexed previous, address indexed next);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotPlatform();
    error UnknownRequest();
    error JobNotActive();
    error InsufficientDeposit(uint256 required, uint256 provided);
    error ZeroAddress();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param platform_        Address of the Somnia IAgentRequester platform contract.
    /// @param llmParseAgentId_ Agent ID for LLM Parse Website (from agents.testnet.somnia.network).
    /// @param llmInferAgentId_ Agent ID for LLM Inference (from agents.testnet.somnia.network).
    constructor(
        address platform_,
        uint256 llmParseAgentId_,
        uint256 llmInferAgentId_
    ) {
        if (platform_ == address(0)) revert ZeroAddress();
        platform       = IAgentRequester(platform_);
        owner          = msg.sender;
        llmParseAgentId = llmParseAgentId_;
        llmInferAgentId = llmInferAgentId_;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setAgentIds(uint256 parseId, uint256 inferId) external onlyOwner {
        llmParseAgentId = parseId;
        llmInferAgentId = inferId;
        emit AgentIdsUpdated(parseId, inferId);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Withdraw accumulated ETH (excess deposits, failed refunds) to owner.
    function withdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    // ─── IARIARegistry: getRequiredDeposit ───────────────────────────────────

    /// @notice Full ETH cost for a 3-stage assessment (Stage1 + Stage2 + Stage3 + buffer).
    function getRequiredDeposit() public view override returns (uint256) {
        uint256 base = platform.getRequestDeposit();
        return (base * 3)
            + (JSON_PRICE_PER_AGENT  * SUBCOMMITTEE_SIZE)
            + (PARSE_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE)
            + (INFER_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE)
            + DEPOSIT_BUFFER;
    }

    // ─── IARIARegistry: requestAssessment ────────────────────────────────────

    function requestAssessment(
        address        target,
        AssessmentType assessmentType,
        bytes4         callbackSelector
    ) external payable override returns (uint256 jobId) {
        // Serve from cache if a fresh assessment already exists
        Assessment storage existing = assessments[target];
        if (existing.exists && block.timestamp < existing.expiry) {
            if (callbackSelector != bytes4(0)) {
                _fireConsumerCallback(
                    msg.sender, callbackSelector,
                    target, existing.score, existing.label
                );
            }
            // Refund the entire msg.value — no pipeline needed
            if (msg.value > 0) {
                (bool ok, ) = payable(msg.sender).call{value: msg.value}("");
                require(ok, "Refund failed");
            }
            return type(uint256).max; // sentinel: served from cache
        }

        uint256 required = getRequiredDeposit();
        if (msg.value < required) {
            revert InsufficientDeposit(required, msg.value);
        }

        // Create the pipeline job
        jobId = nextJobId++;
        uint256[] memory emptyIds = new uint256[](0);
        pipelineJobs[jobId] = PipelineJob({
            target:           target,
            assessmentType:   assessmentType,
            requester:        msg.sender,
            callbackSelector: callbackSelector,
            stage:            PipelineStage.STAGE_1_QUANT,
            quantData:        "",
            qualData:         "",
            requestIds:       emptyIds,
            balance:          msg.value,
            active:           true
        });

        emit AssessmentRequested(jobId, target, msg.sender);

        _launchStage1(jobId);
    }

    // ─── Stage 1: JSON API (Quantitative data) ────────────────────────────────

    function _launchStage1(uint256 jobId) internal {
        PipelineJob storage job = pipelineJobs[jobId];
        uint256 deposit = platform.getRequestDeposit()
                        + JSON_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE;

        (string memory url, string memory selector) =
            _buildStage1Query(job.target, job.assessmentType);

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

        job.balance -= deposit;
        job.requestIds.push(requestId);
        requestToJob[requestId]      = jobId;
        requestRegistered[requestId] = true;

        emit PipelineAdvanced(jobId, PipelineStage.STAGE_1_QUANT, requestId);
    }

    // ─── Stage 2: LLM Parse Website (Qualitative data) ───────────────────────

    function _launchStage2(uint256 jobId) internal {
        PipelineJob storage job = pipelineJobs[jobId];
        uint256 deposit = platform.getRequestDeposit()
                        + PARSE_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE;

        (string memory url, string memory query) =
            _buildStage2Query(job.target, job.assessmentType);

        bytes memory payload = abi.encodeWithSignature(
            "searchAndExtract(string,string)",
            url,
            query
        );

        uint256 requestId = platform.createRequest{value: deposit}(
            llmParseAgentId,
            address(this),
            this.handleResponse.selector,
            payload
        );

        job.balance -= deposit;
        job.requestIds.push(requestId);
        job.stage = PipelineStage.STAGE_2_QUAL;
        requestToJob[requestId]      = jobId;
        requestRegistered[requestId] = true;

        emit PipelineAdvanced(jobId, PipelineStage.STAGE_2_QUAL, requestId);
    }

    // ─── Stage 3: LLM Inference (Score synthesis) ─────────────────────────────

    function _launchStage3(uint256 jobId) internal {
        PipelineJob storage job = pipelineJobs[jobId];
        uint256 deposit = platform.getRequestDeposit()
                        + INFER_PRICE_PER_AGENT * SUBCOMMITTEE_SIZE;

        string memory systemPrompt = string(abi.encodePacked(
            "You are a senior DeFi risk analyst with expertise in smart contract security, ",
            "protocol economics, and on-chain forensics. You produce objective, evidence-based ",
            "risk scores. Penalize heavily for: unverified contracts, recent exploits, anonymous ",
            "teams with no activity, very low liquidity. Reward: long track records, multiple audits, ",
            "high TVL stability, active development."
        ));

        string memory userPrompt = string(abi.encodePacked(
            "TARGET: ", _toHexString(job.target),
            "\nTYPE: ", _aTypeToString(job.assessmentType),
            "\n\n=== QUANTITATIVE DATA (on-chain / API) ===\n", job.quantData,
            "\n\n=== QUALITATIVE DATA (web intelligence) ===\n", job.qualData,
            "\n\n=== SCORING TASK ===\n",
            "Score 0-100 where 0=lowest risk, 100=highest risk.\n",
            "0-25: TRUSTED | 26-55: CAUTION | 56-79: HIGH_RISK | 80-100: UNVERIFIED\n",
            "Return ONLY a single integer."
        ));

        bytes memory payload = abi.encodeWithSignature(
            "inferNumber(string,string,int256,int256)",
            systemPrompt,
            userPrompt,
            int256(0),
            int256(100)
        );

        uint256 requestId = platform.createRequest{value: deposit}(
            llmInferAgentId,
            address(this),
            this.handleResponse.selector,
            payload
        );

        job.balance -= deposit;
        job.requestIds.push(requestId);
        job.stage = PipelineStage.STAGE_3_SYNTH;
        requestToJob[requestId]      = jobId;
        requestRegistered[requestId] = true;

        emit PipelineAdvanced(jobId, PipelineStage.STAGE_3_SYNTH, requestId);
    }

    // ─── IAgentRequesterHandler: handleResponse ───────────────────────────────

    function handleResponse(
        uint256           requestId,
        Response[] memory responses,
        ResponseStatus    status,
        Request memory    /* details */
    ) external override {
        if (msg.sender != address(platform)) revert NotPlatform();
        if (!requestRegistered[requestId])   revert UnknownRequest();

        uint256 jobId = requestToJob[requestId];
        PipelineJob storage job = pipelineJobs[jobId];
        if (!job.active) revert JobNotActive();

        // Handle failure or empty response at any stage
        if (status != ResponseStatus.Success || responses.length == 0) {
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
            // inferNumber returns ABI-encoded uint256 in range [0, 100]
            uint256 rawScore = abi.decode(responses[0].result, (uint256));
            uint256 score    = rawScore > 100 ? 100 : rawScore;
            _storeAssessment(jobId, score);
        }
    }

    // ─── Internal: Store results ──────────────────────────────────────────────

    function _storeAssessment(uint256 jobId, uint256 score) internal {
        PipelineJob storage job = pipelineJobs[jobId];
        RiskLabel label = _scoreToLabel(score);

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

        // Refund any unused balance to the requester
        if (job.balance > 0) {
            uint256 refund = job.balance;
            job.balance = 0;
            (bool ok, ) = payable(job.requester).call{value: refund}("");
            if (!ok) { /* absorb into contract — owner can withdraw */ }
        }

        emit AssessmentComplete(job.target, score, label, jobId);

        if (job.callbackSelector != bytes4(0)) {
            _fireConsumerCallback(
                job.requester, job.callbackSelector,
                job.target, score, label
            );
        }
    }

    function _storeFailedAssessment(uint256 jobId) internal {
        PipelineJob storage job = pipelineJobs[jobId];

        assessments[job.target] = Assessment({
            target:          job.target,
            score:           100,
            label:           RiskLabel.UNVERIFIED,
            timestamp:       block.timestamp,
            expiry:          block.timestamp + ASSESSMENT_TTL,
            evidenceSummary: "Assessment pipeline failed or timed out.",
            requestIds:      job.requestIds,
            exists:          true
        });

        // Refund remaining balance on failure
        if (job.balance > 0) {
            uint256 refund = job.balance;
            job.balance = 0;
            (bool ok, ) = payable(job.requester).call{value: refund}("");
            if (!ok) { /* absorb into contract */ }
        }

        job.active = false;
        job.stage  = PipelineStage.COMPLETE;

        emit AssessmentFailed(job.target, jobId);

        if (job.callbackSelector != bytes4(0)) {
            _fireConsumerCallback(
                job.requester, job.callbackSelector,
                job.target, 100, RiskLabel.UNVERIFIED
            );
        }
    }

    function _fireConsumerCallback(
        address   consumer,
        bytes4    selector,
        address   target,
        uint256   score,
        RiskLabel label
    ) internal {
        bytes memory data = abi.encodeWithSelector(selector, target, score, uint8(label));
        // Non-reverting: a failing consumer callback must not block the registry
        (bool ok, ) = consumer.call(data);
        if (!ok) emit CallbackFailed(consumer, target);
    }

    // ─── IARIARegistry: Read functions ───────────────────────────────────────

    function getAssessment(address target)
        external view override
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

    /// @notice Returns the full evidence string for a target (gas-free off-chain call).
    function getEvidenceSummary(address target) external view returns (string memory) {
        return assessments[target].evidenceSummary;
    }

    /// @notice Returns all Somnia requestIds that contributed to the stored assessment.
    function getRequestIds(address target) external view returns (uint256[] memory) {
        return assessments[target].requestIds;
    }

    function isHighRisk(address target) external view override returns (bool) {
        Assessment storage a = assessments[target];
        // Covers both HIGH_RISK (2) and UNVERIFIED (3) since enum is ordered
        return a.exists && uint8(a.label) >= uint8(RiskLabel.HIGH_RISK);
    }

    function isTrusted(address target) external view override returns (bool) {
        Assessment storage a = assessments[target];
        return a.exists
            && a.label == RiskLabel.TRUSTED
            && block.timestamp < a.expiry;
    }

    // ─── Internal helpers ────────────────────────────────────────────────────

    function _scoreToLabel(uint256 score) internal pure returns (RiskLabel) {
        if (score <= 25) return RiskLabel.TRUSTED;
        if (score <= 55) return RiskLabel.CAUTION;
        if (score <= 79) return RiskLabel.HIGH_RISK;
        return RiskLabel.UNVERIFIED;
    }

    /// @notice Build Stage 1 API URL and JSON selector based on target type.
    function _buildStage1Query(address target, AssessmentType aType)
        internal pure
        returns (string memory url, string memory selector)
    {
        string memory addr = _toHexString(target);
        if (aType == AssessmentType.PROTOCOL) {
            // Etherscan: is the contract verified? What's its name?
            url      = string(abi.encodePacked(
                "https://api.etherscan.io/api?module=contract&action=getsourcecode&address=", addr
            ));
            selector = "result.0.ContractName";
        } else if (aType == AssessmentType.TOKEN) {
            // CoinGecko: token market data by contract address (Ethereum chain)
            url      = string(abi.encodePacked(
                "https://api.coingecko.com/api/v3/coins/ethereum/contract/", addr
            ));
            selector = "market_data.market_cap.usd";
        } else {
            // WALLET: Etherscan first transaction timestamp
            url      = string(abi.encodePacked(
                "https://api.etherscan.io/api?module=account&action=txlist&address=", addr,
                "&startblock=0&endblock=99999999&page=1&offset=5&sort=asc"
            ));
            selector = "result.0.timeStamp";
        }
    }

    /// @notice Build Stage 2 URL and extraction query for qualitative intelligence.
    function _buildStage2Query(address target, AssessmentType aType)
        internal pure
        returns (string memory url, string memory query)
    {
        string memory addr = _toHexString(target);
        if (aType == AssessmentType.PROTOCOL) {
            // Search rekt.news for any known exploits
            url   = string(abi.encodePacked("https://rekt.news/search?q=", addr));
            query = "Extract: protocol name, any exploit or hack incidents, dates, amounts lost. If none found, state 'No known exploits'.";
        } else if (aType == AssessmentType.TOKEN) {
            // Etherscan token page for holder count and contract info
            url   = string(abi.encodePacked("https://etherscan.io/token/", addr));
            query = "Extract: token name, token symbol, holder count, creation date, verified contract status.";
        } else {
            // WALLET: Etherscan address page for activity overview
            url   = string(abi.encodePacked("https://etherscan.io/address/", addr));
            query = "Extract: first seen date, total transactions, contract interactions, any flagged or suspicious activity labels.";
        }
    }

    function _aTypeToString(AssessmentType aType) internal pure returns (string memory) {
        if (aType == AssessmentType.WALLET)   return "WALLET";
        if (aType == AssessmentType.PROTOCOL) return "PROTOCOL";
        return "TOKEN";
    }

    /// @notice Converts an address to its lowercase hex string (e.g. "0x1a2b...").
    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        uint160 value = uint160(addr);
        for (int256 i = 41; i >= 2; i--) {
            uint8 nibble = uint8(value & 0xf);
            buffer[uint256(i)] = nibble < 10
                ? bytes1(nibble + 0x30)
                : bytes1(nibble + 0x57);
            value >>= 4;
        }
        return string(buffer);
    }

    receive() external payable {}
}

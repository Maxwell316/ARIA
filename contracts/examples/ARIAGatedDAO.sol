// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../ARIAConsumerBase.sol";

/// @title ARIAGatedDAO
/// @notice A DAO treasury that blocks fund transfers to HIGH_RISK recipients.
///
///   Demo flow:
///     1. Member calls submitProposal(recipient, amount, description) with ETH covering
///        the ARIA deposit + the proposed transfer amount.
///     2. ARIA assesses the recipient asynchronously (~30s on testnet).
///     3. If score > RISK_THRESHOLD → proposal is blocked.
///     4. Member calls executeProposal(id) → reverts if blocked, transfers if approved.
contract ARIAGatedDAO is ARIAConsumerBase {

    // ─── Config ───────────────────────────────────────────────────────────────

    /// @notice Proposals with ARIA score above this threshold are blocked.
    uint256 public constant RISK_THRESHOLD = 55; // blocks HIGH_RISK + UNVERIFIED

    // ─── Structs / State ──────────────────────────────────────────────────────

    struct Proposal {
        address recipient;
        uint256 amount;
        string  description;
        uint256 votes;
        bool    vetted;   // true once ARIA callback fires
        bool    blocked;  // true if score > RISK_THRESHOLD
        bool    executed;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(address => bool)     public members;
    // recipient → most-recently-submitted proposal ID (for callback resolution)
    mapping(address => uint256)  private _latestProposalForRecipient;

    uint256 public nextProposalId;
    address public admin;

    // ─── Events ───────────────────────────────────────────────────────────────

    event ProposalSubmitted(uint256 indexed id, address indexed recipient, uint256 amount);
    event ProposalVetted(uint256 indexed id, uint256 ariaScore, bool blocked);
    event ProposalExecuted(uint256 indexed id, address indexed recipient, uint256 amount);
    event MemberAdded(address indexed member);

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address registry_) ARIAConsumerBase(registry_) {
        admin = msg.sender;
        members[msg.sender] = true;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function addMember(address member) external {
        require(msg.sender == admin, "Not admin");
        members[member] = true;
        emit MemberAdded(member);
    }

    // ─── Proposal lifecycle ───────────────────────────────────────────────────

    /// @notice Submit a treasury proposal. msg.value must cover the ARIA deposit
    ///         PLUS the proposed transfer amount (held in escrow).
    /// @dev    Call ariaRegistry.getRequiredDeposit() off-chain to size msg.value.
    function submitProposal(
        address recipient,
        uint256 amount,
        string calldata description
    ) external payable returns (uint256 id) {
        require(members[msg.sender], "Not a member");
        require(recipient != address(0), "Zero recipient");

        uint256 ariaDeposit = ariaRegistry.getRequiredDeposit();
        require(msg.value >= ariaDeposit + amount, "Insufficient ETH: cover ARIA deposit + amount");

        id = nextProposalId++;
        proposals[id] = Proposal({
            recipient:   recipient,
            amount:      amount,
            description: description,
            votes:       0,
            vetted:      false,
            blocked:     false,
            executed:    false
        });
        _latestProposalForRecipient[recipient] = id;

        emit ProposalSubmitted(id, recipient, amount);

        // Kick off ARIA assessment of the recipient
        ariaRegistry.requestAssessment{value: ariaDeposit}(
            recipient,
            IARIARegistry.AssessmentType.WALLET,
            this.onAssessmentComplete.selector
        );
    }

    /// @notice Execute an approved, vetted proposal.
    function executeProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(p.vetted,    "Not yet vetted by ARIA");
        require(!p.blocked,  "Blocked: ARIA risk score too high");
        require(!p.executed, "Already executed");

        p.executed = true;
        emit ProposalExecuted(id, p.recipient, p.amount);

        (bool ok, ) = payable(p.recipient).call{value: p.amount}("");
        require(ok, "Transfer failed");
    }

    // ─── ARIA Callback ────────────────────────────────────────────────────────

    function _onAssessmentComplete(
        address target,
        uint256 score,
        uint8   /* label */
    ) internal override {
        uint256 id = _latestProposalForRecipient[target];
        Proposal storage p = proposals[id];
        if (p.recipient != target || p.vetted) return;

        p.vetted  = true;
        p.blocked = score > RISK_THRESHOLD;

        emit ProposalVetted(id, score, p.blocked);
    }

    receive() external payable {}
}

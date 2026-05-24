// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../ARIAConsumerBase.sol";

/// @title ARIALendingMarket
/// @notice Lending market where the maximum LTV depends on the borrower's ARIA risk score.
///
///   LTV tiers:
///     TRUSTED   (score 0–25):  80% LTV
///     CAUTION   (score 26–55): 60% LTV
///     HIGH_RISK (score 56–79): 0%  (blocked)
///     UNVERIFIED(score 80–100): 0% (blocked)
///
///   Flow:
///     1. Borrower calls requestBorrow(amount) with ETH collateral + ARIA deposit.
///     2. ARIA assesses the borrower's wallet asynchronously.
///     3. On callback: collateral is returned to HIGH_RISK/UNVERIFIED borrowers,
///        or loan is disbursed up to the LTV-capped amount.
contract ARIALendingMarket is ARIAConsumerBase {

    // ─── LTV constants ────────────────────────────────────────────────────────
    uint256 public constant LTV_TRUSTED  = 80; // 80%
    uint256 public constant LTV_CAUTION  = 60; // 60%

    // ─── Structs / State ──────────────────────────────────────────────────────

    struct BorrowPosition {
        address borrower;
        uint256 collateral;  // ETH locked as collateral
        uint256 requested;   // ETH amount the borrower wants to borrow
        uint256 disbursed;   // actual amount sent (set on callback)
        bool    settled;     // true once callback has fired
        bool    blocked;     // true if ARIA blocked the loan
    }

    mapping(uint256 => BorrowPosition) public positions;
    // borrower → active position ID
    mapping(address => uint256)        private _activePosition;
    mapping(address => bool)           private _hasPendingPosition;

    uint256 public nextPositionId;
    address public owner;

    // ─── Events ───────────────────────────────────────────────────────────────

    event BorrowRequested(uint256 indexed posId, address indexed borrower, uint256 collateral, uint256 requested);
    event BorrowApproved(uint256 indexed posId, address indexed borrower, uint256 disbursed, uint256 ariaScore);
    event BorrowBlocked(uint256 indexed posId, address indexed borrower, uint256 ariaScore);
    event CollateralReturned(uint256 indexed posId, address indexed borrower);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address registry_) ARIAConsumerBase(registry_) {
        owner = msg.sender;
    }

    // ─── Borrow ───────────────────────────────────────────────────────────────

    /// @notice Request a loan. Send collateral + ARIA deposit in msg.value.
    ///         ARIA deposit is recovered via ariaRegistry.getRequiredDeposit().
    /// @param amount The amount of ETH you want to borrow.
    function requestBorrow(uint256 amount) external payable returns (uint256 posId) {
        require(!_hasPendingPosition[msg.sender], "Pending position exists");
        require(amount > 0, "Zero borrow amount");

        uint256 ariaDeposit = ariaRegistry.getRequiredDeposit();
        uint256 minSend     = ariaDeposit + 1; // at least 1 wei collateral
        require(msg.value >= minSend, "Insufficient ETH: collateral + ARIA deposit");

        uint256 collateral = msg.value - ariaDeposit;

        posId = nextPositionId++;
        positions[posId] = BorrowPosition({
            borrower:   msg.sender,
            collateral: collateral,
            requested:  amount,
            disbursed:  0,
            settled:    false,
            blocked:    false
        });
        _activePosition[msg.sender]    = posId;
        _hasPendingPosition[msg.sender] = true;

        emit BorrowRequested(posId, msg.sender, collateral, amount);

        ariaRegistry.requestAssessment{value: ariaDeposit}(
            msg.sender,
            IARIARegistry.AssessmentType.WALLET,
            this.onAssessmentComplete.selector
        );
    }

    // ─── ARIA Callback ────────────────────────────────────────────────────────

    function _onAssessmentComplete(
        address target,
        uint256 score,
        uint8   /* label */
    ) internal override {
        if (!_hasPendingPosition[target]) return;

        uint256 posId = _activePosition[target];
        BorrowPosition storage pos = positions[posId];

        if (pos.settled || pos.borrower != target) return;

        pos.settled = true;
        _hasPendingPosition[target] = false;

        // Determine LTV
        uint256 ltv;
        if (score <= 25) {
            ltv = LTV_TRUSTED;
        } else if (score <= 55) {
            ltv = LTV_CAUTION;
        } else {
            // HIGH_RISK or UNVERIFIED — return collateral and block
            pos.blocked = true;
            emit BorrowBlocked(posId, target, score);
            emit CollateralReturned(posId, target);
            (bool ok, ) = payable(target).call{value: pos.collateral}("");
            require(ok, "Collateral return failed");
            return;
        }

        uint256 maxBorrow = (pos.collateral * ltv) / 100;
        uint256 approved  = pos.requested < maxBorrow ? pos.requested : maxBorrow;
        pos.disbursed     = approved;

        emit BorrowApproved(posId, target, approved, score);

        if (approved > 0 && address(this).balance >= approved) {
            (bool ok, ) = payable(target).call{value: approved}("");
            require(ok, "Loan disbursement failed");
        }
    }

    // ─── Repay ────────────────────────────────────────────────────────────────

    /// @notice Repay a loan and reclaim collateral.
    function repay(uint256 posId) external payable {
        BorrowPosition storage pos = positions[posId];
        require(pos.borrower == msg.sender, "Not borrower");
        require(pos.settled && !pos.blocked, "Loan not active");
        require(msg.value >= pos.disbursed, "Insufficient repayment");

        uint256 collateral = pos.collateral;
        pos.disbursed      = 0;
        pos.collateral     = 0;

        emit CollateralReturned(posId, msg.sender);
        (bool ok, ) = payable(msg.sender).call{value: collateral}("");
        require(ok, "Collateral return failed");
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Fund the lending pool.
    function fundPool() external payable {}

    function withdraw(uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        payable(owner).transfer(amount);
    }

    receive() external payable {}
}

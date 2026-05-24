// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IARIARegistry.sol";

/// @title ARIAConsumerBase
/// @notice Inherit this contract to integrate ARIA risk gating with one line.
///
///   Usage:
///     1. Inherit ARIAConsumerBase.
///     2. Override _onAssessmentComplete() to handle score/label results.
///     3. Use `onlyTrusted` or `notHighRisk` modifiers on sensitive functions.
///     4. Call ariaRegistry.requestAssessment{value: ariaRegistry.getRequiredDeposit()}(...)
///        when you need a fresh assessment.
abstract contract ARIAConsumerBase {

    IARIARegistry public immutable ariaRegistry;

    constructor(address registry_) {
        require(registry_ != address(0), "ARIAConsumerBase: zero address");
        ariaRegistry = IARIARegistry(registry_);
    }

    // ─── Callback entry point (called by ARIARegistry) ────────────────────────

    /// @notice Called by ARIARegistry when an assessment completes.
    ///         Validates caller then delegates to the internal hook.
    function onAssessmentComplete(
        address target,
        uint256 score,
        uint8   label
    ) external virtual {
        require(msg.sender == address(ariaRegistry), "ARIAConsumerBase: only ARIA");
        _onAssessmentComplete(target, score, label);
    }

    /// @notice Override this in your consumer to react to completed assessments.
    function _onAssessmentComplete(
        address target,
        uint256 score,
        uint8   label
    ) internal virtual;

    // ─── Modifiers ────────────────────────────────────────────────────────────

    /// @notice Reverts if `target` does not have a fresh TRUSTED assessment.
    modifier onlyTrusted(address target) {
        require(
            ariaRegistry.isTrusted(target),
            "ARIAConsumerBase: target not TRUSTED by ARIA"
        );
        _;
    }

    /// @notice Reverts if `target` is HIGH_RISK or UNVERIFIED by ARIA.
    modifier notHighRisk(address target) {
        require(
            !ariaRegistry.isHighRisk(target),
            "ARIAConsumerBase: target is HIGH_RISK by ARIA"
        );
        _;
    }

    /// @notice Convenience: read current risk score without reverting.
    function getARIAScore(address target) public view returns (uint256 score, bool fresh) {
        (score, , , , fresh) = ariaRegistry.getAssessment(target);
    }
}

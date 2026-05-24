// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IARIARegistry
/// @notice Public interface for the ARIA on-chain risk registry.
///         Any contract can call requestAssessment() and read results via getAssessment().
interface IARIARegistry {

    // ─── Types ────────────────────────────────────────────────────────────────

    enum AssessmentType { WALLET, PROTOCOL, TOKEN }

    /// @dev Ordered so that label >= HIGH_RISK covers both HIGH_RISK and UNVERIFIED.
    enum RiskLabel { TRUSTED, CAUTION, HIGH_RISK, UNVERIFIED }

    // ─── Events ───────────────────────────────────────────────────────────────

    event AssessmentRequested(
        uint256 indexed jobId,
        address indexed target,
        address indexed requester
    );

    event AssessmentComplete(
        address indexed target,
        uint256         score,
        RiskLabel       label,
        uint256         jobId
    );

    // ─── Write ────────────────────────────────────────────────────────────────

    /// @notice Request a risk assessment for `target`.
    ///         If a fresh cached assessment exists, fires callback immediately and returns max(uint256).
    ///         Otherwise kicks off the 3-stage agent pipeline.
    /// @param target            Address to assess.
    /// @param assessmentType    WALLET | PROTOCOL | TOKEN
    /// @param callbackSelector  4-byte selector of consumer callback (or bytes4(0) for none).
    /// @return jobId            Pipeline job ID (type(uint256).max if served from cache).
    function requestAssessment(
        address        target,
        AssessmentType assessmentType,
        bytes4         callbackSelector
    ) external payable returns (uint256 jobId);

    // ─── Read ─────────────────────────────────────────────────────────────────

    /// @notice Read a stored assessment for `target`.
    function getAssessment(address target)
        external view
        returns (
            uint256 score,
            uint8   label,
            uint256 timestamp,
            uint256 expiry,
            bool    fresh
        );

    /// @notice Returns true if target's label is HIGH_RISK or UNVERIFIED (and assessed).
    function isHighRisk(address target) external view returns (bool);

    /// @notice Returns true if target's label is TRUSTED and the assessment has not expired.
    function isTrusted(address target) external view returns (bool);

    /// @notice Calculates the minimum ETH required to fund a full 3-stage assessment.
    function getRequiredDeposit() external view returns (uint256);
}

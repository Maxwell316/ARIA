// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAgentRequester.sol";

/// @title MockSomniaPlatform
/// @notice Test double for the Somnia IAgentRequester platform.
///         Records createRequest calls and exposes fulfillRequest / failRequest
///         so tests can drive the ARIA pipeline without a live network.
contract MockSomniaPlatform is IAgentRequester {

    uint256 private _nextRequestId = 1;

    struct PendingRequest {
        uint256 agentId;
        address callbackContract;
        bytes4  callbackSelector;
        bytes   payload;
        uint256 value;
        bool    exists;
    }

    mapping(uint256 => PendingRequest) public pendingRequests;

    /// @notice Fixed base deposit returned by getRequestDeposit().
    uint256 public baseDeposit;

    constructor(uint256 baseDeposit_) {
        baseDeposit = baseDeposit_;
    }

    // ─── IAgentRequester ──────────────────────────────────────────────────────

    function createRequest(
        uint256        agentId,
        address        callbackContract,
        bytes4         callbackSelector,
        bytes calldata payload
    ) external payable override returns (uint256 requestId) {
        requestId = _nextRequestId++;
        pendingRequests[requestId] = PendingRequest({
            agentId:          agentId,
            callbackContract: callbackContract,
            callbackSelector: callbackSelector,
            payload:          payload,
            value:            msg.value,
            exists:           true
        });
    }

    function getRequestDeposit() external view override returns (uint256) {
        return baseDeposit;
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /// @notice Simulate a successful agent response with `result` bytes.
    function fulfillRequest(uint256 requestId, bytes calldata result) external {
        PendingRequest memory req = pendingRequests[requestId];
        require(req.exists, "MockPlatform: unknown request");

        Response[] memory responses = new Response[](1);
        responses[0] = Response({result: result, validatorId: 1});

        Request memory details = Request({
            agentId:          req.agentId,
            callbackContract: req.callbackContract,
            callbackSelector: req.callbackSelector,
            payload:          req.payload
        });

        IAgentRequesterHandler(req.callbackContract).handleResponse(
            requestId,
            responses,
            ResponseStatus.Success,
            details
        );
    }

    /// @notice Simulate a failed agent response.
    function failRequest(uint256 requestId) external {
        PendingRequest memory req = pendingRequests[requestId];
        require(req.exists, "MockPlatform: unknown request");

        Response[] memory responses = new Response[](0);

        Request memory details = Request({
            agentId:          req.agentId,
            callbackContract: req.callbackContract,
            callbackSelector: req.callbackSelector,
            payload:          req.payload
        });

        IAgentRequesterHandler(req.callbackContract).handleResponse(
            requestId,
            responses,
            ResponseStatus.Failed,
            details
        );
    }

    /// @notice Simulate a timed-out agent response.
    function timeoutRequest(uint256 requestId) external {
        PendingRequest memory req = pendingRequests[requestId];
        require(req.exists, "MockPlatform: unknown request");

        Response[] memory responses = new Response[](0);

        Request memory details = Request({
            agentId:          req.agentId,
            callbackContract: req.callbackContract,
            callbackSelector: req.callbackSelector,
            payload:          req.payload
        });

        IAgentRequesterHandler(req.callbackContract).handleResponse(
            requestId,
            responses,
            ResponseStatus.TimedOut,
            details
        );
    }

    /// @notice Peek at what the next request ID will be (useful in tests).
    function nextRequestId() external view returns (uint256) {
        return _nextRequestId;
    }

    receive() external payable {}
}

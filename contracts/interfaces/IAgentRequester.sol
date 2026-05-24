// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Single agent response from a Somnia validator subcommittee member.
struct Response {
    bytes   result;
    uint256 validatorId;
}

/// @notice Metadata about the original request, passed back in handleResponse.
struct Request {
    uint256 agentId;
    address callbackContract;
    bytes4  callbackSelector;
    bytes   payload;
}

/// @notice Status of an agent request after execution.
enum ResponseStatus { Success, Failed, TimedOut }

/// @notice Interface to the Somnia Agentic Platform contract.
interface IAgentRequester {
    /// @notice Create a new agent request. Caller must pay the required deposit.
    /// @param agentId          The Somnia agent type to invoke.
    /// @param callbackContract Contract to receive the handleResponse callback.
    /// @param callbackSelector 4-byte selector of the callback function.
    /// @param payload          ABI-encoded arguments for the agent.
    /// @return requestId       Unique ID for this request.
    function createRequest(
        uint256        agentId,
        address        callbackContract,
        bytes4         callbackSelector,
        bytes calldata payload
    ) external payable returns (uint256 requestId);

    /// @notice Returns the minimum deposit required per createRequest call.
    function getRequestDeposit() external view returns (uint256);
}

/// @notice Interface that contracts must implement to receive agent callbacks.
interface IAgentRequesterHandler {
    function handleResponse(
        uint256           requestId,
        Response[] memory responses,
        ResponseStatus    status,
        Request memory    details
    ) external;
}

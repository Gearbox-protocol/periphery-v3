// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Aave V3 flash-loan receiver callback
interface IAaveV3FlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

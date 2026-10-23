// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Aave Horizon RwaATokenManager (per-aToken authorized transfer roles)
interface IRwaATokenManager {
    function transferRwaAToken(address aToken, address from, address to, uint256 amount) external returns (bool);

    function hasAuthorizedTransferRole(address aToken, address account) external view returns (bool);
}

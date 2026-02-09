// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IVaultWhitelister {
    event VaultWhitelisted(address indexed investor, address indexed vault, address indexed token, string investorId);

    function whitelist(address vaultAddress, address investorWalletAddress) external;

    function token() external view returns (address);
}

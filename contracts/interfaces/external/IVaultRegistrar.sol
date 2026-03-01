// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IVaultRegistrar {
    function token() external view returns (address);
    function isRegistered(address vaultAddress, address investorWalletAddress) external view returns (bool);
    function registerVault(address vaultAddress, address investorWalletAddress) external;
    function unregisterVault(address vaultAddress, address investorWalletAddress) external;
}

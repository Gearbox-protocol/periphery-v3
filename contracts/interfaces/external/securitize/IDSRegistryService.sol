// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IDSRegistryService {
    function registerInvestor(string calldata investorId, string calldata collisionHash) external;
    function isInvestor(string calldata investorId) external view returns (bool);
    function addWallet(address wallet, string calldata investorId) external;
    function getInvestor(address wallet) external view returns (string memory);
    function isWallet(address wallet) external view returns (bool);
}

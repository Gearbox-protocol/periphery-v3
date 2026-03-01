// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {IVaultRegistrar} from "../../../../interfaces/external/IVaultRegistrar.sol";
import {MockDSToken} from "./MockDSToken.sol";

contract MockRegistrar is IVaultRegistrar {
    address public immutable admin;
    address public immutable override token;

    mapping(address => bool) public isOperator;

    error CallerIsNotAdmin(address caller);
    error CallerIsNotOperator(address caller);
    error InvestorNotRegisteredInToken(address investor);
    error VaultNotRegistered(address vault, address investor);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert CallerIsNotAdmin(msg.sender);
        _;
    }

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert CallerIsNotOperator(msg.sender);
        _;
    }

    constructor(address admin_, address token_) {
        admin = admin_;
        token = token_;
    }

    function grantOperator(address account) external onlyAdmin {
        isOperator[account] = true;
    }

    function isRegistered(address vaultAddress, address investorWalletAddress) external view override returns (bool) {
        return MockDSToken(token).registeredVaults(vaultAddress) == investorWalletAddress
            && MockDSToken(token).isAuthorized(investorWalletAddress);
    }

    function registerVault(address vaultAddress, address investorWalletAddress) external override onlyOperator {
        MockDSToken(token).registerVault(vaultAddress, investorWalletAddress);
    }

    function unregisterVault(address vaultAddress, address investorWalletAddress) external override onlyOperator {
        MockDSToken(token).unregisterVault(vaultAddress, investorWalletAddress);
    }
}

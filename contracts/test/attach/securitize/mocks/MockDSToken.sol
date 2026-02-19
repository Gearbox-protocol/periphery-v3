// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDSToken is ERC20 {
    address public immutable admin;
    mapping(address registrar => bool) public isRegistrar;
    mapping(address investor => bool) public isAuthorized;
    mapping(address vault => address investor) public registeredVaults;

    error CallerIsNotAdmin(address caller);
    error CallerIsNotRegistrar(address caller);
    error InvestorAlreadyAuthorized(address investor);
    error InvestorNotAuthorized(address investor);
    error VaultNotRegisteredForInvestor(address vault, address investor);
    error CannotTransfer(address from, address to);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert CallerIsNotAdmin(msg.sender);
        _;
    }

    modifier onlyRegistrar() {
        if (!isRegistrar[msg.sender]) revert CallerIsNotRegistrar(msg.sender);
        _;
    }

    constructor(address admin_) ERC20("Mock DSToken", "MDSToken") {
        admin = admin_;
    }

    function setRegistrar(address retistrar, bool status) external onlyAdmin {
        isRegistrar[retistrar] = status;
    }

    function mint(address to, uint256 amount) external onlyAdmin {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyAdmin {
        _burn(from, amount);
    }

    function authorize(address investor) external onlyAdmin {
        if (isAuthorized[investor]) revert InvestorAlreadyAuthorized(investor);
        isAuthorized[investor] = true;
    }

    function unauthorize(address investor) external onlyAdmin {
        if (!isAuthorized[investor]) revert InvestorNotAuthorized(investor);
        isAuthorized[investor] = false;
    }

    function registerVault(address vault, address investor) external onlyRegistrar {
        if (!isAuthorized[investor]) revert InvestorNotAuthorized(investor);
        registeredVaults[vault] = investor;
    }

    function unregisterVault(address vault, address investor) external onlyRegistrar {
        if (registeredVaults[vault] != investor) revert VaultNotRegisteredForInvestor(vault, investor);
        delete registeredVaults[vault];
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (from != address(0) && !_canTransfer(from) || to != address(0) && !_canTransfer(to)) {
            revert CannotTransfer(from, to);
        }
    }

    function _canTransfer(address account) internal view returns (bool) {
        return isAuthorized[account] || isAuthorized[registeredVaults[account]];
    }
}

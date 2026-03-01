// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IKYCFactory} from "../interfaces/base/IKYCFactory.sol";
import {IKYCUnderlying} from "../interfaces/base/IKYCUnderlying.sol";
import {TYPE_DEFAULT_KYC_UNDERLYING} from "../libraries/AddressValidation.sol";

/// @title  Default KYC Underlying
/// @author Gearbox Foundation
/// @notice An ERC4626-like token wrapper to use as underlying in markets with KYC compliance.
///         Exists primarily to block liquidations of frozen credit accounts since both full and partial liquidations
///         involve minting shares and returning them to the pool.
///         Other interactions with frozen credit accounts are blocked directly in the KYC factory contract.
contract DefaultKYCUnderlying is IKYCUnderlying, ERC4626 {
    bytes32 public constant override contractType = TYPE_DEFAULT_KYC_UNDERLYING;
    uint256 public constant override version = 3_10;

    IKYCFactory internal immutable _FACTORY;

    constructor(IKYCFactory factory, ERC20 underlying, string memory namePrefix, string memory symbolPrefix)
        ERC20(string.concat(namePrefix, underlying.name()), string.concat(symbolPrefix, underlying.symbol()))
        ERC4626(underlying)
    {
        _FACTORY = factory;
    }

    function serialize() external view virtual override returns (bytes memory) {
        return abi.encode(_FACTORY, asset());
    }

    function getFactory() external view override returns (address) {
        return address(_FACTORY);
    }

    function beforeTokenBorrow(address creditAccount, uint256 amount) external view override {}

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        _revertIfFrozenCreditAccount(from);
        _revertIfFrozenCreditAccount(to);
    }

    function _revertIfFrozenCreditAccount(address account) internal view {
        if (_FACTORY.isCreditAccount(account) && _FACTORY.isFrozen(account)) {
            revert FrozenCreditAccountException(account);
        }
    }
}

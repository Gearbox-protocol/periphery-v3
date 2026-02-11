// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {ISecuritizeFactory} from "./interfaces/ISecuritizeFactory.sol";
import {AP_SECURITIZE_FACTORY} from "./libraries/AddressValidation.sol";

/// @title Default Securitize Underlying
/// @author Gearbox Foundation
/// @notice An ERC4626-like token wrapper to use as underlying in Securitize markets
/// @dev Exists primarily to block liquidations of frozen credit accounts since both full and partial liquidations
///      involve minting shares and returning them to the pool.
///      Other interactions with frozen credit accounts are blocked directly in the `SecuritizeWallet` contract.
contract DefaultSecuritizeUnderlying is ERC4626, IVersion {
    IAddressProvider public immutable ADDRESS_PROVIDER;
    ISecuritizeFactory public immutable FACTORY;

    error FrozenCreditAccountException(address creditAccount);

    constructor(IAddressProvider addressProvider, ERC20 underlying)
        ERC20(
            string.concat("Securitize Compliant ", underlying.name()), string.concat("securitize-", underlying.symbol())
        )
        ERC4626(underlying)
    {
        ADDRESS_PROVIDER = addressProvider;
        FACTORY = ISecuritizeFactory(addressProvider.getAddressOrRevert(AP_SECURITIZE_FACTORY, 3_10));
    }

    function contractType() public pure virtual override returns (bytes32) {
        return "SECURITIZE_UNDERLYING::DEFAULT";
    }

    function version() public pure virtual override returns (uint256) {
        return 3_10;
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal view virtual override returns (uint256) {
        return shares;
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal view virtual override returns (uint256) {
        return assets;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal virtual override {
        // TODO: try to limit to factory credit accounts after all
        if (_isFrozenCreditAccount(from) || _isFrozenCreditAccount(to)) revert FrozenCreditAccountException(from);
    }

    function _isFrozenCreditAccount(address account) internal view returns (bool) {
        return FACTORY.isKnownCreditAccount(account) && FACTORY.isFrozen(account);
    }
}

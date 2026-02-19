// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IStateSerializer} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IStateSerializer.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

import {IKYCFactory} from "./interfaces/base/IKYCFactory.sol";
import {IKYCUnderlying} from "./interfaces/base/IKYCUnderlying.sol";
import {AP_DEFAULT_KYC_UNDERLYING, AddressValidation} from "./libraries/AddressValidation.sol";

/// @title  Default KYC Underlying
/// @author Gearbox Foundation
/// @notice An ERC4626-like token wrapper to use as underlying in markets with KYC compliance.
///         Exists primarily to block liquidations of inactive credit accounts since both full and partial liquidations
///         involve minting shares and returning them to the pool.
///         Other interactions with inactive credit accounts are blocked directly in the KYC factory contract.
contract DefaultKYCUnderlying is ERC4626, IKYCUnderlying {
    using AddressValidation for IAddressProvider;

    IAddressProvider internal immutable ADDRESS_PROVIDER;
    IKYCFactory internal immutable FACTORY;

    constructor(
        IAddressProvider addressProvider,
        IKYCFactory factory_,
        ERC20 underlying,
        string memory namePrefix,
        string memory symbolPrefix
    )
        ERC20(string.concat(namePrefix, underlying.name()), string.concat(symbolPrefix, underlying.symbol()))
        ERC4626(underlying)
    {
        ADDRESS_PROVIDER = addressProvider;
        FACTORY = factory_;
    }

    function contractType() public pure virtual override returns (bytes32) {
        return AP_DEFAULT_KYC_UNDERLYING;
    }

    function version() public pure virtual override returns (uint256) {
        return 3_10;
    }

    function serialize() external view virtual override returns (bytes memory) {
        return abi.encode(FACTORY, asset());
    }

    function factory() external view override returns (address) {
        return address(FACTORY);
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal view virtual override returns (uint256) {
        return shares;
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal view virtual override returns (uint256) {
        return assets;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal virtual override {
        _revertIfInactiveCreditAccount(from);
        _revertIfInactiveCreditAccount(to);
    }

    function _revertIfInactiveCreditAccount(address account) internal view {
        if (FACTORY.isInactiveCreditAccount(account)) revert InactiveCreditAccountException(account);
    }
}

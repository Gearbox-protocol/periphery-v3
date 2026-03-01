// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IOnDemandKYCUnderlying} from "../interfaces/IOnDemandKYCUnderlying.sol";
import {IKYCFactory} from "../interfaces/base/IKYCFactory.sol";
import {IOnDemandLiquidityProvider} from "../interfaces/base/IOnDemandLiquidityProvider.sol";
import {
    DOMAIN_ON_DEMAND_LP,
    TYPE_ON_DEMAND_KYC_UNDERLYING,
    AddressValidation
} from "../libraries/AddressValidation.sol";

/// @title  On-demand KYC Underlying
/// @author Gearbox Foundation
/// @notice An ERC4626-like token wrapper to use as underlying in markets with KYC compliance and on-demand liquidity
///         provision. On top of blocking liquidations of frozen credit accounts, it also lets compliant users pull
///         liquidity from an on-demand LP contract right before borrowing, increasing capital efficiency for lenders.
///         Besides the pool, liquidity provider and credit accounts, only users whitelisted by the market configurator
///         admin can interact with the token in order to prevent dissolution of lenders' profits.
contract OnDemandKYCUnderlying is IOnDemandKYCUnderlying, ERC4626 {
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant override contractType = TYPE_ON_DEMAND_KYC_UNDERLYING;
    uint256 public constant override version = 3_10;

    IAddressProvider internal immutable _ADDRESS_PROVIDER;
    IKYCFactory internal immutable _FACTORY;
    IMarketConfigurator internal immutable _MARKET_CONFIGURATOR;
    IOnDemandLiquidityProvider internal immutable _LIQUIDITY_PROVIDER;
    address internal _pool;
    EnumerableSet.AddressSet internal _allowedUsers;

    modifier onlyMarketConfiguratorAdmin() {
        _ensureCallerIsMarketConfiguratorAdmin();
        _;
    }

    constructor(
        IAddressProvider addressProvider,
        IKYCFactory factory,
        IMarketConfigurator marketConfigurator,
        IOnDemandLiquidityProvider liquidityProvider,
        ERC20 underlying,
        string memory namePrefix,
        string memory symbolPrefix
    )
        ERC20(string.concat(namePrefix, underlying.name()), string.concat(symbolPrefix, underlying.symbol()))
        ERC4626(underlying)
    {
        if (!addressProvider.isMarketConfigurator(address(marketConfigurator))) {
            revert InvalidMarketConfiguratorException(address(marketConfigurator));
        }
        if (!addressProvider.hasDomain(address(liquidityProvider), DOMAIN_ON_DEMAND_LP)) {
            revert InvalidLiquidityProviderException(address(liquidityProvider));
        }
        _ADDRESS_PROVIDER = addressProvider;
        _FACTORY = factory;
        _MARKET_CONFIGURATOR = marketConfigurator;
        _LIQUIDITY_PROVIDER = liquidityProvider;
    }

    function serialize() external view override returns (bytes memory) {
        return abi.encode(_FACTORY, asset(), _pool, _MARKET_CONFIGURATOR, _LIQUIDITY_PROVIDER);
    }

    function getFactory() external view override returns (address) {
        return address(_FACTORY);
    }

    function getMarketConfigurator() external view override returns (address) {
        return address(_MARKET_CONFIGURATOR);
    }

    function getLiquidityProvider() external view override returns (address) {
        return address(_LIQUIDITY_PROVIDER);
    }

    function getPool() public view override returns (address pool) {
        pool = _pool;
        if (pool == address(0)) revert PoolNotSetException();
    }

    function setPool(address pool) external override onlyMarketConfiguratorAdmin {
        if (ERC4626(pool).asset() != address(this)) revert InvalidPoolException(pool);
        if (_pool != address(0)) revert PoolAlreadySetException();
        _pool = pool;
        emit SetPool(pool);
    }

    function setUserStatus(address user, bool allowed) external override onlyMarketConfiguratorAdmin {
        if (allowed && _allowedUsers.add(user) || !allowed && _allowedUsers.remove(user)) {
            emit SetUserStatus(user, allowed);
        }
    }

    function beforeTokenBorrow(address creditAccount, uint256 amount) external override {
        address pool = getPool();
        if (msg.sender != _FACTORY.getWallet(creditAccount)) {
            revert CallerIsNotWalletException(msg.sender, creditAccount);
        }
        if (pool != ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).pool()) {
            revert InvalidCreditAccountException(creditAccount);
        }
        _LIQUIDITY_PROVIDER.pullLiquidity(pool, amount);
    }

    /// @dev Even though pools are assumed to use IRMs independent of utilization, this adjustment
    ///      is necessary in order to prevent available liquidity from underflowing on borrowing.
    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        address pool = _pool;
        return super.balanceOf(account)
            + ((pool != address(0) && account == pool) ? _LIQUIDITY_PROVIDER.allowanceOf(pool) : 0);
    }

    /// @dev Just to be a little more consistent with the `balanceOf` adjustment
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        address pool = _pool;
        return super.totalSupply() + (pool != address(0) ? _LIQUIDITY_PROVIDER.allowanceOf(pool) : 0);
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        _checkAccount(from);
        _checkAccount(to);
    }

    function _checkAccount(address account) internal view {
        address pool = _pool;
        // anyone can interact with the token before the pool is set to simplify the setup process
        if (
            account == address(0) || pool == address(0) || account == pool || account == address(_LIQUIDITY_PROVIDER)
                || _allowedUsers.contains(account)
        ) return;
        if (_FACTORY.isCreditAccount(account)) {
            if (_FACTORY.isFrozen(account)) revert FrozenCreditAccountException(account);
        } else {
            revert UserNotAllowedException(account);
        }
    }

    function _ensureCallerIsMarketConfiguratorAdmin() internal view {
        if (msg.sender != _MARKET_CONFIGURATOR.admin()) revert CallerIsNotMarketConfiguratorAdminException(msg.sender);
    }
}

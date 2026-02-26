// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";

import {IMonopolizedOnDemandLP} from "./interfaces/IMonopolizedOnDemandLP.sol";
import {IOnDemandKYCUnderlying} from "./interfaces/IOnDemandKYCUnderlying.sol";
import {
    TYPE_MONOPOLIZED_ON_DEMAND_LP,
    TYPE_ON_DEMAND_KYC_UNDERLYING,
    AddressValidation
} from "./libraries/AddressValidation.sol";

/// @title  Monopolized On-demand LP
/// @author Gearbox Foundation
/// @notice A contract that allows a single depositor to provide liquidity to pools on demand by giving
///         approval of the corresponding token to this contract.
contract MonopolizedOnDemandLP is IMonopolizedOnDemandLP {
    using SafeERC20 for IERC20;
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant contractType = TYPE_MONOPOLIZED_ON_DEMAND_LP;
    uint256 public constant version = 3_10;

    IAddressProvider internal immutable _ADDRESS_PROVIDER;
    IMarketConfigurator internal immutable _MARKET_CONFIGURATOR;
    address internal immutable _DEPOSITOR;

    EnumerableSet.AddressSet internal _poolsSet;
    EnumerableSet.AddressSet internal _tokensSet;

    constructor(IAddressProvider addressProvider, IMarketConfigurator marketConfigurator, address depositor) {
        if (!addressProvider.isMarketConfigurator(address(marketConfigurator))) {
            revert InvalidMarketConfiguratorException(address(marketConfigurator));
        }
        _ADDRESS_PROVIDER = addressProvider;
        _MARKET_CONFIGURATOR = marketConfigurator;
        _DEPOSITOR = depositor;
    }

    function serialize() external view override returns (bytes memory) {
        return abi.encode(_MARKET_CONFIGURATOR, _DEPOSITOR, getPools());
    }

    function getMarketConfigurator() external view override returns (address) {
        return address(_MARKET_CONFIGURATOR);
    }

    function getDepositor() external view override returns (address) {
        return _DEPOSITOR;
    }

    function getPools() public view override returns (Pool[] memory pools) {
        uint256 length = _poolsSet.length();
        pools = new Pool[](length);
        for (uint256 i; i < length; ++i) {
            address pool = _poolsSet.at(i);
            (address token, address underlying) = _getTokens(pool);
            pools[i] = Pool({pool: pool, underlying: underlying, token: token});
        }
    }

    function addPool(address pool) external override {
        if (msg.sender != _MARKET_CONFIGURATOR.admin()) revert CallerIsNotMarketConfiguratorAdminException(msg.sender);
        if (!AddressValidation.isRegisteredPool(address(_MARKET_CONFIGURATOR), pool)) {
            revert InvalidPoolException(pool);
        }
        address underlying = _getAsset(pool);
        if (
            !_ADDRESS_PROVIDER.hasType(underlying, TYPE_ON_DEMAND_KYC_UNDERLYING)
                || IOnDemandKYCUnderlying(underlying).getLiquidityProvider() != address(this)
        ) revert InvalidUnderlyingTokenException(underlying);
        address token = _getAsset(underlying);

        if (!_poolsSet.add(pool)) revert PoolAlreadyAddedException(pool);
        if (!_tokensSet.add(token)) revert TokenAlreadyAddedException(token);
        emit AddPool({token: token, underlying: underlying, pool: pool});

        IERC20(token).forceApprove(underlying, type(uint256).max);
        IERC20(underlying).forceApprove(pool, type(uint256).max);
    }

    function allowanceOf(address pool) external view override returns (uint256) {
        if (!_poolsSet.contains(pool)) return 0;
        (address token,) = _getTokens(pool);
        return Math.min(IERC20(token).balanceOf(_DEPOSITOR), IERC20(token).allowance(_DEPOSITOR, address(this)));
    }

    function pullLiquidity(address pool, uint256 amount) external override {
        if (!_poolsSet.contains(pool)) revert InvalidPoolException(pool);
        (address token, address underlying) = _getTokens(pool);
        if (msg.sender != underlying) revert CallerIsNotUnderlyingException(msg.sender);
        IERC20(token).safeTransferFrom(_DEPOSITOR, address(this), amount);
        ERC4626(underlying).deposit(amount, address(this));
        ERC4626(pool).deposit(amount, address(this));
    }

    function claim(address pool) external override {
        if (!_poolsSet.contains(pool)) revert InvalidPoolException(pool);
        if (msg.sender != _DEPOSITOR) revert CallerIsNotDepositorException(msg.sender);
        (, address underlying) = _getTokens(pool);
        ERC4626(pool).redeem(ERC4626(pool).balanceOf(address(this)), address(this), address(this));
        ERC4626(underlying).redeem(ERC4626(underlying).balanceOf(address(this)), _DEPOSITOR, address(this));
    }

    function _getTokens(address pool) internal view returns (address token, address underlying) {
        underlying = _getAsset(pool);
        token = _getAsset(underlying);
    }

    function _getAsset(address vault) internal view returns (address) {
        return ERC4626(vault).asset();
    }
}

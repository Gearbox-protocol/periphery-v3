// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";

import {DefaultKYCUnderlying} from "./DefaultKYCUnderlying.sol";
import {AddressValidation} from "./libraries/AddressValidation.sol";
import {IKYCFactory} from "./interfaces/base/IKYCFactory.sol";
import {IOnDemandLiquidityProvider} from "./interfaces/base/IOnDemandLiquidityProvider.sol";

/// @title  On-demand KYC Underlying
/// @author Gearbox Foundation
/// @notice An ERC4626-like token wrapper to use as underlying in markets with KYC compliance and on-demand liquidity
///         provision. Liquidity deposits/withdrawals happen automatically on borrow/repay, governed by the on-demand
///         liquidity provider contract. Direct deposits/withdrawals are only allowed to active credit accounts.
contract OnDemandKYCUnderlying is DefaultKYCUnderlying {
    using SafeERC20 for ERC20;
    using AddressValidation for IAddressProvider;

    IOnDemandLiquidityProvider public immutable LIQUIDITY_PROVIDER;
    address internal _pool;

    error CallerIsNotActiveCreditAccountException(address caller);
    error CallerIsNotMarketConfiguratorAdminException(address caller);
    error InvalidPoolException(address pool);
    error InvalidLiquidityProviderException(address liquidityProvider);
    error PoolAlreadySetException();
    error PoolNotSetException();
    error InvalidTransferException(address from, address to);

    modifier onlyMarketConfiguratorAdmin(address pool) {
        _ensureCallerIsMarketConfiguratorAdmin(pool);
        _;
    }

    modifier onlyActiveCreditAccount(address caller) {
        if (!_isActiveCreditAccount(caller)) revert CallerIsNotActiveCreditAccountException(caller);
        _;
    }

    constructor(
        IAddressProvider addressProvider,
        IKYCFactory factory,
        ERC20 underlying,
        IOnDemandLiquidityProvider liquidityProvider,
        string memory namePrefix,
        string memory symbolPrefix
    ) DefaultKYCUnderlying(addressProvider, factory, underlying, namePrefix, symbolPrefix) {
        if (!addressProvider.isOnDemandLiquidityProvider(address(liquidityProvider))) {
            revert InvalidLiquidityProviderException(address(liquidityProvider));
        }
        LIQUIDITY_PROVIDER = liquidityProvider;
    }

    function contractType() public pure override returns (bytes32) {
        return "KYC_UNDERLYING::ON_DEMAND";
    }

    function version() public pure override returns (uint256) {
        return 3_10;
    }

    function serialize() external view override returns (bytes memory) {
        return abi.encode(FACTORY, asset(), getPool(), LIQUIDITY_PROVIDER);
    }

    function getPool() public view returns (address) {
        if (_pool == address(0)) revert PoolNotSetException();
        return _pool;
    }

    function setPool(address pool) external onlyMarketConfiguratorAdmin(pool) {
        if (_pool != address(0)) revert PoolAlreadySetException();
        if (IPoolV3(pool).asset() != address(this)) revert InvalidPoolException(pool);
        _pool = pool;
    }

    /// @dev Even though pools are assumed to use IRMs independent of utilization, this adjustment
    ///      is necessary in order to prevent available liquidity from underflowing on borrowing.
    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        address pool = getPool();
        if (account == pool) return LIQUIDITY_PROVIDER.allowanceOf(asset(), pool);
        return super.balanceOf(account);
    }

    /// @dev Just to be a little more consistent with the `balanceOf` adjustment
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return super.totalSupply() + LIQUIDITY_PROVIDER.allowanceOf(asset(), getPool());
    }

    /// @dev Adapters are trusted to ensure that `receiver` is also set to the same credit account
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override
        onlyActiveCreditAccount(caller)
    {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Adapters are trusted to ensure `owner` and `receiver` are also set to the same credit account
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        onlyActiveCreditAccount(caller)
    {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        address pool = getPool();
        bool fromZero = from == address(0);
        bool toZero = to == address(0);
        bool fromPool = !fromZero && from == pool;
        bool toPool = !toZero && to == pool;
        bool fromCreditAccount = !fromZero && !fromPool && _isActiveCreditAccount(from);
        bool toCreditAccount = !toZero && !toPool && _isActiveCreditAccount(to);

        bool allowed = (fromZero && (toPool || toCreditAccount)) || (fromPool && (toZero || toCreditAccount))
            || (fromCreditAccount && (toZero || toPool));
        if (!allowed) revert InvalidTransferException(from, to);

        if (fromPool && toCreditAccount) {
            // automatic deposit to the pool before borrowing funds to a credit account
            LIQUIDITY_PROVIDER.onBorrow(pool, asset(), to, amount);
            _mint(from, amount);
        } else if (fromZero && toPool) {
            // take underlying assets from LP on automatic deposit
            ERC20(asset()).safeTransferFrom(address(LIQUIDITY_PROVIDER), address(this), amount);
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        address pool = getPool();
        if (to == pool && _isActiveCreditAccount(from)) {
            // automatic withdrawal from the pool after a credit account repays funds
            _burn(to, amount);
            LIQUIDITY_PROVIDER.onRepay(pool, asset(), from, amount);
        } else if (to == address(0) && from == pool) {
            // return underlying assets to LP on automatic withdrawal
            ERC20(asset()).safeTransfer(address(LIQUIDITY_PROVIDER), amount);
        }
    }

    function _isActiveCreditAccount(address account) internal view returns (bool) {
        return FACTORY.isActiveCreditAccount(account);
    }

    function _ensureCallerIsMarketConfiguratorAdmin(address pool) internal view {
        if (!ADDRESS_PROVIDER.isPool(pool)) revert InvalidPoolException(pool);
        address marketConfigurator = AddressValidation.getMarketConfigurator(pool);
        if (msg.sender != IMarketConfigurator(marketConfigurator).admin()) {
            revert CallerIsNotMarketConfiguratorAdminException(msg.sender);
        }
    }
}

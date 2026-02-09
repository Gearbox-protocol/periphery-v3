// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";

import {DefaultSecuritizeUnderlying} from "./DefaultSecuritizeUnderlying.sol";
import {AddressValidation} from "./libraries/AddressValidation.sol";

/// @title On-demand Securitize Underlying
/// @author Gearbox Foundation
/// @notice An ERC4626-like token wrapper to use as underlying in Securitize markets with on-demand liquidity provision
///         - Deposits/withdrawals by the liquidity provider happen automatically on borrow/repay, as long as market is
///           added by the LP and unwrapped token approval is given to this contract
///         - Direct deposits/withdrawals are only allowed to credit accounts
///         - Only whitelisted non-frozen credit accounts can interact with the underlying token
contract OnDemandSecuritizeUnderlying is DefaultSecuritizeUnderlying {
    using SafeERC20 for ERC20;
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable LIQUIDITY_PROVIDER;
    EnumerableSet.AddressSet internal _poolsSet;

    event AddPool(address indexed pool);

    error CallerIsNotLiquidityProviderException(address caller);
    error CallerIsNotCreditAccountException(address caller);
    error InvalidPoolException(address pool);
    error InvalidTransferException(address from, address to);

    modifier onlyLiquidityProvider() {
        if (msg.sender != LIQUIDITY_PROVIDER) revert CallerIsNotLiquidityProviderException(msg.sender);
        _;
    }

    modifier onlyCreditAccount(address caller) {
        if (!_isCreditAccountFromFactory(caller)) revert CallerIsNotCreditAccountException(caller);
        _;
    }

    constructor(IAddressProvider addressProvider, ERC20 underlying, address liquidityProvider)
        DefaultSecuritizeUnderlying(addressProvider, underlying)
    {
        LIQUIDITY_PROVIDER = liquidityProvider;
    }

    function contractType() public pure override returns (bytes32) {
        return "SECURITIZE_UNDERLYING::ON_DEMAND";
    }

    function version() public pure override returns (uint256) {
        return 3_10;
    }

    function addPool(address pool) external onlyLiquidityProvider {
        if (!ADDRESS_PROVIDER.isPool(pool) || IPoolV3(pool).asset() != address(this)) {
            revert InvalidPoolException(pool);
        }
        if (!_poolsSet.add(pool)) return;
        emit AddPool(pool);
    }

    /// @dev Even though pools are assumed to use IRMs independent of utilization, this adjustment
    ///      is necessary in order to prevent available liquidity from underflowing on borrowing.
    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        if (_poolsSet.contains(account)) {
            ERC20 token = ERC20(asset());
            return Math.min(token.balanceOf(LIQUIDITY_PROVIDER), token.allowance(LIQUIDITY_PROVIDER, address(this)));
        }
        return super.balanceOf(account);
    }

    /// @dev Just to be a little more consistent with the `balanceOf` adjustment
    ///      (it still breaks ERC20 invariants unless there's exactly one pool).
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        ERC20 token = ERC20(asset());
        return Math.min(token.balanceOf(LIQUIDITY_PROVIDER), token.allowance(LIQUIDITY_PROVIDER, address(this)))
            + super.totalSupply();
    }

    /// @dev Adapters are trusted to ensure that `receiver` is also set to the same credit account
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
        override
        onlyCreditAccount(caller)
    {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Adapters are trusted to ensure `owner` and `receiver` are also set to the same credit account
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        onlyCreditAccount(caller)
    {
        // NOTE: can also enforce owner and receiver to be a credit account (in case we don't trust our adapters)
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        bool fromZero = from == address(0);
        bool toZero = to == address(0);
        bool fromPool = !fromZero && _poolsSet.contains(from);
        bool toPool = !toZero && _poolsSet.contains(to);
        bool fromCreditAccount = !fromZero && !fromPool && _isCreditAccountFromFactory(from);
        bool toCreditAccount = !toZero && !toPool && _isCreditAccountFromFactory(to);

        bool allowed = (fromZero && (toPool || toCreditAccount)) || (fromPool && (toZero || toCreditAccount))
            || (fromCreditAccount && (toZero || toPool));
        if (!allowed) revert InvalidTransferException(from, to);

        if (fromCreditAccount && _isFrozen(from)) revert FrozenCreditAccountException(from);
        if (toCreditAccount && _isFrozen(to)) revert FrozenCreditAccountException(to);

        if (fromPool && toCreditAccount) {
            // automatic deposit to the pool before borrowing funds to a credit account
            _mint(from, amount);
        } else if (fromZero && toPool) {
            // take underlying assets from LP on automatic deposit
            ERC20(asset()).safeTransferFrom(LIQUIDITY_PROVIDER, address(this), amount);
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (_poolsSet.contains(to) && _isCreditAccountFromFactory(from)) {
            // automatic withdrawal from the pool after a credit account repays funds
            _burn(to, amount);
        } else if (to == address(0) && _poolsSet.contains(from)) {
            // return underlying assets to LP on automatic withdrawal
            ERC20(asset()).safeTransfer(LIQUIDITY_PROVIDER, amount);
        }
    }

    function _isCreditAccountFromFactory(address account) internal view returns (bool) {
        return FACTORY.isCreditAccountFromFactory(account);
    }

    function _isFrozen(address creditAccount) internal view returns (bool) {
        return FACTORY.isFrozen(creditAccount);
    }
}

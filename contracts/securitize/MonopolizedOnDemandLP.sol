// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";

import {IOnDemandLiquidityProvider} from "./interfaces/base/IOnDemandLiquidityProvider.sol";
import {AddressValidation} from "./libraries/AddressValidation.sol";

contract MonopolizedOnDemandLP is IOnDemandLiquidityProvider {
    using SafeERC20 for IERC20;
    using AddressValidation for IAddressProvider;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Pool {
        address token;
        address pool;
    }

    bytes32 public constant contractType = "ON_DEMAND_LP::MONOPOLIZED";
    uint256 public constant version = 3_10;

    IAddressProvider public immutable ADDRESS_PROVIDER;
    address public immutable DEPOSITOR;

    EnumerableSet.AddressSet internal _tokensSet;
    mapping(address token => address pool) internal _pools;

    event AddPool(address indexed token, address indexed underlying, address indexed pool);

    error CallerIsNotMarketConfiguratorAdminException(address caller);
    error InvalidPoolException(address pool);
    error InvalidUnderlyingException(address underlying);
    error PoolAlreadyAddedForTokenException(address token);

    modifier onlyMarketConfiguratorAdmin(address pool) {
        _ensureCallerIsMarketConfiguratorAdmin(pool);
        _;
    }

    constructor(IAddressProvider addressProvider, address depositor) {
        ADDRESS_PROVIDER = addressProvider;
        DEPOSITOR = depositor;
    }

    function serialize() external view override returns (bytes memory) {
        return abi.encode(DEPOSITOR, getPools());
    }

    function getPools() public view returns (Pool[] memory pools) {
        uint256 length = _tokensSet.length();
        pools = new Pool[](length);
        for (uint256 i; i < length; ++i) {
            address token = _tokensSet.at(i);
            pools[i] = Pool(token, _pools[token]);
        }
    }

    function addPool(address pool) external onlyMarketConfiguratorAdmin(pool) {
        address underlying = ERC4626(pool).asset();
        if (!ADDRESS_PROVIDER.isKYCUnderlying(underlying)) revert InvalidUnderlyingException(underlying);

        address token = ERC4626(pool).asset();
        if (_pools[token] != address(0)) revert PoolAlreadyAddedForTokenException(token);
        _tokensSet.add(token);
        _pools[token] = pool;
        emit AddPool(token, underlying, pool);

        IERC20(token).forceApprove(underlying, type(uint256).max);
    }

    function allowanceOf(address token, address pool) external view override returns (uint256) {
        if (pool == address(0) || pool != _pools[token]) return 0;
        return Math.min(IERC20(token).allowance(DEPOSITOR, address(this)), IERC20(token).balanceOf(DEPOSITOR));
    }

    function onBorrow(address token, address pool, address, uint256 amount) external override {
        if (pool == address(0) || pool != _pools[token]) revert InvalidPoolException(pool);
        IERC20(token).safeTransferFrom(DEPOSITOR, address(this), amount);
    }

    function onRepay(address token, address pool, address, uint256 amount) external override {
        if (pool == address(0) || pool != _pools[token]) revert InvalidPoolException(pool);
        IERC20(token).safeTransfer(DEPOSITOR, amount);
    }

    function _ensureCallerIsMarketConfiguratorAdmin(address pool) internal view {
        if (!ADDRESS_PROVIDER.isPool(pool)) revert InvalidPoolException(pool);
        address marketConfigurator = AddressValidation.getMarketConfigurator(pool);
        if (msg.sender != IMarketConfigurator(marketConfigurator).admin()) {
            revert CallerIsNotMarketConfiguratorAdminException(msg.sender);
        }
    }
}

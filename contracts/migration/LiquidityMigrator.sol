// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title LiquidityMigrator
/// @notice Allows the instance owner to migrate a pool position of a user from one pool to another. The user gives an approval of
///         their pool shares to this contract. The instance owner can then migrate assets from specfic `poolFrom` to specific `poolTo`
///         at their discretion.
contract LiquidityMigrator is Ownable {
    event Migrate(address indexed user, uint256 assetsAmount);

    /// @notice The pool the assets are being migrated from
    address public immutable poolFrom;
    /// @notice The pool the assets are being migrated to
    address public immutable poolTo;

    /// @notice Constructs a new LiquidityMigrator
    /// @param ioProxy The address of the Instance Owner's ProxyCall contract. The instance owner migrates liquidity by
    ///                calling `migrate` through the proxy.
    /// @param _poolFrom The address of the pool the assets are being migrated from.
    /// @param _poolTo The address of the pool the assets are being migrated to.
    constructor(address ioProxy, address _poolFrom, address _poolTo) {
        _transferOwnership(ioProxy);
        poolFrom = _poolFrom;
        poolTo = _poolTo;
    }

    /// @notice Migrates assets from `poolFrom` to `poolTo` for `user`
    /// @param user The address of the user whose assets are being migrated
    /// @param assetsAmount The amount of assets to migrate
    function migrate(address user, uint256 assetsAmount) external onlyOwner {
        // The requested amount of assets is withdrawn from `poolFrom`
        IERC4626(poolFrom).withdraw(assetsAmount, address(this), user);
        // The same amount of assets is deposited into `poolTo`, with the user as the receiver
        IERC4626(poolTo).deposit(assetsAmount, user);

        emit Migrate(user, assetsAmount);
    }
}

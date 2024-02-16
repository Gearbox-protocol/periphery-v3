// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {CallerNotPausableAdminException} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";

import {MultiPause} from "../emergency/MultiPause.sol";

import {ForkTest} from "./ForkTest.sol";

contract MultiPauseTest is ForkTest {
    MultiPause multiPause;
    address admin;

    function setUp() public {
        _createFork();

        multiPause = new MultiPause(address(addressProvider));
        admin = makeAddr("ADMIN");

        vm.startPrank(configurator);
        acl.addPausableAdmin(admin);
        acl.addPausableAdmin(address(multiPause));
        vm.stopPrank();
    }

    function test_MP_01_functions_revert_if_caller_is_not_pausable_admin() public onlyFork {
        vm.expectRevert(CallerNotPausableAdminException.selector);
        multiPause.pauseContracts(new address[](0));

        vm.expectRevert(CallerNotPausableAdminException.selector);
        multiPause.pauseAllPools();

        vm.expectRevert(CallerNotPausableAdminException.selector);
        multiPause.pauseAllCreditManagers();

        vm.expectRevert(CallerNotPausableAdminException.selector);
        multiPause.pauseAllContracts();
    }

    function test_MP_02_pauseContracts_works_as_expected() public onlyFork {
        address[] memory pools = register.getPools();

        // ensure that at least one contract is paused
        if (!ACLNonReentrantTrait(pools[0]).paused()) {
            vm.prank(admin);
            ACLNonReentrantTrait(pools[0]).pause();
        }

        vm.prank(admin);
        multiPause.pauseContracts(pools);

        _assert_allPoolsPaused();
    }

    function test_MP_03_pauseAllPools_works_as_expected() public onlyFork {
        vm.prank(admin);
        multiPause.pauseAllPools();
        _assert_allPoolsPaused();
    }

    function test_MP_04_pauseAllCreditManagers_works_as_expected() public onlyFork {
        vm.prank(admin);
        multiPause.pauseAllCreditManagers();
        _assert_allManagersPaused();
    }

    function test_MP_05_pauseAllContracts_works_as_expected() public onlyFork {
        vm.prank(admin);
        multiPause.pauseAllContracts();
        _assert_allPoolsPaused();
        _assert_allManagersPaused();
    }

    function _assert_contractsPaused(address[] memory contracts) internal {
        for (uint256 i; i < contracts.length; ++i) {
            assertTrue(
                ACLNonReentrantTrait(contracts[i]).paused(),
                string.concat("Contract ", vm.toString(contracts[i]), " is not paused")
            );
        }
    }

    function _assert_allPoolsPaused() internal {
        address[] memory pools = register.getPools();
        for (uint256 i; i < pools.length; ++i) {
            assertTrue(
                ACLNonReentrantTrait(pools[i]).paused(), string.concat("Pool ", vm.toString(pools[i]), " is not paused")
            );
        }
    }

    function _assert_allManagersPaused() internal {
        address[] memory creditManagers = register.getCreditManagers();
        for (uint256 i; i < creditManagers.length; ++i) {
            if (ICreditManagerV3(creditManagers[i]).version() < 3_00) {
                assertTrue(
                    ACLNonReentrantTrait(creditManagers[i]).paused(),
                    string.concat("Manager ", vm.toString(creditManagers[i]), " is not paused")
                );
            } else {
                address facade = ICreditManagerV3(creditManagers[i]).creditFacade();
                assertTrue(
                    ACLNonReentrantTrait(facade).paused(),
                    string.concat("Facade ", vm.toString(facade), " is not paused")
                );
            }
        }
    }
}

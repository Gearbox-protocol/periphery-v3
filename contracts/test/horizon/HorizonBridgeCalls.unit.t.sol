// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

import {IHorizonGearboxBridge} from "../../interfaces/IHorizonGearboxBridge.sol";
import {HorizonBridgeCalls} from "../../libraries/HorizonBridgeCalls.sol";

contract MockCreditManager {
    address public creditFacade;
    mapping(address => address) public adapterToContract;

    constructor(address facade_) {
        creditFacade = facade_;
    }

    function setAdapter(address adapter, address target) external {
        adapterToContract[adapter] = target;
    }
}

/// @dev Exposes library entrypoints with calldata for unit tests
contract HorizonBridgeCallsHarness {
    function validateOpenCalls(address creditManager, MultiCall[] calldata calls) external view {
        HorizonBridgeCalls.validateOpenCalls(creditManager, calls);
    }

    function validateCloseCalls(address creditManager, MultiCall[] calldata calls, address allowedWithdrawTo)
        external
        view
    {
        HorizonBridgeCalls.validateCloseCalls(creditManager, calls, allowedWithdrawTo);
    }
}

contract HorizonBridgeCallsUnitTest is Test {
    address internal facade = makeAddr("facade");
    address internal adapter = makeAddr("adapter");
    address internal bridge = makeAddr("bridge");
    address internal stranger = makeAddr("stranger");

    MockCreditManager internal cm;
    HorizonBridgeCallsHarness internal harness;

    function setUp() public {
        cm = new MockCreditManager(facade);
        cm.setAdapter(adapter, makeAddr("target"));
        harness = new HorizonBridgeCallsHarness();
    }

    function test_validateOpenCalls_allowsSlippageAndAdapters() public {
        MultiCall[] memory calls = new MultiCall[](3);
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())
        });
        calls[1] = MultiCall({
            target: facade, callData: abi.encodeWithSelector(ICreditFacadeV3Multicall.storeExpectedBalances.selector)
        });
        calls[2] = MultiCall({target: adapter, callData: hex"deadbeef"});

        harness.validateOpenCalls(address(cm), calls);
    }

    function test_validateOpenCalls_rejectsIncreaseDebt() public {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (1))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IHorizonGearboxBridge.ForbiddenFacadeSelectorException.selector,
                ICreditFacadeV3Multicall.increaseDebt.selector
            )
        );
        harness.validateOpenCalls(address(cm), calls);
    }

    function test_validateOpenCalls_rejectsUnknownAdapter() public {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({target: makeAddr("unknown"), callData: hex"00"});

        vm.expectRevert(
            abi.encodeWithSelector(IHorizonGearboxBridge.UnknownAdapterException.selector, makeAddr("unknown"))
        );
        harness.validateOpenCalls(address(cm), calls);
    }

    function test_validateCloseCalls_allowsDebtAndBridgeWithdraw() public {
        MultiCall[] memory calls = new MultiCall[](3);
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (100))
        });
        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (makeAddr("token"), int96(1), uint96(0)))
        });
        calls[2] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (makeAddr("asset"), uint256(1), bridge))
        });

        harness.validateCloseCalls(address(cm), calls, bridge);
    }

    function test_validateCloseCalls_rejectsWithdrawToStranger() public {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (makeAddr("asset"), uint256(1), stranger)
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(IHorizonGearboxBridge.ForbiddenWithdrawRecipientException.selector, stranger)
        );
        harness.validateCloseCalls(address(cm), calls, bridge);
    }

    function test_validateCloseCalls_rejectsAddCollateral() public {
        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (makeAddr("token"), uint256(1)))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IHorizonGearboxBridge.ForbiddenFacadeSelectorException.selector,
                ICreditFacadeV3Multicall.addCollateral.selector
            )
        );
        harness.validateCloseCalls(address(cm), calls, bridge);
    }
}

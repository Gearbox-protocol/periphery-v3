// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {PauseMulticall} from "../emergency/PauseMulticall.sol";
import {
    IAddressProviderV3,
    AP_CONTRACTS_REGISTER,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {ContractsRegister} from "@gearbox-protocol/core-v2/contracts/core/ContractsRegister.sol";
import {
    IAddressProviderV3,
    AP_CONTRACTS_REGISTER
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {NetworkDetector} from "@gearbox-protocol/sdk-gov/contracts/NetworkDetector.sol";

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

address constant ap = 0x9ea7b04Da02a5373317D745c1571c84aaD03321D;

contract PauseMulticallTest is Test {
    uint256 chainId;

    PauseMulticall pm;

    constructor() {
        NetworkDetector nd = new NetworkDetector();
        chainId = nd.chainId();
    }

    modifier liveTestOnly() {
        if (chainId == 1) {
            _;
        }
    }

    function setUp() public liveTestOnly {
        pm = new PauseMulticall(ap);
    }

    ///
    /// TESTS
    ///
}

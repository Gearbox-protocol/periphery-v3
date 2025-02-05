// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";
import {AdapterState} from "../types/CreditSuiteData.sol";
import {IAdapterCompressor} from "../interfaces/IAdapterCompressor.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IStateSerializer} from "../interfaces/IStateSerializer.sol";
import {AP_ADAPTER_COMPRESSOR} from "../libraries/Literals.sol";

interface ILegacyAdapter {
    function _gearboxAdapterVersion() external view returns (uint16);
    function _gearboxAdapterType() external view returns (uint8);
}

contract AdapterCompressor is IAdapterCompressor {
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = AP_ADAPTER_COMPRESSOR;

    mapping(uint8 => bytes32) public contractTypes;

    constructor() {
        contractTypes[uint8(AdapterType.BALANCER_VAULT)] = "ADAPTER::BALANCER_VAULT";
        contractTypes[uint8(AdapterType.BALANCER_V3_ROUTER)] = "ADAPTER::BALANCER_V3_ROUTER";
        contractTypes[uint8(AdapterType.CAMELOT_V3_ROUTER)] = "ADAPTER::CAMELOT_V3_ROUTER";
        contractTypes[uint8(AdapterType.CONVEX_V1_BASE_REWARD_POOL)] = "ADAPTER::CVX_V1_BASE_REWARD_POOL";
        contractTypes[uint8(AdapterType.CONVEX_V1_BOOSTER)] = "ADAPTER::CVX_V1_BOOSTER";
        contractTypes[uint8(AdapterType.CURVE_V1_2ASSETS)] = "ADAPTER::CURVE_V1_2ASSETS";
        contractTypes[uint8(AdapterType.CURVE_V1_3ASSETS)] = "ADAPTER::CURVE_V1_3ASSETS";
        contractTypes[uint8(AdapterType.CURVE_V1_4ASSETS)] = "ADAPTER::CURVE_V1_4ASSETS";
        contractTypes[uint8(AdapterType.CURVE_STABLE_NG)] = "ADAPTER::CURVE_STABLE_NG";
        contractTypes[uint8(AdapterType.CURVE_V1_STECRV_POOL)] = "ADAPTER::CURVE_V1_STECRV_POOL";
        contractTypes[uint8(AdapterType.CURVE_V1_WRAPPER)] = "ADAPTER::CURVE_V1_WRAPPER";
        contractTypes[uint8(AdapterType.DAI_USDS_EXCHANGE)] = "ADAPTER::DAI_USDS_EXCHANGE";
        contractTypes[uint8(AdapterType.EQUALIZER_ROUTER)] = "ADAPTER::EQUALIZER_ROUTER";
        contractTypes[uint8(AdapterType.ERC4626_VAULT)] = "ADAPTER::ERC4626_VAULT";
        contractTypes[uint8(AdapterType.LIDO_V1)] = "ADAPTER::LIDO_V1";
        contractTypes[uint8(AdapterType.LIDO_WSTETH_V1)] = "ADAPTER::LIDO_WSTETH_V1";
        contractTypes[uint8(AdapterType.MELLOW_ERC4626_VAULT)] = "ADAPTER::MELLOW_ERC4626_VAULT";
        contractTypes[uint8(AdapterType.MELLOW_LRT_VAULT)] = "ADAPTER::MELLOW_LRT_VAULT";
        contractTypes[uint8(AdapterType.PENDLE_ROUTER)] = "ADAPTER::PENDLE_ROUTER";
        contractTypes[uint8(AdapterType.STAKING_REWARDS)] = "ADAPTER::STAKING_REWARDS";
        contractTypes[uint8(AdapterType.UNISWAP_V2_ROUTER)] = "ADAPTER::UNISWAP_V2_ROUTER";
        contractTypes[uint8(AdapterType.UNISWAP_V3_ROUTER)] = "ADAPTER::UNISWAP_V3_ROUTER";
        contractTypes[uint8(AdapterType.VELODROME_V2_ROUTER)] = "ADAPTER::VELODROME_V2_ROUTER";
        contractTypes[uint8(AdapterType.YEARN_V2)] = "ADAPTER::YEARN_V2";
        contractTypes[uint8(AdapterType.ZIRCUIT_POOL)] = "ADAPTER::ZIRCUIT_POOL";
    }

    function getAdapters(address creditManager) external view returns (AdapterState[] memory adapters) {
        ICreditConfiguratorV3 creditConfigurator =
            ICreditConfiguratorV3(ICreditManagerV3(creditManager).creditConfigurator());

        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();
        uint256 len = allowedAdapters.length;

        adapters = new AdapterState[](len);
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address adapter = allowedAdapters[i];
                adapters[i].baseParams.addr = adapter;
                try IVersion(adapter).contractType() returns (bytes32 contractType_) {
                    adapters[i].baseParams.contractType = contractType_;
                } catch {
                    adapters[i].baseParams.contractType = contractTypes[ILegacyAdapter(adapter)._gearboxAdapterType()];
                }

                try IVersion(adapter).version() returns (uint256 v) {
                    adapters[i].baseParams.version = v;
                } catch {
                    adapters[i].baseParams.version = ILegacyAdapter(adapter)._gearboxAdapterVersion();
                }

                try IStateSerializer(adapter).serialize() returns (bytes memory serializedParams) {
                    adapters[i].baseParams.serializedParams = serializedParams;
                } catch {}

                adapters[i].targetContract = ICreditManagerV3(creditManager).adapterToContract(adapter);
            }
        }
    }
}

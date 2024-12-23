// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.17;

import {AdapterType} from "@gearbox-protocol/sdk-gov/contracts/AdapterType.sol";
import {ContractAdapter} from "../types/MarketData.sol";
import {IAdapterCompressor} from "../interfaces/IAdapterCompressor.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IStateSerializer} from "../interfaces/IStateSerializer.sol";
import {IVersion} from "../interfaces/IVersion.sol";

interface ILegacyAdapter {
    function _gearboxAdapterVersion() external view returns (uint16);
    function _gearboxAdapterType() external view returns (uint8);
}

contract AdapterCompressor is IAdapterCompressor {
    uint256 public constant version = 3_10;
    bytes32 public constant override contractType = "ADAPTER_COMPRESSOR";

    mapping(uint8 => bytes32) public contractTypes;

    constructor() {
        contractTypes[uint8(AdapterType.ABSTRACT)] = "AD_ABSTRACT";
        contractTypes[uint8(AdapterType.UNISWAP_V2_ROUTER)] = "AD_UNISWAP_V2_ROUTER";
        contractTypes[uint8(AdapterType.UNISWAP_V3_ROUTER)] = "AD_UNISWAP_V3_ROUTER";
        contractTypes[uint8(AdapterType.CURVE_V1_EXCHANGE_ONLY)] = "AD_CURVE_V1_EXCHANGE_ONLY";
        contractTypes[uint8(AdapterType.YEARN_V2)] = "AD_YEARN_V2";
        contractTypes[uint8(AdapterType.CURVE_V1_2ASSETS)] = "AD_CURVE_V1_2ASSETS";
        contractTypes[uint8(AdapterType.CURVE_V1_3ASSETS)] = "AD_CURVE_V1_3ASSETS";
        contractTypes[uint8(AdapterType.CURVE_V1_4ASSETS)] = "AD_CURVE_V1_4ASSETS";
        contractTypes[uint8(AdapterType.CURVE_V1_STECRV_POOL)] = "AD_CURVE_V1_STECRV_POOL";
        contractTypes[uint8(AdapterType.CURVE_V1_WRAPPER)] = "AD_CURVE_V1_WRAPPER";
        contractTypes[uint8(AdapterType.CONVEX_V1_BASE_REWARD_POOL)] = "AD_CONVEX_V1_BASE_REWARD_POOL";
        contractTypes[uint8(AdapterType.CONVEX_V1_BOOSTER)] = "AD_CONVEX_V1_BOOSTER";
        contractTypes[uint8(AdapterType.CONVEX_V1_CLAIM_ZAP)] = "AD_CONVEX_V1_CLAIM_ZAP";
        contractTypes[uint8(AdapterType.LIDO_V1)] = "AD_LIDO_V1";
        contractTypes[uint8(AdapterType.UNIVERSAL)] = "AD_UNIVERSAL";
        contractTypes[uint8(AdapterType.LIDO_WSTETH_V1)] = "AD_LIDO_WSTETH_V1";
        contractTypes[uint8(AdapterType.BALANCER_VAULT)] = "AD_BALANCER_VAULT";
        contractTypes[uint8(AdapterType.AAVE_V2_LENDING_POOL)] = "AD_AAVE_V2_LENDING_POOL";
        contractTypes[uint8(AdapterType.AAVE_V2_WRAPPED_ATOKEN)] = "AD_AAVE_V2_WRAPPED_ATOKEN";
        contractTypes[uint8(AdapterType.COMPOUND_V2_CERC20)] = "AD_COMPOUND_V2_CERC20";
        contractTypes[uint8(AdapterType.COMPOUND_V2_CETHER)] = "AD_COMPOUND_V2_CETHER";
        contractTypes[uint8(AdapterType.ERC4626_VAULT)] = "AD_ERC4626_VAULT";
        contractTypes[uint8(AdapterType.VELODROME_V2_ROUTER)] = "AD_VELODROME_V2_ROUTER";
        contractTypes[uint8(AdapterType.CURVE_STABLE_NG)] = "AD_CURVE_STABLE_NG";
        contractTypes[uint8(AdapterType.CAMELOT_V3_ROUTER)] = "AD_CAMELOT_V3_ROUTER";
        contractTypes[uint8(AdapterType.CONVEX_L2_BOOSTER)] = "AD_CONVEX_L2_BOOSTER";
        contractTypes[uint8(AdapterType.CONVEX_L2_REWARD_POOL)] = "AD_CONVEX_L2_REWARD_POOL";
        contractTypes[uint8(AdapterType.AAVE_V3_LENDING_POOL)] = "AD_AAVE_V3_LENDING_POOL";
        contractTypes[uint8(AdapterType.ZIRCUIT_POOL)] = "AD_ZIRCUIT_POOL";
        contractTypes[uint8(AdapterType.SYMBIOTIC_DEFAULT_COLLATERAL)] = "AD_SYMBIOTIC_DEFAULT_COLLATERAL";
        contractTypes[uint8(AdapterType.MELLOW_LRT_VAULT)] = "AD_MELLOW_LRT_VAULT";
        contractTypes[uint8(AdapterType.PENDLE_ROUTER)] = "AD_PENDLE_ROUTER";
        contractTypes[uint8(AdapterType.DAI_USDS_EXCHANGE)] = "AD_DAI_USDS_EXCHANGE";
        contractTypes[uint8(AdapterType.MELLOW_ERC4626_VAULT)] = "AD_MELLOW_ERC4626_VAULT";
        contractTypes[uint8(AdapterType.STAKING_REWARDS)] = "AD_STAKING_REWARDS";
        // TODO: should add equalizer as well
    }

    function getContractAdapters(address creditManager) external view returns (ContractAdapter[] memory adapters) {
        ICreditConfiguratorV3 creditConfigurator =
            ICreditConfiguratorV3(ICreditManagerV3(creditManager).creditConfigurator());

        address[] memory allowedAdapters = creditConfigurator.allowedAdapters();
        uint256 len = allowedAdapters.length;

        adapters = new ContractAdapter[](len);
        bytes memory stateSerialised;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                address adapter = allowedAdapters[i];
                adapters[i].baseParams.addr = adapter;
                try IVersion(adapter).contractType() returns (bytes32 adapterType) {
                    adapters[i].baseParams.contractType = adapterType;
                } catch {
                    try ILegacyAdapter(adapter)._gearboxAdapterType() returns (uint8 adapterType) {
                        adapters[i].baseParams.contractType = contractTypes[adapterType];
                    } catch {
                        adapters[i].baseParams.contractType = "AD_ABSTRACT";
                    }
                }

                try IVersion(adapter).version() returns (uint256 v) {
                    adapters[i].baseParams.version = v;
                } catch {
                    try ILegacyAdapter(adapter)._gearboxAdapterVersion() returns (uint16 v) {
                        adapters[i].baseParams.version = uint256(v);
                    } catch {}
                }

                try IStateSerializer(adapter).serialize() returns (bytes memory serializedParams) {
                    adapters[i].baseParams.serializedParams = serializedParams;
                } catch {}

                adapters[i].targetContract = ICreditManagerV3(creditManager).adapterToContract(adapter);
            }
        }
    }
}

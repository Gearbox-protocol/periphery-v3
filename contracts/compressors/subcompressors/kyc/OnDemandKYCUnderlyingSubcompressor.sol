// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IKYCUnderlyingSubcompressor} from "../../../interfaces/base/IKYCUnderlyingSubcompressor.sol";
import {IOnDemandKYCUnderlying} from "../../../interfaces/IOnDemandKYCUnderlying.sol";

import {DOMAIN_KYC_UNDERLYING} from "../../../libraries/AddressValidation.sol";
import {BaseLib, BaseParams} from "../../../libraries/BaseLib.sol";

contract OnDemandKYCUnderlyingSubcompressor is IKYCUnderlyingSubcompressor {
    using BaseLib for address;

    bytes32 public constant override contractType = "GLOBAL::ON_DEMAND_KU_SC";
    uint256 public constant override version = 3_10;

    function getCompressedType() external pure override returns (bytes32, bytes32) {
        return (DOMAIN_KYC_UNDERLYING, "ON_DEMAND");
    }

    function getUnderlyingData(address underlying) external view override returns (bytes memory) {
        address liquidityProvider = IOnDemandKYCUnderlying(underlying).getLiquidityProvider();
        // let's just hope that on-demand LPs don't have more nested contracts and serialized state is sufficient
        return abi.encode(liquidityProvider.getBaseParams());
    }
}

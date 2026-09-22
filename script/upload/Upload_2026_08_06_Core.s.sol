// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Bytecode} from "@gearbox-protocol/permissionless/contracts/interfaces/Types.sol";
import {UploadBytecode} from "@gearbox-protocol/permissionless/script/UploadBytecode.sol";

import {DefaultAccountFactoryV3} from "@gearbox-protocol/core-v3/contracts/core/DefaultAccountFactoryV3.sol";

contract Upload_2026_08_06_Core is UploadBytecode {
    function _getContracts() internal pure override returns (Bytecode[] memory bytecodes) {
        bytecodes = new Bytecode[](1);
        bytecodes[0].contractType = "ACCOUNT_FACTORY::DEFAULT";
        bytecodes[0].version = 3_11;
        bytecodes[0].initCode = type(DefaultAccountFactoryV3).creationCode;
        bytecodes[0].source =
            "https://github.com/Gearbox-protocol/core-v3/blob/dd1e0be09fccd22c4c3e89681b840716baaf739f/contracts/core/DefaultAccountFactoryV3.sol";
    }
}

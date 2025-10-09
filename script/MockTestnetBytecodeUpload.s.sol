// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {BCRHelpers} from "@gearbox-protocol/permissionless/contracts/test/helpers/BCRHelpers.sol";
import {InstanceManager} from "@gearbox-protocol/permissionless/contracts/instance/InstanceManager.sol";
import {BytecodeRepository} from "@gearbox-protocol/permissionless/contracts/global/BytecodeRepository.sol";
import {Bytecode, AuditReport} from "@gearbox-protocol/permissionless/contracts/interfaces/Types.sol";
import {Bytecodes} from "./Bytecodes.sol";
import {BytecodeRepositoryMock} from "./BytecodeRepositoryMock.sol";
import {AnvilHelper} from "./AnvilHelper.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LibBytes} from "@solady/utils/LibBytes.sol";
import "forge-std/Script.sol";

address constant IM = 0x77777777144339Bdc3aCceE992D8d4D31734CB2e;

contract UploadMockTestnetBytecode is Script, BCRHelpers, Bytecodes, AnvilHelper {
    address ccmProxy;

    function _mockBytecodeRepositoryBytecode(address bytecodeRepository) internal {
        address bcrOwner = BytecodeRepository(bytecodeRepository).owner();

        address ownerPlaceholder = makeAddr("placeholder");
        address bytecodeRepositoryMock = address(new BytecodeRepositoryMock(ownerPlaceholder));
        bytes memory findBytes = abi.encodePacked(ownerPlaceholder);
        bytes memory replacementBytes = abi.encodePacked(bcrOwner);
        bytes memory updatedBytecode = LibBytes.replace(bytecodeRepositoryMock.code, findBytes, replacementBytes);
        _replaceBytecode(bytecodeRepository, updatedBytecode);
    }

    function run() external {
        bytes32 auditorPrivateKey = vm.envOr("AUDITOR_PRIVATE_KEY", bytes32(0));

        if (auditorPrivateKey == bytes32(0)) {
            revert("AUDITOR_PRIVATE_KEY is not set");
        }

        bytecodeRepository = InstanceManager(IM).bytecodeRepository();
        _mockBytecodeRepositoryBytecode(bytecodeRepository);
        ccmProxy = InstanceManager(IM).crossChainGovernanceProxy();

        VmSafe.Wallet memory auditor = vm.createWallet(uint256(auditorPrivateKey));

        vm.startBroadcast(auditor.addr);

        _startPrankOrBroadcast(ccmProxy);
        BytecodeRepository(bytecodeRepository).addAuditor(auditor.addr, "auditor");
        _stopPrankOrBroadcast();

        Bytecode[] memory bcs = _getAdapterContracts();

        for (uint256 i = 0; i < bcs.length; i++) {
            _safeUploadBytecode(auditor, bcs[i]);
        }

        bcs = _getPriceFeedContracts();

        for (uint256 i = 0; i < bcs.length; i++) {
            _safeUploadBytecode(auditor, bcs[i]);
        }

        bcs = _getHelperContracts();

        for (uint256 i = 0; i < bcs.length; i++) {
            _safeUploadBytecode(auditor, bcs[i]);
        }

        vm.stopBroadcast();
    }

    function _safeUploadBytecode(VmSafe.Wallet memory auditor, Bytecode memory bc) internal {
        if (BytecodeRepository(bytecodeRepository).getAllowedBytecodeHash(bc.contractType, bc.version) == bytes32(0)) {
            bytes32 bytecodeHash = _uploadByteCodeAndSign(auditor, auditor, bc.initCode, bc.contractType, bc.version);
            BytecodeRepositoryMock(bytecodeRepository).exposed_allowContract(bytecodeHash, bc.contractType, bc.version);
        }
    }
}

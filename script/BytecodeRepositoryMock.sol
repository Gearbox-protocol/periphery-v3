// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {BytecodeRepository} from "@gearbox-protocol/permissionless/contracts/global/BytecodeRepository.sol";
import {Bytecode, AuditReport, BytecodePointer} from "@gearbox-protocol/permissionless/contracts/interfaces/Types.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract BytecodeRepositoryMock is BytecodeRepository {
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor(address owner_) BytecodeRepository(owner_) {}

    function exposed_allowContract(bytes32 bytecodeHash, bytes32 cType, uint256 ver) external {
        _allowContract(bytecodeHash, cType, ver);
    }

    function _submitAuditReport(bytes32 bytecodeHash, AuditReport memory auditReport) internal {
        _auditReports[bytecodeHash].push(auditReport);
    }

    function _uploadBytecode(Bytecode calldata bytecode) internal {
        bytes32 bytecodeHash = computeBytecodeHash(bytecode);
        if (isBytecodeUploaded(bytecodeHash)) return;

        _validateContractType(bytecode.contractType);
        _validateVersion(bytecode.contractType, bytecode.version);
        if (_allowedBytecodeHashes[bytecode.contractType][bytecode.version] != 0) {
            revert BytecodeIsAlreadyAllowedException(bytecode.contractType, bytecode.version);
        }
        address[] memory initCodePointers = _writeInitCode(bytecode.initCode);
        _bytecodeByHash[bytecodeHash] = BytecodePointer({
            contractType: bytecode.contractType,
            version: bytecode.version,
            initCodePointers: initCodePointers,
            author: bytecode.author,
            source: bytecode.source,
            authorSignature: bytecode.authorSignature
        });
    }

    function exposed_addBytecode(Bytecode[] calldata bytecodes) external {
        address auditor = _auditorsSet.at(0);
        for (uint256 i; i < bytecodes.length; ++i) {
            _uploadBytecode(bytecodes[i]);
            bytes32 bytecodeHash = computeBytecodeHash(bytecodes[i]);
            _submitAuditReport(bytecodeHash, AuditReport({auditor: auditor, reportUrl: "dummy/report", signature: ""}));
            _allowContract(bytecodeHash, bytecodes[i].contractType, bytecodes[i].version);
        }
    }
}
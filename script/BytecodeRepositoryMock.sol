// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {BytecodeRepository} from "@gearbox-protocol/permissionless/contracts/global/BytecodeRepository.sol";

contract BytecodeRepositoryMock is BytecodeRepository {
    constructor(address owner_) BytecodeRepository(owner_) {}

    function exposed_allowContract(bytes32 bytecodeHash, bytes32 cType, uint256 ver) external {
        _allowContract(bytecodeHash, cType, ver);
    }
}

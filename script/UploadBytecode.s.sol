// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    Bytecode,
    IBytecodeRepository
} from "@gearbox-protocol/permissionless/contracts/interfaces/IBytecodeRepository.sol";
import {Bytecodes} from "./Bytecodes.sol";

contract UploadBytecode is Script, Bytecodes {
    VmSafe.Wallet public author;
    address public bytecodeRepository;
    bytes32 public domainSeparator;

    function setUp() public {
        author = vm.createWallet(vm.envUint("AUTHOR_PRIVATE_KEY"));
        bytecodeRepository = vm.envAddress("BYTECODE_REPOSITORY");
        domainSeparator = IBytecodeRepository(bytecodeRepository).domainSeparatorV4();
    }

    function run() public {
        vm.startBroadcast(author.privateKey);
        _uploadBytecodes(_getAdapterContracts());
        _uploadBytecodes(_getBotContracts());
        _uploadBytecodes(_getCoreContracts());
        _uploadBytecodes(_getDegenNFTContracts());
        _uploadBytecodes(_getInterestRateModelContracts());
        _uploadBytecodes(_getLossPolicyContracts());
        _uploadBytecodes(_getPriceFeedContracts());
        _uploadBytecodes(_getRateKeeperContracts());
        _uploadBytecodes(_getZapperContracts());
        vm.stopBroadcast();
    }

    function _uploadBytecodes(Bytecode[] memory bytecodes) internal {
        for (uint256 i; i < bytecodes.length; ++i) {
            bytecodes[i].author = author.addr;
            bytes32 bytecodeHash = IBytecodeRepository(bytecodeRepository).computeBytecodeHash(bytecodes[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(author, ECDSA.toTypedDataHash(domainSeparator, bytecodeHash));
            bytecodes[i].authorSignature = abi.encodePacked(r, s, v);
            IBytecodeRepository(bytecodeRepository).uploadBytecode(bytecodes[i]);
        }
    }
}

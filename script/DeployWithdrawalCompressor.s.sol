// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {WithdrawalCompressor} from "../contracts/compressors/WithdrawalCompressor.sol";
import {MellowWithdrawalSubcompressor} from
    "../contracts/compressors/subcompressors/withdrawal/MellowWithdrawalSubcompressor.sol";
import {InfinifiWithdrawalSubcompressor} from
    "../contracts/compressors/subcompressors/withdrawal/InfinifiWithdrawalSubcompressor.sol";

import {console} from "forge-std/console.sol";

contract DeployWithdrawalCompressor is Script {
    address constant addressProvider = 0xF7f0a609BfAb9a0A98786951ef10e5FE26cC1E38;
    address constant ioProxy = 0xBcD875f0D62B9AA22481c81975F9AE1753Fc559A;
    VmSafe.Wallet deployer;

    WithdrawalCompressor public wc;
    MellowWithdrawalSubcompressor public mwsc;
    InfinifiWithdrawalSubcompressor public iusc;

    function run() external {
        deployer = vm.createWallet(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        vm.startBroadcast(deployer.privateKey);
        wc = new WithdrawalCompressor(deployer.addr, addressProvider);
        mwsc = new MellowWithdrawalSubcompressor();
        iusc = new InfinifiWithdrawalSubcompressor();

        wc.setSubcompressor(address(mwsc));
        wc.setSubcompressor(address(iusc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::MELLOW_WITHDRAWAL", "GLOBAL::MELLOW_WD_SC");
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::INFINIFI_UNWIND", "GLOBAL::INFINIFI_WD_SC");

        vm.stopBroadcast();

        console.log("WithdrawalCompressor deployed to", address(wc));
    }
}

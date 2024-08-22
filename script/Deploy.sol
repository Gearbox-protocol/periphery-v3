// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";
import {MarketCompressorV3} from "../contracts/compressors/MarketCompressorV3.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        // address oldAddressProvider = vm.envAddress("ADDRESS_PROVIDER");
        // address vetoAdmin = vm.envAddress("VETO_ADMIN");

        vm.startBroadcast(deployerPrivateKey);

        address priceFeedCompressor = address(new PriceFeedCompressor());
        address marketCompressor = address(new MarketCompressorV3(priceFeedCompressor));

        vm.stopBroadcast();
    }

    function stringToBytes32(string memory source) public pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }
}

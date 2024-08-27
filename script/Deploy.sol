// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {PriceFeedCompressor} from "../contracts/compressors/PriceFeedCompressor.sol";
import {MarketCompressor} from "../contracts/compressors/MarketCompressor.sol";

import "forge-std/Script.sol";
import "forge-std/console.sol";

struct AddressToml {
    address addressProvider;
}

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // READ toml;
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/address.toml");
        string memory toml = vm.readFile(path);
        bytes memory data = vm.parseToml(toml);
        AddressToml memory configToml = abi.decode(data, (AddressToml));

        address addressProvider = configToml.addressProvider;
        // address vetoAdmin = vm.envAddress("VETO_ADMIN");

        vm.startBroadcast(deployerPrivateKey);

        address priceFeedCompressor = address(new PriceFeedCompressor());
        address marketCompressor = address(new MarketCompressor(addressProvider, priceFeedCompressor));

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

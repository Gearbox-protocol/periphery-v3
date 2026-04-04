// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {KYCCompressor} from "../contracts/compressors/KYCCompressor.sol";
import {
    OnDemandKYCUnderlyingSubcompressor
} from "../contracts/compressors/subcompressors/kyc/OnDemandKYCUnderlyingSubcompressor.sol";
import {
    SecuritizeKYCFactorySubcompressor
} from "../contracts/compressors/subcompressors/kyc/SecuritizeKYCFactorySubcompressor.sol";

import {ISecuritizeDegenNFT} from "../contracts/interfaces/ISecuritizeDegenNFT.sol";
import {IDSToken} from "../contracts/interfaces/external/securitize/IDSToken.sol";

import {TYPE_KYC_COMPRESSOR} from "../contracts/libraries/AddressValidation.sol";

import {SecuritizeAttachHelper} from "../contracts/test/attach/securitize/SecuritizeAttachHelper.sol";

contract DeploySecuritizeContracts is Script, SecuritizeAttachHelper {
    address public investor;
    address public depositor;

    function run() external {
        vm.skip(ADDRESS_PROVIDER.code.length == 0, "Not in an attach mode");
        vm.skip(block.chainid != 1, "Not Ethereum mainnet");

        uint256 authorPrivateKey = vm.envOr("AUTHOR_PRIVATE_KEY", uint256(0));
        require(authorPrivateKey != 0, "AUTHOR_PRIVATE_KEY is not set");
        deployer = author = auditor = riskCurator = vm.createWallet(authorPrivateKey);

        _omniPrank(USDC_DONOR);
        ERC20(USDC).transfer(riskCurator.addr, 100_000e6);

        investor = depositor = securitize = deployer.addr;

        _setUp();
        _setUpBytecode();
        _attachSecuritize(investor);

        _omniPrank(securitize);
        IDSToken(dsToken).issueTokens(investor, 1000000 ether);

        // NOTE: adding degen NFT as periphery contract is required to use it in the credit suite
        _addPeripheryContract(degenNFT);

        _addPriceFeed(USDC_PRICE_FEED, 1 days, "Chainlink USDC price feed");
        _allowPriceFeed(USDC, USDC_PRICE_FEED);
        _allowPriceFeed(dsToken, onePriceFeed);
        _configureLocal(degenNFT, abi.encodeCall(ISecuritizeDegenNFT.addRegistrar, (registrar)));

        _createMarketWithDefaultKYCUnderlying();
        _createMarketWithOnDemandKYCUnderlying(depositor);

        _startOmniPrank(deployer);
        address compressor = address(new KYCCompressor(addressProvider));
        address onDemandUnderlyingSubcompressor = address(new OnDemandKYCUnderlyingSubcompressor());
        address securitizeFactorySubcompressor = address(new SecuritizeKYCFactorySubcompressor());
        _stopOmniPrank();

        _setGlobalAddress(TYPE_KYC_COMPRESSOR, compressor, true);
        _configureLocal(compressor, abi.encodeCall(KYCCompressor.setSubcompressor, (onDemandUnderlyingSubcompressor)));
        _configureLocal(compressor, abi.encodeCall(KYCCompressor.setSubcompressor, (securitizeFactorySubcompressor)));

        vm.serializeAddress("Addresses", "marketConfigurator", address(marketConfigurator));
        string memory finalJson = vm.serializeAddress("Addresses", "factory", factory);
        vm.writeJson(finalJson, "kyc-addresses.json");
    }
}

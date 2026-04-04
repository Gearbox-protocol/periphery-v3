// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {AttachScriptBase} from "@gearbox-protocol/permissionless/contracts/test/suite/AttachScriptBase.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {ERC4626UnderlyingZapper} from "@gearbox-protocol/integrations-v3/contracts/zappers/ERC4626UnderlyingZapper.sol";

import {KYCCompressor} from "../contracts/compressors/KYCCompressor.sol";
import {
    OnDemandKYCUnderlyingSubcompressor
} from "../contracts/compressors/subcompressors/kyc/OnDemandKYCUnderlyingSubcompressor.sol";
import {
    SecuritizeKYCFactorySubcompressor
} from "../contracts/compressors/subcompressors/kyc/SecuritizeKYCFactorySubcompressor.sol";

import {DefaultKYCUnderlying} from "../contracts/kyc/DefaultKYCUnderlying.sol";
import {MonopolizedOnDemandLP} from "../contracts/kyc/MonopolizedOnDemandLP.sol";
import {OnDemandKYCUnderlying} from "../contracts/kyc/OnDemandKYCUnderlying.sol";
import {SecuritizeDegenNFT} from "../contracts/kyc/SecuritizeDegenNFT.sol";
import {SecuritizeKYCFactory} from "../contracts/kyc/SecuritizeKYCFactory.sol";

import {
    DOMAIN_KYC_FACTORY,
    DOMAIN_KYC_UNDERLYING,
    DOMAIN_ON_DEMAND_LP,
    TYPE_KYC_COMPRESSOR
} from "../contracts/libraries/AddressValidation.sol";

import {MockDSToken} from "../contracts/test/attach/securitize/mocks/MockDSToken.sol";
import {MockVaultRegistrar} from "../contracts/test/attach/securitize/mocks/MockVaultRegistrar.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDC_DONOR = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
address constant USDC_PRICE_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

contract DeploySecuritizeContracts is AttachScriptBase {
    address public kycCompressor;
    address public kycFactory;
    address public degenNFT;
    address public cUSDC;

    MockDSToken public dsToken;
    MockVaultRegistrar public registrar;

    address public pool;
    address public creditManager;

    function setUp() public {
        vm.skip(ADDRESS_PROVIDER.code.length == 0, "Not in an attach mode");
        vm.skip(block.chainid != 1, "Not Ethereum mainnet");

        uint256 authorPrivateKey = vm.envOr("AUTHOR_PRIVATE_KEY", uint256(0));
        require(authorPrivateKey != 0, "AUTHOR_PRIVATE_KEY is not set");
        deployer = author = auditor = riskCurator = vm.createWallet(authorPrivateKey);
    }

    function run() external {
        _setUp();

        _addPublicDomain(DOMAIN_KYC_FACTORY);
        _addPublicDomain(DOMAIN_KYC_UNDERLYING);
        _addPublicDomain(DOMAIN_ON_DEMAND_LP);

        _uploadContract("DEGEN_NFT::SECURITIZE", 3_10, type(SecuritizeDegenNFT).creationCode);
        _uploadContract("KYC_FACTORY::SECURITIZE", 3_10, type(SecuritizeKYCFactory).creationCode);
        _uploadContract("KYC_UNDERLYING::DEFAULT", 3_10, type(DefaultKYCUnderlying).creationCode);
        _uploadContract("KYC_UNDERLYING::ON_DEMAND", 3_10, type(OnDemandKYCUnderlying).creationCode);
        _uploadContract("ON_DEMAND_LP::MONOPOLIZED", 3_10, type(MonopolizedOnDemandLP).creationCode);
        _uploadContract("ZAPPER::ERC4626_UNDERLYING", 3_10, type(ERC4626UnderlyingZapper).creationCode);

        // Contract deployment --------------------------------------------------------------------------------------- //

        _startOmniPrank(deployer);
        dsToken = new MockDSToken(author.addr);
        registrar = new MockVaultRegistrar(author.addr, address(dsToken));
        kycCompressor = address(new KYCCompressor(addressProvider));
        address onDemandKYCUnderlyingSubcompressor = address(new OnDemandKYCUnderlyingSubcompressor());
        address securitizeKYCFactorySubcompressor = address(new SecuritizeKYCFactorySubcompressor());
        _stopOmniPrank();

        _setGlobalAddress(TYPE_KYC_COMPRESSOR, kycCompressor, true);

        kycFactory = _deploy("KYC_FACTORY::SECURITIZE", 3_10, abi.encode(address(addressProvider), author.addr));
        cUSDC =
            _deploy("KYC_UNDERLYING::DEFAULT", 3_10, abi.encode(addressProvider, kycFactory, USDC, "compliant ", "c"));
        degenNFT = SecuritizeKYCFactory(kycFactory).getDegenNFT();

        _startOmniPrank(author);
        dsToken.registerInvestor("Fake investor", "Fake investor");
        dsToken.addWallet(author.addr, "Fake investor");
        dsToken.setRegistrar(address(registrar), true);
        dsToken.issueTokens(author.addr, 1000000 ether);
        registrar.addOperator(degenNFT);
        _stopOmniPrank();

        // Instance owner actions ------------------------------------------------------------------------------------ //

        _addPriceFeed(onePriceFeed, 0, "$1 price feed");
        _allowPriceFeed(USDC, USDC_PRICE_FEED);
        _allowPriceFeed(cUSDC, USDC_PRICE_FEED);
        _allowPriceFeed(address(dsToken), onePriceFeed);

        _configureLocal(degenNFT, abi.encodeCall(SecuritizeDegenNFT.addRegistrar, (address(registrar))));
        _configureLocal(
            kycCompressor, abi.encodeCall(KYCCompressor.setSubcompressor, (onDemandKYCUnderlyingSubcompressor))
        );
        _configureLocal(
            kycCompressor, abi.encodeCall(KYCCompressor.setSubcompressor, (securitizeKYCFactorySubcompressor))
        );

        // Risk curator actions -------------------------------------------------------------------------------------- //

        // NOTE: adding degen NFT as periphery contract is required to use it in the credit suite
        _addPeripheryContract(degenNFT);

        // NOTE: mint small amount of underlying to risk curator to mint dead pool shares
        _omniPrank(USDC_DONOR);
        ERC20(USDC).transfer(author.addr, 1e5);

        _startOmniPrank(riskCurator);
        ERC20(USDC).approve(cUSDC, 1e5);
        ERC4626(cUSDC).deposit(1e5, address(marketConfigurator));
        _stopOmniPrank();

        MarketParams memory marketParams = _getDefaultMarketParams(cUSDC);
        marketParams.underlyingPriceFeed = USDC_PRICE_FEED;
        pool = _createMockMarket(cUSDC, marketParams);
        _addToken(
            pool,
            TokenParams({
                token: USDC,
                priceFeed: USDC_PRICE_FEED,
                reservePriceFeed: USDC_PRICE_FEED,
                quotaLimit: 10_000_000e6,
                quotaRate: 1
            })
        );
        _addToken(
            pool,
            TokenParams({
                token: address(dsToken),
                priceFeed: onePriceFeed,
                reservePriceFeed: onePriceFeed,
                quotaLimit: 10_000_000e6,
                quotaRate: 1
            })
        );
        // NOTE: updating rates also adds new tokens to the quota keeper
        _updateQuotaRates(pool);

        address zapper = _deploy("ZAPPER::ERC4626_UNDERLYING", 3_10, abi.encode(pool));

        _addPeripheryContract(zapper);

        CreditSuiteParams memory creditSuiteParams = _getDefaultCreditSuiteParams();
        creditSuiteParams.debtLimit = 1_000_000e6;
        creditSuiteParams.minDebt = 50_000e6;
        creditSuiteParams.maxDebt = 1_000_000e6;
        creditSuiteParams.degenNFT = degenNFT;
        creditManager = _createMockCreditSuite(pool, creditSuiteParams);

        _addCollateralToken(creditManager, USDC, 98_00);
        _addCollateralToken(creditManager, address(dsToken), 90_00);
        _allowAdapter(creditManager, "ERC4626_VAULT", abi.encode(creditManager, cUSDC, address(0)));

        vm.serializeAddress("Addresses", "marketConfigurator", address(marketConfigurator));
        string memory finalJson = vm.serializeAddress("Addresses", "kycFactory", kycFactory);
        vm.writeJson(finalJson, "kyc-addresses.json");
    }
}

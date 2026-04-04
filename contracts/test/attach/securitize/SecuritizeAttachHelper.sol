// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {VmSafe} from "forge-std/Vm.sol";
import {AttachBase} from "@gearbox-protocol/permissionless/contracts/test/suite/AttachBase.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ERC4626UnderlyingZapper} from "@gearbox-protocol/integrations-v3/contracts/zappers/ERC4626UnderlyingZapper.sol";

import {ISecuritizeDegenNFT} from "../../../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "../../../interfaces/ISecuritizeKYCFactory.sol";
import {IDSRegistryService} from "../../../interfaces/external/securitize/IDSRegistryService.sol";
import {IDSServiceConsumer} from "../../../interfaces/external/securitize/IDSServiceConsumer.sol";
import {IDSTrustService} from "../../../interfaces/external/securitize/IDSTrustService.sol";
import {IVaultRegistrar} from "../../../interfaces/external/securitize/IVaultRegistrar.sol";

import {DefaultKYCUnderlying} from "../../../kyc/DefaultKYCUnderlying.sol";
import {MonopolizedOnDemandLP} from "../../../kyc/MonopolizedOnDemandLP.sol";
import {OnDemandKYCUnderlying} from "../../../kyc/OnDemandKYCUnderlying.sol";
import {SecuritizeDegenNFT} from "../../../kyc/SecuritizeDegenNFT.sol";
import {SecuritizeKYCFactory} from "../../../kyc/SecuritizeKYCFactory.sol";

import {MockDSToken} from "./mocks/MockDSToken.sol";
import {MockVaultRegistrar} from "./mocks/MockVaultRegistrar.sol";

contract SecuritizeAttachHelper is AttachBase {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDC_DONOR = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address public constant USDC_PRICE_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    function _setUpBytecode() internal {
        _addPublicDomain("KYC_FACTORY");
        _addPublicDomain("KYC_UNDERLYING");
        _addPublicDomain("ON_DEMAND_LP");

        _uploadContract("DEGEN_NFT::SECURITIZE", 3_10, type(SecuritizeDegenNFT).creationCode);
        _uploadContract("KYC_FACTORY::SECURITIZE", 3_10, type(SecuritizeKYCFactory).creationCode);
        _uploadContract("KYC_UNDERLYING::DEFAULT", 3_10, type(DefaultKYCUnderlying).creationCode);
        _uploadContract("KYC_UNDERLYING::ON_DEMAND", 3_10, type(OnDemandKYCUnderlying).creationCode);
        _uploadContract("ON_DEMAND_LP::MONOPOLIZED", 3_10, type(MonopolizedOnDemandLP).creationCode);
        _uploadContract("ZAPPER::ERC4626_UNDERLYING", 3_10, type(ERC4626UnderlyingZapper).creationCode);
    }

    // ---------- //
    // SECURITIZE //
    // ---------- //

    address public securitize;
    address public factory;
    address public degenNFT;
    address public dsToken;
    address public registrar;

    function _attachSecuritize(address investor) internal {
        factory = _deploy("KYC_FACTORY::SECURITIZE", 3_10, abi.encode(addressProvider, securitize));
        degenNFT = ISecuritizeKYCFactory(factory).getDegenNFT();

        registrar = vm.envOr("VAULT_REGISTRAR", address(0));
        if (registrar != address(0)) {
            _attachWithLiveRegistrar(investor);
        } else {
            dsToken = vm.envOr("DS_TOKEN", address(0));
            if (dsToken != address(0)) {
                _attachWithMockRegistrar(investor);
            } else {
                _attachWithMockDSToken(investor);
            }
        }
    }

    function _attachWithMockDSToken(address investor) internal {
        _startOmniPrank(deployer);
        dsToken = address(new MockDSToken(securitize));
        registrar = address(new MockVaultRegistrar(securitize, dsToken));
        _stopOmniPrank();

        _startOmniPrank(securitize);
        MockDSToken(dsToken).registerInvestor("Fake investor", "Fake investor");
        MockDSToken(dsToken).addWallet(investor, "Fake investor");
        MockDSToken(dsToken).setRegistrar(registrar, true);
        IVaultRegistrar(registrar).addOperator(degenNFT);
        _stopOmniPrank();
    }

    function _attachWithMockRegistrar(address investor) internal {
        _omniPrank(deployer);
        registrar = address(new MockVaultRegistrar(securitize, dsToken));
        address registryService =
            IDSServiceConsumer(dsToken).getDSService(IDSServiceConsumer(dsToken).REGISTRY_SERVICE());
        address trustService = IDSServiceConsumer(dsToken).getDSService(IDSServiceConsumer(dsToken).TRUST_SERVICE());

        address master = address(uint160(uint256(vm.load(trustService, bytes32(0)))));
        _omniPrank(master);
        IDSTrustService(trustService).setServiceOwner(securitize);

        _startOmniPrank(securitize);
        IDSTrustService(trustService).setRole(registrar, IDSTrustService(trustService).TRANSFER_AGENT());
        IDSRegistryService(registryService).registerInvestor("Fake investor", "Fake collision hash");
        IDSRegistryService(registryService).addWallet(investor, "Fake investor");
        IVaultRegistrar(registrar).addOperator(degenNFT);
        _stopOmniPrank();
    }

    function _attachWithLiveRegistrar(address investor) internal {
        dsToken = IVaultRegistrar(registrar).token();
        address registryService =
            IDSServiceConsumer(dsToken).getDSService(IDSServiceConsumer(dsToken).REGISTRY_SERVICE());
        address trustService = IDSServiceConsumer(dsToken).getDSService(IDSServiceConsumer(dsToken).TRUST_SERVICE());

        address master = address(uint160(uint256(vm.load(trustService, bytes32(0)))));
        _omniPrank(master);
        IDSTrustService(trustService).setServiceOwner(securitize);

        _startOmniPrank(securitize);
        IDSTrustService(trustService).setRole(registrar, IDSTrustService(trustService).TRANSFER_AGENT());
        IDSRegistryService(registryService).registerInvestor("Fake investor", "Fake collision hash");
        IDSRegistryService(registryService).addWallet(investor, "Fake investor");
        IVaultRegistrar(registrar).addOperator(degenNFT);
        _stopOmniPrank();
    }

    function _signRegisterVaultMessage(VmSafe.Wallet memory investor)
        internal
        view
        returns (ISecuritizeDegenNFT.RegisterMessage memory message)
    {
        bytes32 domainSeparator = _buildDomainSeparator(registrar);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "RegisterVault(address investor,address operator,address token,uint256 nonce,uint256 deadline)"
                ),
                investor.addr,
                degenNFT,
                dsToken,
                IVaultRegistrar(registrar).operatorNonce(investor.addr, degenNFT),
                type(uint256).max
            )
        );
        return ISecuritizeDegenNFT.RegisterMessage({
            token: dsToken,
            signature: ISecuritizeDegenNFT.Signature({
                deadline: type(uint256).max, signature: _sign(investor, domainSeparator, structHash)
            })
        });
    }

    // ------- //
    // MARKETS //
    // ------- //

    function _createMarketWithDefaultKYCUnderlying()
        internal
        returns (address underlying, address pool, address creditManager, address zapper)
    {
        underlying = _deploy(
            "KYC_UNDERLYING::DEFAULT", 3_10, abi.encode(addressProvider, factory, USDC, "Default compliant ", "dc")
        );
        _allowPriceFeed(underlying, USDC_PRICE_FEED);

        // NOTE: sending small amount of underlying to market configurator to mint dead pool shares
        _startOmniPrank(riskCurator);
        ERC20(USDC).approve(underlying, 1e5);
        ERC4626(underlying).deposit(1e5, address(marketConfigurator));
        _stopOmniPrank();

        MarketParams memory marketParams = _getDefaultMarketParams(underlying);
        marketParams.underlyingPriceFeed = USDC_PRICE_FEED;
        marketParams.interestRateModelParams.salt = "GEARBOX_DEFAULT";
        pool = _createMockMarket(underlying, marketParams);
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

        zapper = _deploy("ZAPPER::ERC4626_UNDERLYING", 3_10, abi.encode(pool));
        _addPeripheryContract(zapper);

        CreditSuiteParams memory creditSuiteParams = _getDefaultCreditSuiteParams();
        creditSuiteParams.debtLimit = 1_000_000e6;
        creditSuiteParams.minDebt = 50_000e6;
        creditSuiteParams.maxDebt = 1_000_000e6;
        creditSuiteParams.degenNFT = degenNFT;
        creditManager = _createMockCreditSuite(pool, creditSuiteParams);

        _addCollateralToken(creditManager, USDC, 98_00);
        _addCollateralToken(creditManager, address(dsToken), 90_00);
        _allowAdapter(creditManager, "ERC4626_VAULT", abi.encode(creditManager, underlying, address(0)));
    }

    function _createMarketWithOnDemandKYCUnderlying(address depositor)
        internal
        returns (address underlying, address pool, address creditManager, address liquidityProvider)
    {
        liquidityProvider = _deploy(
            "ON_DEMAND_LP::MONOPOLIZED", 3_10, abi.encode(addressProvider, marketConfigurator, depositor)
        );
        underlying = _deploy(
            "KYC_UNDERLYING::ON_DEMAND",
            3_10,
            abi.encode(
                addressProvider, factory, liquidityProvider, marketConfigurator, USDC, "On-demand compliant ", "oc"
            )
        );
        _allowPriceFeed(underlying, USDC_PRICE_FEED);

        // NOTE: sending small amount of underlying to market configurator to mint dead pool shares
        _startOmniPrank(riskCurator);
        ERC20(USDC).approve(underlying, 1e5);
        ERC4626(underlying).deposit(1e5, address(marketConfigurator));
        _stopOmniPrank();

        MarketParams memory marketParams = _getDefaultMarketParams(underlying);
        marketParams.underlyingPriceFeed = USDC_PRICE_FEED;
        marketParams.interestRateModelParams.salt = keccak256(abi.encode(underlying));
        pool = _createMockMarket(underlying, marketParams);
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
                token: dsToken,
                priceFeed: onePriceFeed,
                reservePriceFeed: onePriceFeed,
                quotaLimit: 10_000_000e6,
                quotaRate: 1
            })
        );
        // NOTE: updating rates also adds new tokens to the quota keeper
        _updateQuotaRates(pool);

        _startOmniPrank(riskCurator);
        OnDemandKYCUnderlying(underlying).setPool(pool);
        MonopolizedOnDemandLP(liquidityProvider).addPool(pool);
        _stopOmniPrank();

        CreditSuiteParams memory creditSuiteParams = _getDefaultCreditSuiteParams();
        creditSuiteParams.debtLimit = 1_000_000e6;
        creditSuiteParams.minDebt = 50_000e6;
        creditSuiteParams.maxDebt = 1_000_000e6;
        creditSuiteParams.degenNFT = degenNFT;
        creditSuiteParams.accountFactoryParams.salt = keccak256(abi.encode(underlying));
        creditManager = _createMockCreditSuite(pool, creditSuiteParams);

        _addCollateralToken(creditManager, USDC, 98_00);
        _addCollateralToken(creditManager, dsToken, 90_00);
        _allowAdapter(creditManager, "ERC4626_VAULT", abi.encode(creditManager, underlying, address(0)));
    }
}

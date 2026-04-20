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

    uint256 public idx;
    modifier repeatTestForEachDSToken() {
        for (idx; idx < dsTokens.length; ++idx) {
            uint256 snapshot = vm.snapshotState();
            _;
            vm.revertToStateAndDelete(snapshot);
        }
    }

    // ---------- //
    // SECURITIZE //
    // ---------- //

    address public securitize;
    address public factory;
    address public degenNFT;

    struct DSToken {
        address token;
        address registrar;
    }

    DSToken[] public dsTokens;

    function _attachSecuritize(address investor) internal {
        factory = _deploy("KYC_FACTORY::SECURITIZE", 3_10, abi.encode(addressProvider, securitize));
        degenNFT = ISecuritizeKYCFactory(factory).getDegenNFT();

        address[] memory registrars = vm.envOr("VAULT_REGISTRAR", ",", new address[](0));
        if (registrars.length != 0) {
            for (uint256 i; i < registrars.length; ++i) {
                address dsToken = _attachWithLiveRegistrar(investor, registrars[i]);
                dsTokens.push(DSToken(dsToken, registrars[i]));
            }
        } else {
            address[] memory tokens = vm.envOr("DS_TOKEN", ",", new address[](0));
            if (tokens.length != 0) {
                for (uint256 i; i < tokens.length; ++i) {
                    address registrar = _attachWithMockRegistrar(investor, tokens[i]);
                    dsTokens.push(DSToken(tokens[i], registrar));
                }
            } else {
                (address dsToken, address registrar) = _attachWithMockDSToken(investor);
                dsTokens.push(DSToken(dsToken, registrar));
            }
        }
    }

    function _attachWithMockDSToken(address investor) internal returns (address dsToken, address registrar) {
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

    function _attachWithMockRegistrar(address investor, address dsToken) internal returns (address registrar) {
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

    function _attachWithLiveRegistrar(address investor, address registrar) internal returns (address dsToken) {
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

    function _signRegisterVaultMessage(VmSafe.Wallet memory investor, DSToken memory dsToken)
        internal
        view
        returns (ISecuritizeDegenNFT.RegisterMessage memory message)
    {
        bytes32 domainSeparator = _buildDomainSeparator(dsToken.registrar);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "RegisterVault(address investor,address operator,address token,uint256 nonce,uint256 deadline)"
                ),
                investor.addr,
                degenNFT,
                dsToken.token,
                IVaultRegistrar(dsToken.registrar).operatorNonce(investor.addr, degenNFT),
                type(uint256).max
            )
        );
        return ISecuritizeDegenNFT.RegisterMessage({
            token: dsToken.token,
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
        returns (address underlying, address pool, address[] memory creditManagers, address zapper)
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
        for (uint256 i; i < dsTokens.length; ++i) {
            _addToken(
                pool,
                TokenParams({
                    token: dsTokens[i].token,
                    priceFeed: onePriceFeed,
                    reservePriceFeed: onePriceFeed,
                    quotaLimit: 10_000_000e6,
                    quotaRate: 1
                })
            );
        }
        // NOTE: updating rates also adds new tokens to the quota keeper
        _updateQuotaRates(pool);

        zapper = _deploy("ZAPPER::ERC4626_UNDERLYING", 3_10, abi.encode(pool));
        _addPeripheryContract(zapper);

        creditManagers = new address[](dsTokens.length);
        for (uint256 i; i < dsTokens.length; ++i) {
            CreditSuiteParams memory creditSuiteParams = _getDefaultCreditSuiteParams();
            creditSuiteParams.debtLimit = 1_000_000e6;
            creditSuiteParams.minDebt = 50_000e6;
            creditSuiteParams.maxDebt = 1_000_000e6;
            creditSuiteParams.degenNFT = degenNFT;
            creditSuiteParams.accountFactoryParams.salt = keccak256(abi.encode(underlying, dsTokens[i].token));
            creditManagers[i] = _createMockCreditSuite(pool, creditSuiteParams);

            _addCollateralToken(creditManagers[i], USDC, 98_00);
            _addCollateralToken(creditManagers[i], dsTokens[i].token, 90_00);
            _allowAdapter(creditManagers[i], "ERC4626_VAULT", abi.encode(creditManagers[i], underlying, address(0)));
        }
    }

    function _createMarketWithOnDemandKYCUnderlying(address depositor)
        internal
        returns (address underlying, address pool, address[] memory creditManagers, address liquidityProvider)
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
        for (uint256 i; i < dsTokens.length; ++i) {
            _addToken(
                pool,
                TokenParams({
                    token: dsTokens[i].token,
                    priceFeed: onePriceFeed,
                    reservePriceFeed: onePriceFeed,
                    quotaLimit: 10_000_000e6,
                    quotaRate: 1
                })
            );
        }
        // NOTE: updating rates also adds new tokens to the quota keeper
        _updateQuotaRates(pool);

        _startOmniPrank(riskCurator);
        OnDemandKYCUnderlying(underlying).setPool(pool);
        MonopolizedOnDemandLP(liquidityProvider).addPool(pool);
        OnDemandKYCUnderlying(underlying).setDepositorStatus(treasury, true);
        _stopOmniPrank();

        creditManagers = new address[](dsTokens.length);
        for (uint256 i; i < dsTokens.length; ++i) {
            CreditSuiteParams memory creditSuiteParams = _getDefaultCreditSuiteParams();
            creditSuiteParams.debtLimit = 1_000_000e6;
            creditSuiteParams.minDebt = 50_000e6;
            creditSuiteParams.maxDebt = 1_000_000e6;
            creditSuiteParams.degenNFT = degenNFT;
            creditSuiteParams.accountFactoryParams.salt = keccak256(abi.encode(underlying, dsTokens[i].token));
            creditManagers[i] = _createMockCreditSuite(pool, creditSuiteParams);

            _addCollateralToken(creditManagers[i], USDC, 98_00);
            _addCollateralToken(creditManagers[i], dsTokens[i].token, 90_00);
            _allowAdapter(creditManagers[i], "ERC4626_VAULT", abi.encode(creditManagers[i], underlying, address(0)));
        }
    }
}

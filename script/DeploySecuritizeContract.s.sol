// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {AnvilHelper} from "./AnvilHelper.sol";
import {AttachBase} from "@gearbox-protocol/permissionless/contracts/test/suite/AttachBase.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {BytecodeRepository} from "@gearbox-protocol/permissionless/contracts/global/BytecodeRepository.sol";
import {Bytecode, AuditReport} from "@gearbox-protocol/permissionless/contracts/interfaces/Types.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {DeployParams} from "@gearbox-protocol/permissionless/contracts/interfaces/Types.sol";
import {
    CreditManagerParams,
    CreditFacadeParams,
    ICreditConfigureActions
} from "@gearbox-protocol/permissionless/contracts/interfaces/factories/ICreditConfigureActions.sol";
import {ITumblerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ITumblerV3.sol";
import {
    IPoolConfigureActions
} from "@gearbox-protocol/permissionless/contracts/interfaces/factories/IPoolConfigureActions.sol";
import {
    IPriceOracleConfigureActions
} from "@gearbox-protocol/permissionless/contracts/interfaces/factories/IPriceOracleConfigureActions.sol";

import {SecuritizeKYCFactory} from "../contracts/kyc/SecuritizeKYCFactory.sol";
import {DefaultKYCUnderlying} from "../contracts/kyc/DefaultKYCUnderlying.sol";
import {SecuritizeDegenNFT} from "../contracts/kyc/SecuritizeDegenNFT.sol";
import {ERC4626UnderlyingZapper} from "@gearbox-protocol/integrations-v3/contracts/zappers/ERC4626UnderlyingZapper.sol";
import {BytecodeRepositoryMock} from "./BytecodeRepositoryMock.sol";
import {MockDSToken} from "../contracts/test/attach/securitize/mocks/MockDSToken.sol";
import {MockVaultRegistrar} from "../contracts/test/attach/securitize/mocks/MockVaultRegistrar.sol";

import {KYCCompressor} from "../contracts/compressors/KYCCompressor.sol";
import {
    OnDemandKYCUnderlyingSubcompressor
} from "../contracts/compressors/subcompressors/kyc/OnDemandKYCUnderlyingSubcompressor.sol";
import {
    SecuritizeKYCFactorySubcompressor
} from "../contracts/compressors/subcompressors/kyc/SecuritizeKYCFactorySubcompressor.sol";

import {
    DOMAIN_KYC_FACTORY,
    DOMAIN_KYC_UNDERLYING,
    DOMAIN_ON_DEMAND_LP,
    TYPE_KYC_COMPRESSOR
} from "../contracts/libraries/AddressValidation.sol";

address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDC_DONOR = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

address constant AUDITOR = 0x9A4Ff94eC9400698cD7fbe28b1Dc0d347a05310d;

struct MarketParams {
    string name;
    string symbol;
    DeployParams interestRateModelParams;
    DeployParams rateKeeperParams;
    DeployParams lossPolicyParams;
    address underlyingPriceFeed;
}

struct CreditSuiteParams {
    uint128 minDebt;
    uint128 maxDebt;
    uint256 debtLimit;
    uint8 maxEnabledTokens;
    uint16 feeInterest;
    uint16 feeLiquidation;
    uint16 liquidationPremium;
    uint16 feeLiquidationExpired;
    uint16 liquidationPremiumExpired;
    address degenNFT;
    bool expirable;
    bool migrateBotList;
    DeployParams accountFactoryParams;
}

contract DeploySecuritizeContracts is AttachBase, AnvilHelper {
    VmSafe.Wallet public author;

    address public kycCompressor;
    address public kycFactory;
    address public kycUnderlying;
    address public degenNFT;

    MockDSToken public dsToken;
    MockVaultRegistrar public registrar;
    address public onePriceFeed;

    address public marketConfigurator;
    address public pool;
    address public creditManager;

    function setUp() public virtual {
        _attachCore();

        bytes32 authorPrivateKey = vm.envOr("AUTHOR_PRIVATE_KEY", bytes32(0));

        if (authorPrivateKey == bytes32(0)) {
            revert("AUTHOR_PRIVATE_KEY is not set");
        }

        author = vm.createWallet(uint256(authorPrivateKey));

        _setBalance(instanceOwner, 100 ether);
        _setBalance(crossChainGovernance, 100 ether);
        _setBalance(USDC_DONOR, 100 ether);
    }

    function _mockBytecodeRepositoryBytecode() internal {
        address bcrOwner = bytecodeRepository.owner();
        address bytecodeRepositoryMock = address(new BytecodeRepositoryMock(bcrOwner));
        _replaceBytecode(address(bytecodeRepository), bytecodeRepositoryMock.code);
    }

    function _getContractsBytecodes() internal pure returns (Bytecode[] memory bytecodes) {
        bytecodes = new Bytecode[](4);
        bytecodes[0].contractType = "KYC_FACTORY::SECURITIZE";
        bytecodes[0].version = 3_10;
        bytecodes[0].initCode = type(SecuritizeKYCFactory).creationCode;
        bytecodes[0].source =
            "https://github.com/Gearbox-protocol/periphery-v3/tree/securitize-integration/contracts/kyc/SecuritizeKYCFactory.sol";
        bytecodes[1].contractType = "KYC_UNDERLYING::DEFAULT";
        bytecodes[1].version = 3_10;
        bytecodes[1].initCode = type(DefaultKYCUnderlying).creationCode;
        bytecodes[1].source =
            "https://github.com/Gearbox-protocol/periphery-v3/tree/securitize-integration/contracts/kyc/DefaultKYCUnderlying.sol";
        bytecodes[2].contractType = "DEGEN_NFT::SECURITIZE";
        bytecodes[2].version = 3_10;
        bytecodes[2].initCode = type(SecuritizeDegenNFT).creationCode;
        bytecodes[2].source =
            "https://github.com/Gearbox-protocol/periphery-v3/tree/securitize-integration/contracts/kyc/SecuritizeDegenNFT.sol";
        bytecodes[3].contractType = "ZAPPER::ERC4626_UNDERLYING";
        bytecodes[3].version = 3_10;
        bytecodes[3].initCode = type(ERC4626UnderlyingZapper).creationCode;
        bytecodes[3].source =
            "https://github.com/Gearbox-protocol/integrations-v3/tree/erc-4626-underlying-zapper/contracts/zappers/ERC4626UnderlyingZapper.sol";
    }

    function _createMockMarketConfigurator() internal {
        marketConfigurator = marketConfiguratorFactory.createMarketConfigurator({
            emergencyAdmin: address(0),
            adminFeeTreasury: address(0),
            curatorName: "Compliant Curator",
            deployGovernor: false
        });

        IMarketConfigurator(marketConfigurator).addPeripheryContract(degenNFT);
    }

    function _getDefaultMarketParams(address underlying) internal view returns (MarketParams memory params) {
        string memory name = string.concat("Diesel ", ERC20(underlying).name());
        string memory symbol = string.concat("d", ERC20(underlying).symbol());
        address poolAddr = IMarketConfigurator(marketConfigurator)
            .previewCreateMarket({minorVersion: 3_10, underlying: underlying, name: name, symbol: symbol});
        return MarketParams({
            name: name,
            symbol: symbol,
            interestRateModelParams: DeployParams({
                postfix: "LINEAR", salt: "GEARBOX", constructorParams: abi.encode(5000, 9000, 10_00, 0, 0, 0, false)
            }),
            rateKeeperParams: DeployParams({
                postfix: "TUMBLER", salt: "GEARBOX", constructorParams: abi.encode(poolAddr, 0)
            }),
            lossPolicyParams: DeployParams({
                postfix: "ALIASED", salt: "GEARBOX", constructorParams: abi.encode(poolAddr, ADDRESS_PROVIDER)
            }),
            underlyingPriceFeed: onePriceFeed
        });
    }

    function _addToken(address token) internal {
        IMarketConfigurator(marketConfigurator).addToken({pool: pool, token: token, priceFeed: onePriceFeed});
        IMarketConfigurator(marketConfigurator)
            .configurePriceOracle(
                pool, abi.encodeCall(IPriceOracleConfigureActions.setReservePriceFeed, (token, onePriceFeed))
            );
        IMarketConfigurator(marketConfigurator)
            .configurePool(pool, abi.encodeCall(IPoolConfigureActions.setTokenLimit, (token, 10_000_000e6)));
        IMarketConfigurator(marketConfigurator)
            .configureRateKeeper(pool, abi.encodeCall(ITumblerV3.setRate, (token, 1)));
    }

    function _createMockMarket() internal {
        MarketParams memory params = _getDefaultMarketParams(kycUnderlying);
        ERC20(USDC).approve(kycUnderlying, 1e5);
        DefaultKYCUnderlying(kycUnderlying).deposit(1e5, author.addr);
        ERC20(kycUnderlying).transfer(address(marketConfigurator), 1e5);

        pool = IMarketConfigurator(marketConfigurator)
            .createMarket({
                minorVersion: 3_10,
                underlying: kycUnderlying,
                name: params.name,
                symbol: params.symbol,
                interestRateModelParams: params.interestRateModelParams,
                rateKeeperParams: params.rateKeeperParams,
                lossPolicyParams: params.lossPolicyParams,
                underlyingPriceFeed: params.underlyingPriceFeed
            });

        _addToken(USDC);
        _addToken(address(dsToken));
        IMarketConfigurator(marketConfigurator).configureRateKeeper(pool, abi.encodeCall(ITumblerV3.updateRates, ()));

        address zapper = bytecodeRepository.deploy("ZAPPER::ERC4626_UNDERLYING", 3_10, abi.encode(pool), bytes32(0));
        IMarketConfigurator(marketConfigurator).addPeripheryContract(zapper);
    }

    function _getDefaultCreditSuiteParams() internal view returns (CreditSuiteParams memory) {
        return CreditSuiteParams({
            minDebt: 50_000 * 1e6,
            maxDebt: 1_000_000 * 1e6,
            debtLimit: 10_000_000 * 1e6,
            maxEnabledTokens: 2,
            feeInterest: 50_00,
            feeLiquidation: 1_00,
            liquidationPremium: 1_00,
            feeLiquidationExpired: 1_00,
            liquidationPremiumExpired: 1_00,
            degenNFT: degenNFT,
            expirable: false,
            migrateBotList: false,
            accountFactoryParams: DeployParams({
                postfix: "DEFAULT", salt: "GEARBOX", constructorParams: abi.encode(ADDRESS_PROVIDER)
            })
        });
    }

    function _createMockCreditSuite() internal {
        CreditSuiteParams memory params = _getDefaultCreditSuiteParams();
        CreditManagerParams memory cmParams = CreditManagerParams({
            maxEnabledTokens: params.maxEnabledTokens,
            feeInterest: params.feeInterest,
            feeLiquidation: params.feeLiquidation,
            liquidationPremium: params.liquidationPremium,
            feeLiquidationExpired: params.feeLiquidationExpired,
            liquidationPremiumExpired: params.liquidationPremiumExpired,
            minDebt: params.minDebt,
            maxDebt: params.maxDebt,
            name: string.concat("Compliant ", ERC20(ERC4626(pool).asset()).symbol(), " Credit Suite"),
            accountFactoryParams: params.accountFactoryParams
        });

        CreditFacadeParams memory cfParams = CreditFacadeParams({
            degenNFT: params.degenNFT, expirable: params.expirable, migrateBotList: params.migrateBotList
        });

        creditManager = IMarketConfigurator(marketConfigurator)
            .createCreditSuite({minorVersion: 3_10, pool: pool, encdodedParams: abi.encode(cmParams, cfParams)});

        IMarketConfigurator(marketConfigurator)
            .configurePool(
                pool, abi.encodeCall(IPoolConfigureActions.setCreditManagerDebtLimit, (creditManager, params.debtLimit))
            );
        IMarketConfigurator(marketConfigurator)
            .configureCreditSuite(
                creditManager, abi.encodeCall(ICreditConfigureActions.addCollateralToken, (USDC, 98_00))
            );
        IMarketConfigurator(marketConfigurator)
            .configureCreditSuite(
                creditManager, abi.encodeCall(ICreditConfigureActions.addCollateralToken, (address(dsToken), 90_00))
            );
        IMarketConfigurator(marketConfigurator)
            .configureCreditSuite(
                creditManager,
                abi.encodeCall(
                    ICreditConfigureActions.allowAdapter,
                    (DeployParams({
                            postfix: "ERC4626_VAULT",
                            salt: "GEARBOX",
                            constructorParams: abi.encode(creditManager, kycUnderlying, address(0))
                        }))
                )
            );
    }

    function run() external {
        _autoImpersonate(true);
        _mockBytecodeRepositoryBytecode();

        vm.startBroadcast(crossChainGovernance);
        kycCompressor = address(new KYCCompressor(addressProvider));
        instanceManager.setGlobalAddress(TYPE_KYC_COMPRESSOR, kycCompressor, true);
        instanceManager.configureGlobal(
            address(bytecodeRepository), abi.encodeCall(BytecodeRepository.addPublicDomain, (DOMAIN_KYC_FACTORY))
        );
        instanceManager.configureGlobal(
            address(bytecodeRepository), abi.encodeCall(BytecodeRepository.addPublicDomain, (DOMAIN_KYC_UNDERLYING))
        );
        instanceManager.configureGlobal(
            address(bytecodeRepository), abi.encodeCall(BytecodeRepository.addPublicDomain, (DOMAIN_ON_DEMAND_LP))
        );
        vm.stopBroadcast();

        vm.startBroadcast(author.addr);

        Bytecode[] memory bytecodes = _getContractsBytecodes();
        BytecodeRepositoryMock(address(bytecodeRepository)).exposed_addBytecode(bytecodes);

        dsToken = new MockDSToken(author.addr);
        registrar = new MockVaultRegistrar(author.addr, address(dsToken));
        onePriceFeed =
            bytecodeRepository.deploy("PRICE_FEED::CONSTANT", 3_10, abi.encode(1e8, "$1 price feed"), bytes32(0));

        bytes memory factoryConstructorParams = abi.encode(address(addressProvider), author.addr);
        kycFactory = bytecodeRepository.deploy(
            bytecodes[0].contractType, bytecodes[0].version, factoryConstructorParams, bytes32(0)
        );

        bytes memory underlyingConstructorParams = abi.encode(addressProvider, kycFactory, USDC, "compliant ", "c");

        kycUnderlying = bytecodeRepository.deploy(
            bytecodes[1].contractType, bytecodes[1].version, underlyingConstructorParams, bytes32(0)
        );

        degenNFT = SecuritizeKYCFactory(kycFactory).getDegenNFT();

        dsToken.registerInvestor("Fake investor", "Fake investor");
        dsToken.addWallet(author.addr, "Fake investor");
        dsToken.setRegistrar(address(registrar), true);
        dsToken.issueTokens(author.addr, 1000000 ether);
        registrar.addOperator(degenNFT);

        vm.stopBroadcast();

        vm.startBroadcast(instanceOwner);
        instanceManager.configureLocal(
            address(priceFeedStore), abi.encodeCall(priceFeedStore.addPriceFeed, (onePriceFeed, 0, "$1 price feed"))
        );
        instanceManager.configureLocal(
            address(priceFeedStore), abi.encodeCall(priceFeedStore.allowPriceFeed, (address(dsToken), onePriceFeed))
        );
        instanceManager.configureLocal(
            address(priceFeedStore), abi.encodeCall(priceFeedStore.allowPriceFeed, (USDC, onePriceFeed))
        );
        instanceManager.configureLocal(
            address(priceFeedStore), abi.encodeCall(priceFeedStore.allowPriceFeed, (kycUnderlying, onePriceFeed))
        );

        instanceManager.configureLocal(degenNFT, abi.encodeCall(SecuritizeDegenNFT.addRegistrar, (address(registrar))));

        instanceManager.configureLocal(
            kycCompressor,
            abi.encodeCall(KYCCompressor.setSubcompressor, (address(new OnDemandKYCUnderlyingSubcompressor())))
        );
        instanceManager.configureLocal(
            kycCompressor,
            abi.encodeCall(KYCCompressor.setSubcompressor, (address(new SecuritizeKYCFactorySubcompressor())))
        );
        vm.stopBroadcast();

        vm.startBroadcast(USDC_DONOR);
        ERC20(USDC).transfer(author.addr, 100 * 1e6);
        vm.stopBroadcast();

        vm.startBroadcast(author.addr);
        _createMockMarketConfigurator();
        _createMockMarket();
        _createMockCreditSuite();
        vm.stopBroadcast();

        vm.serializeAddress("Addresses", "kycFactory", kycFactory);
        string memory finalJson = vm.serializeAddress("Addresses", "marketConfigurator", marketConfigurator);
        vm.writeJson(finalJson, "kyc-addresses.json");
    }
}

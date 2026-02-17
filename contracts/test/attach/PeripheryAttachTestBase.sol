// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import {AttachTestBase} from "@gearbox-protocol/permissionless/contracts/test/suite/AttachTestBase.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {ITumblerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ITumblerV3.sol";

import {ConstantPriceFeed} from "@gearbox-protocol/permissionless/contracts/helpers/ConstantPriceFeed.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {
    CreditManagerParams,
    CreditFacadeParams,
    ICreditConfigureActions
} from "@gearbox-protocol/permissionless/contracts/interfaces/factories/ICreditConfigureActions.sol";
import {
    IPoolConfigureActions
} from "@gearbox-protocol/permissionless/contracts/interfaces/factories/IPoolConfigureActions.sol";
import {DeployParams} from "@gearbox-protocol/permissionless/contracts/interfaces/Types.sol";

contract PeripheryAttachTestBase is AttachTestBase {
    address zeroPriceFeed;
    address onePriceFeed;

    function _setUp() internal {
        vm.skip(ADDRESS_PROVIDER.code.length == 0, "Not in an attach mode");

        // NOTE: even though we compile our contracts under Shanghai EVM version,
        // more recent one might be needed to interact with third-party contracts
        vm.setEvmVersion("osaka");

        _attachCore();

        zeroPriceFeed = priceFeedStore.zeroPriceFeed();
        if (bytecodeRepository.getAllowedBytecodeHash("PRICE_FEED::CONSTANT", 3_10) == 0) {
            // NOTE: this would fail on deployment if we bump `ConstantPriceFeed` to v3.1.1 in the permissionless repo,
            // but we assume that in this case v3.1.0 would already be uploaded to the bytecode repository
            _uploadContract("PRICE_FEED::CONSTANT", 3_10, type(ConstantPriceFeed).creationCode);
        }
        onePriceFeed = _deploy("PRICE_FEED::CONSTANT", 3_10, abi.encode(1e8, "$1 price feed"));
        _addPriceFeed(onePriceFeed, 0, "$1 price feed");
    }

    function _configureGlobal(address target, bytes memory data) internal {
        vm.prank(crossChainGovernance);
        instanceManager.configureGlobal(target, data);
    }

    function _configureLocal(address target, bytes memory data) internal {
        vm.prank(instanceOwner);
        instanceManager.configureLocal(target, data);
    }

    function _addPeripheryContract(address peripheryContract) internal {
        vm.prank(riskCurator);
        IMarketConfigurator(marketConfigurator).addPeripheryContract(peripheryContract);
    }

    function _updateQuotaRates(address pool) internal {
        vm.prank(riskCurator);
        IMarketConfigurator(marketConfigurator).configureRateKeeper(pool, abi.encodeCall(ITumblerV3.updateRates, ()));
    }

    struct MarketParams {
        string name;
        string symbol;
        DeployParams interestRateModelParams;
        DeployParams rateKeeperParams;
        DeployParams lossPolicyParams;
        address underlyingPriceFeed;
    }

    function _getDefaultMarketParams(address underlying) internal view returns (MarketParams memory) {
        string memory name = string.concat("Mock Diesel ", ERC20(underlying).name());
        string memory symbol = string.concat("md", ERC20(underlying).symbol());
        address pool = marketConfigurator.previewCreateMarket({
            minorVersion: 3_10, underlying: underlying, name: name, symbol: symbol
        });
        return MarketParams({
            name: name,
            symbol: symbol,
            interestRateModelParams: DeployParams({
                postfix: "LINEAR", salt: "GEARBOX", constructorParams: abi.encode(5000, 9000, 10_00, 0, 0, 0, false)
            }),
            rateKeeperParams: DeployParams({
                postfix: "TUMBLER", salt: "GEARBOX", constructorParams: abi.encode(pool, 0)
            }),
            lossPolicyParams: DeployParams({
                postfix: "ALIASED", salt: "GEARBOX", constructorParams: abi.encode(pool, ADDRESS_PROVIDER)
            }),
            underlyingPriceFeed: onePriceFeed
        });
    }

    function _createMockMarket(address underlying, MarketParams memory params) internal returns (address pool) {
        vm.startPrank(riskCurator);
        ERC20(underlying).transfer(address(marketConfigurator), 1e5);

        pool = marketConfigurator.createMarket({
            minorVersion: 3_10,
            underlying: underlying,
            name: params.name,
            symbol: params.symbol,
            interestRateModelParams: params.interestRateModelParams,
            rateKeeperParams: params.rateKeeperParams,
            lossPolicyParams: params.lossPolicyParams,
            underlyingPriceFeed: params.underlyingPriceFeed
        });
        vm.stopPrank();
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

    function _getDefaultCreditSuiteParams() internal pure returns (CreditSuiteParams memory) {
        return CreditSuiteParams({
            minDebt: 0,
            maxDebt: 0,
            debtLimit: 0,
            maxEnabledTokens: 2,
            feeInterest: 50_00,
            feeLiquidation: 1_00,
            liquidationPremium: 1_00,
            feeLiquidationExpired: 1_00,
            liquidationPremiumExpired: 1_00,
            degenNFT: address(0),
            expirable: false,
            migrateBotList: false,
            accountFactoryParams: DeployParams({
                postfix: "DEFAULT", salt: "GEARBOX", constructorParams: abi.encode(ADDRESS_PROVIDER)
            })
        });
    }

    function _createMockCreditSuite(address pool, CreditSuiteParams memory params)
        internal
        returns (address creditManager)
    {
        CreditManagerParams memory cmParams = CreditManagerParams({
            maxEnabledTokens: params.maxEnabledTokens,
            feeInterest: params.feeInterest,
            feeLiquidation: params.feeLiquidation,
            liquidationPremium: params.liquidationPremium,
            feeLiquidationExpired: params.feeLiquidationExpired,
            liquidationPremiumExpired: params.liquidationPremiumExpired,
            minDebt: params.minDebt,
            maxDebt: params.maxDebt,
            name: string.concat("Mock ", ERC20(ERC4626(pool).asset()).symbol(), " Credit Suite"),
            accountFactoryParams: params.accountFactoryParams
        });

        CreditFacadeParams memory cfParams = CreditFacadeParams({
            degenNFT: params.degenNFT, expirable: params.expirable, migrateBotList: params.migrateBotList
        });

        vm.startPrank(riskCurator);
        creditManager = marketConfigurator.createCreditSuite({
            minorVersion: 3_10, pool: pool, encdodedParams: abi.encode(cmParams, cfParams)
        });

        if (params.debtLimit != 0) {
            marketConfigurator.configurePool(
                pool, abi.encodeCall(IPoolConfigureActions.setCreditManagerDebtLimit, (creditManager, params.debtLimit))
            );
        }
        vm.stopPrank();
    }
}

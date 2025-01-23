// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {CreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {BaseLib} from "../libraries/BaseLib.sol";

import {BaseParams, BaseState} from "../types/BaseState.sol";
import {CreditFacadeState} from "../types/CreditFacadeState.sol";
import {CollateralToken, CreditManagerState} from "../types/CreditManagerState.sol";
import {CreditSuiteData} from "../types/CreditSuiteData.sol";

import {AdapterCompressor} from "./AdapterCompressor.sol";

import {AP_CREDIT_SUITE_COMPRESSOR} from "../libraries/Literals.sol";

contract CreditSuiteCompressor {
    AdapterCompressor adapterCompressor;

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = AP_CREDIT_SUITE_COMPRESSOR;

    constructor() {
        adapterCompressor = new AdapterCompressor();
    }

    function getCreditSuiteData(address creditManager) public view returns (CreditSuiteData memory result) {
        result.creditManager = getCreditManagerState(creditManager);
        result.creditFacade = getCreditFacadeState(ICreditManagerV3(creditManager).creditFacade());
        result.creditConfigurator = BaseLib.getBaseState(
            ICreditManagerV3(creditManager).creditConfigurator(), "CREDIT_CONFIGURATOR", address(0)
        );

        result.adapters = adapterCompressor.getAdapters(creditManager);
    }

    /// @dev Returns CreditManagerData for a particular _cm
    /// @param _cm CreditManager address
    function getCreditManagerState(address _cm) public view returns (CreditManagerState memory result) {
        ICreditManagerV3 creditManager = ICreditManagerV3(_cm);
        ICreditConfiguratorV3 creditConfigurator = ICreditConfiguratorV3(creditManager.creditConfigurator());
        CreditFacadeV3 creditFacade = CreditFacadeV3(creditManager.creditFacade());

        result.baseParams = BaseLib.getBaseParams(_cm, "CREDIT_MANAGER", address(0));
        // string name;
        result.name = ICreditManagerV3(_cm).name();

        // address accountFactory;
        result.accountFactory = creditManager.accountFactory();
        // address underlying;
        result.underlying = creditManager.underlying();
        // address pool;
        result.pool = creditManager.pool();
        // address creditFacade;
        result.creditFacade = address(creditFacade);
        // address creditConfigurator;
        result.creditConfigurator = address(creditConfigurator);
        // uint8 maxEnabledTokens;
        result.maxEnabledTokens = creditManager.maxEnabledTokens();

        uint256 collateralTokensCount = creditManager.collateralTokensCount();
        result.collateralTokens = new CollateralToken[](collateralTokensCount);
        for (uint256 i; i < collateralTokensCount; ++i) {
            (address token, uint16 lt) = creditManager.collateralTokenByMask(1 << i);
            result.collateralTokens[i] = CollateralToken(token, lt);
        }

        (
            result.feeInterest,
            result.feeLiquidation,
            result.liquidationDiscount,
            result.feeLiquidationExpired,
            result.liquidationDiscountExpired
        ) = creditManager.fees();
    }

    /// @dev Returns CreditManagerData for a particular _cm
    /// @param _cf CreditFacade address
    function getCreditFacadeState(address _cf) public view returns (CreditFacadeState memory result) {
        CreditFacadeV3 creditFacade = CreditFacadeV3(_cf);

        result.baseParams = BaseLib.getBaseParams(_cf, "CREDIT_FACADE", address(0));
        result.expirable = creditFacade.expirable();
        result.degenNFT = creditFacade.degenNFT();
        result.expirationDate = creditFacade.expirationDate();
        result.maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        result.botList = creditFacade.botList();
        (result.minDebt, result.maxDebt) = creditFacade.debtLimits();
        result.forbiddenTokenMask = creditFacade.forbiddenTokenMask();
        result.isPaused = creditFacade.paused();
    }
}

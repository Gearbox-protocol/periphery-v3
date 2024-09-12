// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import {PoolV3} from "@gearbox-protocol/core-v3/contracts/pool/PoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";
import {IVersion} from "../interfaces/IVersion.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {CreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/credit/CreditFacadeV3.sol";

// State & Params
import {BaseParams, BaseState} from "../types/BaseState.sol";
import {PoolState, CreditManagerDebtParams} from "../types/PoolState.sol";
import {PoolQuotaKeeperState, QuotaTokenParams} from "../types/PoolQuotaKeeperState.sol";
import {RateKeeperState, Rate} from "../types/RateKeeperState.sol";

import {CreditManagerData} from "../types/MarketData.sol";
import {CreditManagerState} from "../types/CreditManagerState.sol";
import {CreditFacadeState} from "../types/CreditFacadeState.sol";

import {PERCENTAGE_FACTOR, RAY} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {IRateKeeper} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IRateKeeper.sol";

// Serializers
import {BaseLib} from "../libraries/BaseLib.sol";

import {GaugeSerializer} from "../serializers/pool/GaugeSerializer.sol";
import {LinearInterestModelSerializer} from "../serializers/pool/LinearInterestModelSerializer.sol";

/// @title Pool compressor
/// @notice Collects data from pool related contracts
/// Do not use for data from data compressor for state-changing functions
contract PoolCompressorV3 {
    // Contract version
    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "POOL_COMPRESSOR";

    address public immutable gaugeSerializer;
    address public immutable linearInterestModelSerializer;

    constructor() {
        gaugeSerializer = address(new GaugeSerializer());
        linearInterestModelSerializer = address(new LinearInterestModelSerializer());
    }

    function getPoolState(address pool) public view returns (PoolState memory result) {
        PoolV3 _pool = PoolV3(pool);
        //
        // CONTRACT PARAMETERS
        //
        result.baseParams = BaseLib.getBaseParams(pool, "POOL", address(0));

        //
        // ERC20 Properties
        //
        // string symbol;
        result.symbol = _pool.symbol();
        // string name;
        result.name = _pool.name();
        // uint8 decimals;
        result.decimals = _pool.decimals();
        // uint256 totalSupply;
        result.totalSupply = _pool.totalSupply();

        // address poolQuotaKeeper;
        result.poolQuotaKeeper = _pool.poolQuotaKeeper();
        // address interestRateModel;
        result.interestRateModel = _pool.interestRateModel();

        result.treasury = _pool.treasury();
        result.controller = _pool.controller();
        //
        // address underlying;
        result.underlying = _pool.underlyingToken();

        // uint256 availableLiquidity;
        result.availableLiquidity = _pool.availableLiquidity();
        // uint256 expectedLiquidity;
        result.expectedLiquidity = _pool.expectedLiquidity();

        // uint256 baseInterestIndex;
        result.baseInterestIndex = _pool.baseInterestIndex();
        // uint256 baseInterestRate;
        result.baseInterestRate = _pool.baseInterestRate();
        // uint256 dieselRate;
        result.dieselRate = _pool.convertToAssets(RAY);

        // uint256 totalBorrowed;
        result.totalBorrowed = _pool.totalBorrowed();
        // uint256 totalAssets;
        result.totalAssets = _pool.totalAssets();
        // uint256 supplyRate;
        result.supplyRate = _pool.supplyRate();
        // uint256 withdrawFee;
        result.withdrawFee = _pool.withdrawFee();
        // uint256 totalDebtLimit;
        result.totalDebtLimit = _pool.totalDebtLimit();

        // updates
        // uint256 baseInterestIndexLU;
        result.baseInterestIndexLU = _pool.baseInterestIndexLU();

        // uint256 expectedLiquidityLU;
        result.baseInterestIndexLU = _pool.baseInterestIndexLU();

        // uint256 quotaRevenue;
        result.quotaRevenue = _pool.quotaRevenue();

        // uint256 lastBaseInterestUpdate;
        result.lastBaseInterestUpdate = _pool.lastBaseInterestUpdate();

        // uint40 lastQuotaRevenueUpdate;
        result.lastQuotaRevenueUpdate = _pool.lastQuotaRevenueUpdate();
        // uint256 baseInterestIndexLU;
        result.baseInterestIndexLU = _pool.baseInterestIndexLU();

        // CreditManagerDebtParams[] creditManagerDebtParams;
        address[] memory creditManagers = _pool.creditManagers();
        uint256 len = creditManagers.length;
        result.creditManagerDebtParams = new CreditManagerDebtParams[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                address creditManager = creditManagers[i];
                result.creditManagerDebtParams[i] = CreditManagerDebtParams({
                    creditManager: creditManager,
                    borrowed: _pool.creditManagerBorrowed(creditManager),
                    limit: _pool.creditManagerDebtLimit(creditManager)
                });
            }
        }
        // bool isPaused;
        result.isPaused = _pool.paused();
    }

    function getPoolQuotaKeeperState(address pqk) external view returns (PoolQuotaKeeperState memory result) {
        IPoolQuotaKeeperV3 _pqk = IPoolQuotaKeeperV3(pqk);

        result.baseParams = BaseLib.getBaseParams(pqk, "POOL_QUOTA_KEEPER", address(0));

        // address rateKeeper;
        result.rateKeeper = _pqk.gauge();
        // QuotaTokenParams[] quotas;
        address[] memory quotaTokens = _pqk.quotedTokens();
        uint256 len = quotaTokens.length;
        result.quotas = new QuotaTokenParams[](len);
        unchecked {
            for (uint256 i; i < len; ++i) {
                result.quotas[i].token = quotaTokens[i];
                (
                    result.quotas[i].rate,
                    ,
                    result.quotas[i].quotaIncreaseFee,
                    result.quotas[i].totalQuoted,
                    result.quotas[i].limit,
                    result.quotas[i].isActive
                ) = _pqk.getTokenQuotaParams(quotaTokens[i]);
            }
        }

        // address[] creditManagers;
        result.creditManagers = _pqk.creditManagers();

        // uint40 lastQuotaRateUpdate;
        result.lastQuotaRateUpdate = _pqk.lastQuotaRateUpdate();
    }

    function getRateKeeperState(address rateKeeper) external view returns (RateKeeperState memory result) {
        IRateKeeper _rateKeeper = IRateKeeper(rateKeeper);

        bytes32 contractType;

        result.baseParams = BaseLib.getBaseParams(rateKeeper, "GAUGE", gaugeSerializer);

        IPoolQuotaKeeperV3 _pqk = IPoolQuotaKeeperV3(PoolV3(_rateKeeper.pool()).poolQuotaKeeper());

        address[] memory quotaTokens = _pqk.quotedTokens();
        uint256 quotaTokensLen = quotaTokens.length;

        uint16[] memory rawRates = _rateKeeper.getRates(quotaTokens);
        result.rates = new Rate[](quotaTokensLen);

        for (uint256 i; i < quotaTokensLen; ++i) {
            result.rates[i].token = quotaTokens[i];
            result.rates[i].rate = rawRates[i];
        }
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
        // address priceOracle;
        result.priceOracle = creditManager.priceOracle();
        // uint8 maxEnabledTokens;
        result.maxEnabledTokens = creditManager.maxEnabledTokens();
        // address[] collateralTokens;
        // uint16[] liquidationThresholds;
        {
            uint256 collateralTokenCount = creditManager.collateralTokensCount();

            result.collateralTokens = new address[](collateralTokenCount);
            result.liquidationThresholds = new uint16[](collateralTokenCount);

            unchecked {
                for (uint256 i = 0; i < collateralTokenCount; ++i) {
                    (result.collateralTokens[i], result.liquidationThresholds[i]) =
                        creditManager.collateralTokenByMask(1 << i);
                }
            }
        }
        // uint16 feeInterest; // Interest fee protocol charges: fee = interest accrues * feeInterest
        // uint16 feeLiquidation; // Liquidation fee protocol charges: fee = totalValue * feeLiquidation
        // uint16 liquidationDiscount; // Miltiplier to get amount which liquidator should pay: amount = totalValue * liquidationDiscount
        // uint16 feeLiquidationExpired; // Liquidation fee protocol charges on expired accounts
        // uint16 liquidationDiscountExpired; // Multiplier for the amount the liquidator has to pay when closing an expired account
        {
            (
                result.feeInterest,
                result.feeLiquidation,
                result.liquidationDiscount,
                result.feeLiquidationExpired,
                result.liquidationDiscountExpired
            ) = creditManager.fees();
        }
    }

    /// @dev Returns CreditManagerData for a particular _cm
    /// @param _cf CreditFacade address
    function getCreditFacadeState(address _cf) public view returns (CreditFacadeState memory result) {
        CreditFacadeV3 creditFacade = CreditFacadeV3(_cf);

        result.baseParams = BaseLib.getBaseParams(_cf, "CREDIT_FACADE", address(0));
        //
        result.maxQuotaMultiplier = creditFacade.maxQuotaMultiplier();
        // address treasury;
        // result.treasury = creditFacade.treasury();
        // bool expirable;
        result.expirable = creditFacade.expirable();
        // address degenNFT;
        result.degenNFT = creditFacade.degenNFT();
        // uint40 expirationDate;
        result.expirationDate = creditFacade.expirationDate();
        // uint8 maxDebtPerBlockMultiplier;
        result.maxDebtPerBlockMultiplier = creditFacade.maxDebtPerBlockMultiplier();
        // address botList;
        result.botList = creditFacade.botList();
        // uint256 minDebt;
        // uint256 maxDebt;
        (result.minDebt, result.maxDebt) = creditFacade.debtLimits();
        // uint256 forbiddenTokenMask;
        result.forbiddenTokenMask = creditFacade.forbiddenTokenMask();
        // address lossLiquidator;
        // result.lossLiquidator = creditFacade.lossLiquidator();
        // bool isPaused;
        result.isPaused = creditFacade.paused();
    }

    function getInterestModelState(address addr) public view returns (BaseState memory baseState) {
        baseState = BaseLib.getBaseState(addr, "INTEREST_MODEL", linearInterestModelSerializer);
    }

    function getCreditManagerData(address creditManager) public view returns (CreditManagerData memory result) {
        result.creditManager = getCreditManagerState(creditManager);
        result.creditFacade = getCreditFacadeState(ICreditManagerV3(creditManager).creditFacade());
        result.creditConfigurator = BaseLib.getBaseState(
            ICreditManagerV3(creditManager).creditConfigurator(), "CREDIT_CONFIGURATOR", address(0)
        );

        PoolV3 _pool = PoolV3(result.creditManager.pool);
        result.totalDebt = _pool.creditManagerBorrowed(creditManager);
        result.totalDebtLimit = _pool.creditManagerDebtLimit(creditManager);
        result.availableToBorrow = _pool.creditManagerBorrowable(creditManager);
    }
}

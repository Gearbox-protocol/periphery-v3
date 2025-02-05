// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.23;

import {PoolV3} from "@gearbox-protocol/core-v3/contracts/pool/PoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";
import {IUSDT} from "@gearbox-protocol/core-v3/contracts/interfaces/external/IUSDT.sol";

// State & Params
import {BaseParams, BaseState} from "../types/BaseState.sol";
import {PoolState, CreditManagerDebtParams} from "../types/PoolState.sol";
import {PoolQuotaKeeperState, QuotaTokenParams} from "../types/PoolQuotaKeeperState.sol";
import {RateKeeperState, Rate} from "../types/RateKeeperState.sol";

import {RAY} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {IRateKeeper} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IRateKeeper.sol";

// Serializers
import {BaseLib} from "../libraries/BaseLib.sol";
import {GaugeSerializer} from "../serializers/pool/GaugeSerializer.sol";
import {LinearInterestRateModelSerializer} from "../serializers/pool/LinearInterestRateModelSerializer.sol";

/// @title Pool compressor
/// @notice Collects data from pool related contracts
/// Do not use for data from data compressor for state-changing functions
contract PoolCompressor {
    // Contract version
    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "POOL_COMPRESSOR";

    address public immutable gaugeSerializer;
    address public immutable linearInterestRateModelSerializer;

    constructor() {
        gaugeSerializer = address(new GaugeSerializer());
        linearInterestRateModelSerializer = address(new LinearInterestRateModelSerializer());
    }

    function getPoolState(address pool) public view returns (PoolState memory result) {
        PoolV3 _pool = PoolV3(pool);
        //
        // CONTRACT PARAMETERS
        //
        bytes32 defaultContractType = "POOL";
        try IUSDT(_pool.underlyingToken()).basisPointsRate() {
            defaultContractType = "POOL::USDT";
        } catch {}
        result.baseParams = BaseLib.getBaseParams(pool, defaultContractType, address(0));

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

        // uint256 supplyRate;
        result.supplyRate = _pool.supplyRate();
        // uint256 withdrawFee;
        result.withdrawFee = _pool.withdrawFee();

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

        // uint256 totalBorrowed;
        result.totalBorrowed = _pool.totalBorrowed();
        // uint256 totalDebtLimit;
        result.totalDebtLimit = _pool.totalDebtLimit();

        // CreditManagerDebtParams[] creditManagerDebtParams;
        address[] memory creditManagers = _pool.creditManagers();
        uint256 len = creditManagers.length;
        result.creditManagerDebtParams = new CreditManagerDebtParams[](len);

        for (uint256 i; i < len; ++i) {
            address creditManager = creditManagers[i];
            result.creditManagerDebtParams[i] = CreditManagerDebtParams({
                creditManager: creditManager,
                borrowed: _pool.creditManagerBorrowed(creditManager),
                limit: _pool.creditManagerDebtLimit(creditManager),
                available: _pool.creditManagerBorrowable(creditManager)
            });
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

        result.baseParams = BaseLib.getBaseParams(rateKeeper, "RATE_KEEPER::GAUGE", gaugeSerializer);

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

    function getInterestRateModelState(address addr) public view returns (BaseState memory) {
        return BaseLib.getBaseState(addr, "IRM::LINEAR", linearInterestRateModelSerializer);
    }

    function getLossPolicyState(address lossPolicy) public view returns (BaseState memory) {
        return BaseLib.getBaseState(lossPolicy, "LOSS_POLICY::DEFAULT", address(0));
    }
}

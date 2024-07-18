// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;
pragma experimental ABIEncoderV2;

import {PoolV3} from "@gearbox-protocol/core-v3/contracts/pool/PoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";

import {PoolState, CreditManagerDebtParams} from "../types/PoolState.sol";
import {PoolQuotaKeeperState, QuotaTokenParams} from "../types/PoolQuotaKeeperState.sol";
import {RateKeeperState, Rate} from "../types/RateKeeperState.sol";
import {PERCENTAGE_FACTOR, RAY} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {IRateKeeper} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IRateKeeper.sol";

import {RateKeeperType} from "../types/Enums.sol";
// Serializers
import {GaugeSerializer} from "../serializers/pool/GaugeSerializer.sol";

/// @title Pool compressor
/// @notice Collects data from pool related contracts
/// Do not use for data from data compressor for state-changing functions
contract PoolCompressorV3 {
    // Contract version
    uint256 public constant version = 3_10;

    address public immutable gaugeSerializer;

    constructor() {
        gaugeSerializer = address(new GaugeSerializer());
    }

    function getPoolState(address pool) public view returns (PoolState memory result) {
        PoolV3 _pool = PoolV3(pool);
        //
        // CONTRACT PARAMETERS
        //
        // address addr;
        result.addr = pool;
        // uint16 poolType;
        // uint256 version;
        result.version = _pool.version();

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

        // // connected contracts

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
        // //
        // uint256 baseInterestIndex;
        result.baseInterestIndex = _pool.baseInterestIndex();
        // uint256 baseInterestRate;
        result.baseInterestRate = _pool.baseInterestRate();
        // uint256 dieselRate_RAY;
        result.dieselRate_RAY = _pool.convertToAssets(RAY);
        // uint256 totalBorrowed;
        result.totalBorrowed = _pool.totalBorrowed();
        // uint256 totalDebtLimit;
        result.totalDebtLimit = _pool.totalDebtLimit();
        // uint256 totalAssets;
        result.totalAssets = _pool.totalAssets();

        // uint256 supplyRate;
        result.supplyRate = _pool.supplyRate();
        // uint256 withdrawFee;
        result.withdrawFee = _pool.withdrawFee();
        // uint256 lastBaseInterestUpdate;
        result.lastBaseInterestUpdate = _pool.lastBaseInterestUpdate();
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
                    limit: _pool.creditManagerDebtLimit(creditManager),
                    availableToBorrow: _pool.creditManagerBorrowable(creditManager)
                });
            }
        }
        // bool isPaused;
        result.isPaused = _pool.paused();
    }

    function getPoolQuotaKeeperState(address pqk) external view returns (PoolQuotaKeeperState memory result) {
        IPoolQuotaKeeperV3 _pqk = IPoolQuotaKeeperV3(pqk);

        result.addr = pqk;

        // address version;
        result.version = _pqk.version();
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

        // uint40 lastQuotaRateUpdate;
        result.lastQuotaRateUpdate = _pqk.lastQuotaRateUpdate();
    }

    function getRateKeeperState(address rateKeeper) external view returns (RateKeeperState memory result) {
        IRateKeeper _rateKeeper = IRateKeeper(rateKeeper);

        IPoolQuotaKeeperV3 _pqk;

        result.addr = rateKeeper;

        result.version = _rateKeeper.version();
        if (result.version == 3_00) {
            result.contractType = "RK_GAUGE";
            _pqk = IPoolQuotaKeeperV3(PoolV3(IGaugeV3(rateKeeper).pool()).poolQuotaKeeper());
            result.serialisedData = GaugeSerializer(gaugeSerializer).serialize(rateKeeper);
        } else {
            // TODO: add querying data for 3.1
            // resuilt.rateKeeperType = uint16(_rateKeeper.rateKeeperType());
            // _pqk = IPoolQuotaKeeperV3(IGaugeV3(rateKeeper).quotaKeeper());
        }

        address[] memory quotaTokens = _pqk.quotedTokens();
        uint256 quotaTokensLen = quotaTokens.length;

        uint16[] memory rawRates = _rateKeeper.getRates(quotaTokens);
        result.rates = new Rate[](quotaTokensLen);

        for (uint256 i; i < quotaTokensLen; ++i) {
            result.rates[i].token = quotaTokens[i];
            result.rates[i].rate = rawRates[i];
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2024
pragma solidity ^0.8.10;

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IGaugeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGaugeV3.sol";
import {IGearStakingV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IGearStakingV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IContractsRegister} from "@gearbox-protocol/permissionless/contracts/interfaces/IContractsRegister.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {IMarketConfiguratorFactory} from
    "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfiguratorFactory.sol";
import {
    AP_MARKET_CONFIGURATOR_FACTORY,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/permissionless/contracts/libraries/ContractLiterals.sol";

import {MarketFilter} from "../types/Filters.sol";
import {GaugeQuotaParams, GaugeInfo} from "../types/RateKeeperState.sol";
import {IGaugeCompressor} from "../interfaces/IGaugeCompressor.sol";
import {AP_GAUGE_COMPRESSOR} from "../libraries/Literals.sol";

/// @title Gauge Compressor
/// @notice Collects data from gauges for use in the dApp
contract GaugeCompressor is IGaugeCompressor {
    uint256 public constant version = 3_10;
    bytes32 public constant contractType = AP_GAUGE_COMPRESSOR;

    address public immutable marketConfiguratorFactory;

    struct Pool {
        address addr;
        address configurator;
    }

    constructor(address addressProvider) {
        marketConfiguratorFactory =
            IAddressProvider(addressProvider).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);
    }

    /// @dev Returns gauge info for all gauges matching the filter
    /// @param filter Filter parameters for pools
    /// @param staker Address of the staker to get votes for (can be address(0) if not needed)
    function getGauges(MarketFilter memory filter, address staker)
        external
        view
        override
        returns (GaugeInfo[] memory result)
    {
        Pool[] memory pools = _getPools(filter);
        uint256 len = pools.length;
        result = new GaugeInfo[](len);
        uint256 validGauges;

        for (uint256 i; i < len; ++i) {
            address pool = pools[i].addr;
            IPoolQuotaKeeperV3 pqk = _getPoolQuotaKeeper(pool);
            address gauge = _getGauge(pqk);

            if (gauge == address(0)) continue;

            try this.getGauge(gauge, staker) returns (GaugeInfo memory gaugeInfo) {
                result[validGauges++] = gaugeInfo;
            } catch {
                continue;
            }
        }

        return _trim(result, validGauges);
    }

    /// @dev Returns gauge info for a specific gauge
    /// @param gauge Gauge address
    /// @param staker Address of the staker to get votes for (can be address(0) if not needed)
    function getGauge(address gauge, address staker) public view override returns (GaugeInfo memory result) {
        if (!_isValidGauge(gauge)) revert("INVALID_GAUGE_TYPE");

        address pool = IGaugeV3(gauge).pool();
        IPoolQuotaKeeperV3 pqk = _getPoolQuotaKeeper(pool);
        return _getGaugeInfo(gauge, pool, pqk, staker);
    }

    /// @dev Internal function to check if an address is a valid gauge
    /// @param gauge Address to check
    /// @return True if the address is a valid gauge (either old or new version)
    function _isValidGauge(address gauge) internal view returns (bool) {
        try IGaugeV3(gauge).contractType() returns (bytes32 cType) {
            return cType == "RATE_KEEPER::GAUGE";
        } catch {
            return true;
        }
    }

    /// @dev Internal function to get gauge info
    function _getGaugeInfo(address gauge, address pool, IPoolQuotaKeeperV3 pqk, address staker)
        internal
        view
        returns (GaugeInfo memory gaugeInfo)
    {
        gaugeInfo.addr = gauge;
        gaugeInfo.pool = pool;
        (gaugeInfo.symbol, gaugeInfo.name) = _getSymbolAndName(pool);
        gaugeInfo.underlying = IPoolV3(pool).asset();
        gaugeInfo.voter = IGaugeV3(gauge).voter();

        gaugeInfo.currentEpoch = IGearStakingV3(gaugeInfo.voter).getCurrentEpoch();
        gaugeInfo.epochLastUpdate = IGaugeV3(gauge).epochLastUpdate();
        gaugeInfo.epochFrozen = IGaugeV3(gauge).epochFrozen();

        address[] memory quotaTokens = pqk.quotedTokens();
        uint256 quotaTokensLen = quotaTokens.length;
        gaugeInfo.quotaParams = new GaugeQuotaParams[](quotaTokensLen);

        for (uint256 j; j < quotaTokensLen; ++j) {
            GaugeQuotaParams memory quotaParams = gaugeInfo.quotaParams[j];
            address token = quotaTokens[j];
            quotaParams.token = token;

            (quotaParams.minRate, quotaParams.maxRate, quotaParams.totalVotesLpSide, quotaParams.totalVotesCaSide) =
                IGaugeV3(gauge).quotaRateParams(token);

            // Get staker votes if staker address is provided
            if (staker != address(0)) {
                (quotaParams.stakerVotesLpSide, quotaParams.stakerVotesCaSide) =
                    IGaugeV3(gauge).userTokenVotes(staker, token);
            }
        }
    }

    /// @dev Internal function to get pools matching the filter
    function _getPools(MarketFilter memory filter) internal view returns (Pool[] memory pools) {
        address[] memory configurators = filter.configurators.length != 0
            ? filter.configurators
            : IMarketConfiguratorFactory(marketConfiguratorFactory).getMarketConfigurators();

        // rough estimate of maximum number of pools
        uint256 max;
        for (uint256 i; i < configurators.length; ++i) {
            address contractsRegister = IMarketConfigurator(configurators[i]).contractsRegister();
            max += IContractsRegister(contractsRegister).getPools().length;
        }

        pools = new Pool[](max);
        uint256 num;

        for (uint256 i; i < configurators.length; ++i) {
            address contractsRegister = IMarketConfigurator(configurators[i]).contractsRegister();
            address[] memory poolsMC = IContractsRegister(contractsRegister).getPools();
            for (uint256 j; j < poolsMC.length; ++j) {
                address pool = poolsMC[j];
                if (filter.pools.length != 0 && !_contains(filter.pools, pool)) continue;
                if (filter.underlying != address(0) && IPoolV3(pool).asset() != filter.underlying) continue;
                pools[num++] = Pool({addr: pool, configurator: configurators[i]});
            }
        }

        assembly {
            mstore(pools, num)
        }
    }

    /// @dev Internal function to get pool quota keeper
    function _getPoolQuotaKeeper(address pool) internal view returns (IPoolQuotaKeeperV3) {
        return IPoolQuotaKeeperV3(IPoolV3(pool).poolQuotaKeeper());
    }

    /// @dev Internal function to get gauge from pool quota keeper
    function _getGauge(IPoolQuotaKeeperV3 pqk) internal view returns (address) {
        return pqk.gauge();
    }

    /// @dev Internal function to get symbol and name of a token
    function _getSymbolAndName(address token) internal view returns (string memory symbol, string memory name) {
        symbol = IERC20Metadata(token).symbol();
        name = IERC20Metadata(token).name();
    }

    /// @dev Internal function to check if an array contains an address
    function _contains(address[] memory array, address value) internal pure returns (bool) {
        for (uint256 i; i < array.length; ++i) {
            if (array[i] == value) return true;
        }
        return false;
    }

    function _trim(GaugeInfo[] memory array, uint256 validGauges) internal pure returns (GaugeInfo[] memory result) {
        result = new GaugeInfo[](validGauges);

        for (uint256 i = 0; i < validGauges; ++i) {
            result[i] = array[i];
        }
        return result;
    }
}

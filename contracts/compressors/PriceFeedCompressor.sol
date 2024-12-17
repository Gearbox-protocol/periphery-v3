// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {AddressIsNotContractException} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3, PriceFeedParams} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {IPriceFeed, IUpdatablePriceFeed} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeed.sol";
import {IPriceFeedCompressor} from "../interfaces/IPriceFeedCompressor.sol";
import {PriceFeedType} from "@gearbox-protocol/sdk-gov/contracts/PriceFeedType.sol";
import {IVersion} from "../interfaces/IVersion.sol";

import {BaseLib} from "../libraries/BaseLib.sol";

import {IStateSerializerLegacy} from "../interfaces/IStateSerializerLegacy.sol";
import {IStateSerializer} from "../interfaces/IStateSerializer.sol";
import {NestedPriceFeeds} from "../libraries/NestedPriceFeeds.sol";
import {BoundedPriceFeedSerializer} from "../serializers/oracles/BoundedPriceFeedSerializer.sol";
import {BPTWeightedPriceFeedSerializer} from "../serializers/oracles/BPTWeightedPriceFeedSerializer.sol";
import {LPPriceFeedSerializer} from "../serializers/oracles/LPPriceFeedSerializer.sol";
import {PythPriceFeedSerializer} from "../serializers/oracles/PythPriceFeedSerializer.sol";
import {RedstonePriceFeedSerializer} from "../serializers/oracles/RedstonePriceFeedSerializer.sol";
import {PendleTWAPPTPriceFeedSerializer} from "../serializers/oracles/PendleTWAPPTPriceFeedSerializer.sol";
import {PriceFeedAnswer, PriceFeedMapEntry, PriceFeedTreeNode, PriceOracleState} from "../types/PriceOracleState.sol";

interface ImplementsPriceFeedType {
    /// @dev Annotates `priceFeedType` as `uint8` instead of `PriceFeedType` enum to support future types
    function priceFeedType() external view returns (uint8);
}

/// @dev Price oracle with version below `3_10` has some important interface differences:
///      - it does not implement `getTokens`
///      - it only allows to fetch staleness period of a currently active price feed
interface IPriceOracleV3Legacy {
    /// @dev Older signature for fetching main and reserve feeds, reverts if price feed is not set
    function priceFeedsRaw(address token, bool reserve) external view returns (address);
}

/// @title  Price feed compressor
/// @notice Allows to fetch all useful data from price oracle in a single call
/// @dev    The contract is not gas optimized and is thus not recommended for on-chain use
contract PriceFeedCompressor is IPriceFeedCompressor {
    using NestedPriceFeeds for IPriceFeed;

    /// @notice Contract version
    uint256 public constant override version = 3_10;
    bytes32 public constant override contractType = "PRICE_FEED_COMPRESSOR";

    /// @notice Map of state serializers for different price feed types
    /// @dev    Serializers only apply to feeds that don't implement `IStateSerializer` themselves
    mapping(bytes32 => address) public serializers;

    mapping(uint8 => bytes32) public contractTypes;

    /// @notice Constructor
    /// @dev    Sets serializers for existing price feed types.
    ///         It is recommended to implement `IStateSerializer` in new price feeds.
    constructor() {
        address lpSerializer = address(new LPPriceFeedSerializer());

        contractTypes[uint8(PriceFeedType.ZERO_ORACLE)] = "PF_ZERO_ORACLE";
        contractTypes[uint8(PriceFeedType.CHAINLINK_ORACLE)] = "PF_CHAINLINK_ORACLE";
        contractTypes[uint8(PriceFeedType.COMPOSITE_ORACLE)] = "PF_COMPOSITE_ORACLE";

        contractTypes[uint8(PriceFeedType.BALANCER_STABLE_LP_ORACLE)] = "PF_BALANCER_STABLE_LP_ORACLE";
        contractTypes[uint8(PriceFeedType.COMPOUND_V2_ORACLE)] = "NOT_USED";
        contractTypes[uint8(PriceFeedType.CURVE_2LP_ORACLE)] = "PF_CURVE_STABLE_LP_ORACLE";
        contractTypes[uint8(PriceFeedType.CURVE_3LP_ORACLE)] = "PF_CURVE_STABLE_LP_ORACLE";
        contractTypes[uint8(PriceFeedType.CURVE_4LP_ORACLE)] = "PF_CURVE_STABLE_LP_ORACLE";
        contractTypes[uint8(PriceFeedType.CURVE_CRYPTO_ORACLE)] = "PF_CURVE_CRYPTO_LP_ORACLE";
        contractTypes[uint8(PriceFeedType.CURVE_USD_ORACLE)] = "PF_CURVE_USD_ORACLE";
        contractTypes[uint8(PriceFeedType.ERC4626_VAULT_ORACLE)] = "PF_ERC4626_ORACLE";
        contractTypes[uint8(PriceFeedType.WRAPPED_AAVE_V2_ORACLE)] = "NOT_USED";
        contractTypes[uint8(PriceFeedType.WSTETH_ORACLE)] = "PF_WSTETH_ORACLE";
        contractTypes[uint8(PriceFeedType.YEARN_ORACLE)] = "PF_YEARN_ORACLE";
        contractTypes[uint8(PriceFeedType.MELLOW_LRT_ORACLE)] = "PF_MELLOW_LRT_ORACLE";
        contractTypes[uint8(PriceFeedType.PENDLE_PT_TWAP_ORACLE)] = "PF_PENDLE_PT_TWAP_ORACLE";

        // these types need special serialization
        contractTypes[uint8(PriceFeedType.BALANCER_WEIGHTED_LP_ORACLE)] = "PF_BALANCER_WEIGHTED_LP_ORACLE";
        contractTypes[uint8(PriceFeedType.BOUNDED_ORACLE)] = "PF_BOUNDED_ORACLE";
        contractTypes[uint8(PriceFeedType.PYTH_ORACLE)] = "PF_PYTH_ORACLE";
        contractTypes[uint8(PriceFeedType.REDSTONE_ORACLE)] = "PF_REDSTONE_ORACLE";

        // these types can be serialized as generic LP price feeds
        _setSerializer("PF_BALANCER_STABLE_LP_ORACLE", lpSerializer);
        _setSerializer("PF_CURVE_STABLE_LP_ORACLE", lpSerializer);
        _setSerializer("PF_CURVE_CRYPTO_LP_ORACLE", lpSerializer);
        _setSerializer("PF_CURVE_USD_ORACLE", lpSerializer);
        _setSerializer("PF_ERC4626_ORACLE", lpSerializer);
        _setSerializer("PF_WSTETH_ORACLE", lpSerializer);
        _setSerializer("PF_YEARN_ORACLE", lpSerializer);
        _setSerializer("PF_MELLOW_LRT_ORACLE", lpSerializer);

        // these types need special serialization
        _setSerializer("PF_BALANCER_WEIGHTED_LP_ORACLE", address(new BPTWeightedPriceFeedSerializer()));
        _setSerializer("PF_BOUNDED_ORACLE", address(new BoundedPriceFeedSerializer()));
        _setSerializer("PF_PYTH_ORACLE", address(new PythPriceFeedSerializer()));
        _setSerializer("PF_REDSTONE_ORACLE", address(new RedstonePriceFeedSerializer()));
        _setSerializer("PF_PENDLE_PT_TWAP_ORACLE", address(new PendleTWAPPTPriceFeedSerializer()));
    }

    /// @notice Returns all potentially useful price feeds data for a given price oracle in the form of two arrays:
    ///         - `priceFeedMap` is a set of entries in the map (token, reserve) => (priceFeed, stalenessPeirod).
    ///         These are all the price feeds one can actually query via the price oracle.
    ///         - `priceFeedTree` is a set of nodes in a tree-like structure that contains detailed info of both feeds
    ///         from `priceFeedMap` and their underlying feeds, in case former are nested, which can help to determine
    ///         what underlying feeds should be updated to query the nested one.
    function getPriceFeeds(address priceOracle)
        public
        view
        override
        returns (PriceFeedMapEntry[] memory priceFeedMap, PriceFeedTreeNode[] memory priceFeedTree)
    {
        address[] memory tokens = IPriceOracleV3(priceOracle).getTokens();
        return getPriceFeeds(priceOracle, tokens);
    }

    function getPriceOracleState(address priceOracle, address[] memory tokens)
        external
        view
        returns (PriceOracleState memory result)
    {
        result.baseParams = BaseLib.getBaseParams(priceOracle, "PRICE_ORACLE", address(0));
        (result.priceFeedMapping, result.priceFeedStructure) = getPriceFeeds(priceOracle, tokens);
    }

    /// @dev Same as the above but takes the list of tokens as argument as legacy oracle doesn't implement `getTokens`
    function getPriceFeeds(address priceOracle, address[] memory tokens)
        public
        view
        override
        returns (PriceFeedMapEntry[] memory priceFeedMap, PriceFeedTreeNode[] memory priceFeedTree)
    {
        uint256 numTokens = tokens.length;

        priceFeedMap = new PriceFeedMapEntry[](2 * numTokens);
        uint256 priceFeedMapSize;
        uint256 priceFeedTreeSize;

        for (uint256 i; i < 2 * numTokens; ++i) {
            address token = tokens[i % numTokens];
            bool reserve = i >= numTokens;

            (address priceFeed, uint32 stalenessPeriod) = _getPriceFeed(priceOracle, token, reserve);
            if (priceFeed == address(0)) continue;

            priceFeedMap[priceFeedMapSize++] = PriceFeedMapEntry({
                token: token,
                reserve: reserve,
                priceFeed: priceFeed,
                stalenessPeriod: stalenessPeriod
            });
            priceFeedTreeSize += _getPriceFeedTreeSize(priceFeed);
        }
        assembly {
            mstore(priceFeedMap, priceFeedMapSize)
        }

        priceFeedTree = new PriceFeedTreeNode[](priceFeedTreeSize);
        uint256 offset;
        for (uint256 i; i < priceFeedMapSize; ++i) {
            offset = _loadPriceFeedTree(priceFeedMap[i].priceFeed, priceFeedTree, offset);
        }
        // trim array to its actual size in case there were duplicates
        assembly {
            mstore(priceFeedTree, offset)
        }
    }

    function loadPriceFeedTree(address[] memory priceFeeds)
        external
        view
        override
        returns (PriceFeedTreeNode[] memory priceFeedTree)
    {
        uint256 len = priceFeeds.length;
        uint256 priceFeedTreeSize;

        for (uint256 i; i < len; ++i) {
            priceFeedTreeSize += _getPriceFeedTreeSize(priceFeeds[i]);
        }

        priceFeedTree = new PriceFeedTreeNode[](priceFeedTreeSize);
        uint256 offset;
        for (uint256 i; i < len; ++i) {
            offset = _loadPriceFeedTree(priceFeeds[i], priceFeedTree, offset);
        }
        // trim array to its actual size in case there were duplicates
        assembly {
            mstore(priceFeedTree, offset)
        }
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Sets `serializer` for `priceFeedType`
    function _setSerializer(bytes32 contractType, address serializer) internal {
        if (serializers[contractType] != serializer) {
            serializers[contractType] = serializer;
            emit SetSerializer(contractType, serializer);
        }
    }

    /// @dev Returns `token`'s price feed in the price oracle
    function _getPriceFeed(address priceOracle, address token, bool reserve) internal view returns (address, uint32) {
        if (IPriceOracleV3(priceOracle).version() < 3_10) {
            try IPriceOracleV3Legacy(priceOracle).priceFeedsRaw(token, reserve) returns (address priceFeed) {
                // legacy oracle does not allow to fetch staleness period of a non-active feed
                return (priceFeed, 0);
            } catch {
                return (address(0), 0);
            }
        }
        PriceFeedParams memory params = reserve
            ? IPriceOracleV3(priceOracle).reservePriceFeedParams(token)
            : IPriceOracleV3(priceOracle).priceFeedParams(token);
        return (params.priceFeed, params.stalenessPeriod);
    }

    /// @dev Computes the size of the `priceFeed`'s subtree (recursively)
    function _getPriceFeedTreeSize(address priceFeed) internal view returns (uint256 size) {
        size = 1;
        (address[] memory underlyingFeeds,) = IPriceFeed(priceFeed).getUnderlyingFeeds();
        for (uint256 i; i < underlyingFeeds.length; ++i) {
            size += _getPriceFeedTreeSize(underlyingFeeds[i]);
        }
    }

    /// @dev Loads `priceFeed`'s subtree (recursively)
    function _loadPriceFeedTree(address priceFeed, PriceFeedTreeNode[] memory priceFeedTree, uint256 offset)
        internal
        view
        returns (uint256)
    {
        // duplicates are possible since price feed can be in `priceFeedMap` for more than one (token, reserve) pair
        // or serve as an underlying in more than one nested feed, and the whole subtree can be skipped in this case
        for (uint256 i; i < offset; ++i) {
            if (priceFeedTree[i].baseParams.addr == priceFeed) return offset;
        }

        PriceFeedTreeNode memory node = _getPriceFeedTreeNode(priceFeed);
        priceFeedTree[offset++] = node;
        for (uint256 i; i < node.underlyingFeeds.length; ++i) {
            offset = _loadPriceFeedTree(node.underlyingFeeds[i], priceFeedTree, offset);
        }
        return offset;
    }

    /// @dev Returns price feed tree node, see `PriceFeedTreeNode` for detailed description of struct fields
    function _getPriceFeedTreeNode(address priceFeed) internal view returns (PriceFeedTreeNode memory data) {
        try IVersion(priceFeed).contractType() returns (bytes32 contractType) {
            data.baseParams.contractType = contractType;
        } catch {
            try ImplementsPriceFeedType(priceFeed).priceFeedType() returns (uint8 priceFeedType) {
                data.baseParams.contractType = contractTypes[priceFeedType];
            } catch {
                data.baseParams.contractType = "PF_CHAINLINK_ORACLE";
            }
        }

        data.baseParams =
            BaseLib.getBaseParams(priceFeed, data.baseParams.contractType, serializers[data.baseParams.contractType]);

        data.decimals = IPriceFeed(priceFeed).decimals();

        try IPriceFeed(priceFeed).skipPriceCheck() returns (bool skipCheck) {
            data.skipCheck = skipCheck;
        } catch {}

        try IUpdatablePriceFeed(priceFeed).updatable() returns (bool updatable) {
            data.updatable = updatable;
        } catch {}

        (data.underlyingFeeds, data.underlyingStalenessPeriods) = IPriceFeed(priceFeed).getUnderlyingFeeds();

        try IPriceFeed(priceFeed).latestRoundData() returns (uint80, int256 price, uint256, uint256 updatedAt, uint80) {
            data.answer = PriceFeedAnswer({price: price, updatedAt: updatedAt, success: true});
        } catch {}
    }
}

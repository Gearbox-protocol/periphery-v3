// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {AddressIsNotContractException} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3, PriceFeedParams} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {IPriceFeed, IUpdatablePriceFeed} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeed.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {PriceFeedType} from "@gearbox-protocol/sdk-gov/contracts/PriceFeedType.sol";

import {IStateSerializer} from "../interfaces/IStateSerializer.sol";
import {IStateSerializerTrait} from "../interfaces/IStateSerializerTrait.sol";
import {NestedPriceFeeds} from "../libraries/NestedPriceFeeds.sol";
import {PriceFeedAnswer, PriceFeedMapEntry, PriceFeedTreeNode} from "./Types.sol";

interface ImplementsPriceFeedType {
    /// @dev Annotates `priceFeedType` as `uint8` instead of `PriceFeedType` enum to support future types
    function priceFeedType() external view returns (uint8);
}

/// @title Price feed compressor
/// @notice Allows to fetch all useful data from price oracle in a single call
/// @dev The contract is not gas optimized and is thus not recommended for on-chain use
contract PriceFeedCompressor is IVersion, Ownable {
    using Address for address;
    using NestedPriceFeeds for IPriceFeed;

    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Map of state serializers for different price feed types
    /// @dev    Serializers only apply to feeds that don't implement `IStateSerializerTrait` themselves
    mapping(uint8 => address) public serializers;

    /// @notice Emitted when new state serializer is set for a given price feed type
    event SetSerializer(uint8 indexed priceFeedType, address indexed serializer);

    /// @notice Constructor
    /// @param  owner Contract owner
    constructor(address owner) {
        transferOwnership(owner);
    }

    /// @notice Sets state serializer for a given price feed type (unsets if `serializer` is `address(0)`)
    function setSerializer(uint8 priceFeedType, address serializer) external onlyOwner {
        if (serializer != address(0) && !serializer.isContract()) revert AddressIsNotContractException(serializer);
        if (serializers[priceFeedType] != serializer) {
            serializers[priceFeedType] = serializer;
            emit SetSerializer(priceFeedType, serializer);
        }
    }

    /// @notice Returns all potentially useful price feeds data for a given price oracle in the form of two arrays:
    ///         - `priceFeedMap` is a set of entries in the map (token, reserve) => (priceFeed, stalenessPeirod).
    ///         These are all the price feeds one can actually query via the price oracle.
    ///         - `priceFeedTree` is a set of nodes in a tree-like structure that contains detailed info of both feeds
    ///         from `priceFeedMap` and their underlying feeds, in case former are nested, which can help to determine
    ///         what underlying feeds should be updated to query the nested one.
    /// @dev    `priceFeedTree` can have duplicate entries since a price feed can both be in `priceFeedMap` for one or
    ///         more (token, reserve) pairs, and serve as an underlying feed in one or more nested feeds.
    ///         If there are two identical nodes in the tree, then subtrees of these nodes are also identical.
    function getPriceFeeds(address priceOracle)
        external
        view
        returns (PriceFeedMapEntry[] memory priceFeedMap, PriceFeedTreeNode[] memory priceFeedTree)
    {
        address[] memory tokens = IPriceOracleV3(priceOracle).getTokens();
        uint256 numTokens = tokens.length;

        priceFeedMap = new PriceFeedMapEntry[](2 * numTokens);
        uint256 priceFeedMapSize;
        uint256 priceFeedTreeSize;

        for (uint256 i; i < 2 * numTokens; ++i) {
            address token = tokens[i % numTokens];
            bool reserve = i >= numTokens;

            PriceFeedParams memory params = reserve
                ? IPriceOracleV3(priceOracle).reservePriceFeedParams(token)
                : IPriceOracleV3(priceOracle).priceFeedParams(token);

            // can only happen to reserve price feeds
            if (params.priceFeed == address(0)) continue;

            priceFeedMap[priceFeedMapSize++] = PriceFeedMapEntry({
                token: token,
                reserve: reserve,
                priceFeed: params.priceFeed,
                stalenessPeriod: params.stalenessPeriod
            });
            priceFeedTreeSize += _getPriceFeedTreeSize(params.priceFeed);
        }
        assembly {
            mstore(priceFeedMap, priceFeedMapSize)
        }

        priceFeedTree = new PriceFeedTreeNode[](priceFeedTreeSize);
        uint256 offset;
        for (uint256 i; i < priceFeedMapSize; ++i) {
            offset = _loadPriceFeedTree(priceFeedMap[i].priceFeed, priceFeedTree, offset);
        }
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
        PriceFeedTreeNode memory node = _getPriceFeedTreeNode(priceFeed);
        priceFeedTree[offset++] = node;
        for (uint256 i; i < node.underlyingFeeds.length; ++i) {
            offset = _loadPriceFeedTree(node.underlyingFeeds[i], priceFeedTree, offset);
        }
        return offset;
    }

    /// @dev Returns price feed tree node, see `PriceFeedTreeNode` for detailed description of struct fields
    function _getPriceFeedTreeNode(address priceFeed) internal view returns (PriceFeedTreeNode memory data) {
        data.priceFeed = priceFeed;
        data.decimals = IPriceFeed(priceFeed).decimals();

        try ImplementsPriceFeedType(priceFeed).priceFeedType() returns (uint8 priceFeedType) {
            data.priceFeedType = priceFeedType;
        } catch {
            data.priceFeedType = uint8(PriceFeedType.CHAINLINK_ORACLE);
        }

        try IPriceFeed(priceFeed).skipPriceCheck() returns (bool skipCheck) {
            data.skipCheck = skipCheck;
        } catch {}

        try IUpdatablePriceFeed(priceFeed).updatable() returns (bool updatable) {
            data.updatable = updatable;
        } catch {}

        try IStateSerializerTrait(priceFeed).serialize() returns (bytes memory specificParams) {
            data.specificParams = specificParams;
        } catch {
            address serializer = serializers[data.priceFeedType];
            if (serializer != address(0)) {
                data.specificParams = IStateSerializer(serializer).serialize(priceFeed);
            }
        }

        (data.underlyingFeeds, data.underlyingStalenessPeriods) = IPriceFeed(priceFeed).getUnderlyingFeeds();

        try IPriceFeed(priceFeed).latestRoundData() returns (uint80, int256 price, uint256, uint256 updatedAt, uint80) {
            data.answer = PriceFeedAnswer({price: price, updatedAt: updatedAt, success: true});
        } catch {}
    }
}

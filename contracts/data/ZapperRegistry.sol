// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IZapper} from "@gearbox-protocol/integrations-v3/contracts/interfaces/zappers/IZapper.sol";
import {IZapperRegistry} from "../interfaces/IZapperRegistry.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";

contract ZapperRegistry is ACLNonReentrantTrait, IZapperRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => EnumerableSet.AddressSet) internal _zappersMap;

    constructor(address addressProvider) ACLNonReentrantTrait(addressProvider) {}

    function addZapper(address zapper) external controllerOnly {
        EnumerableSet.AddressSet storage zapperSet = _zappersMap[IZapper(zapper).pool()];
        if (!zapperSet.contains(zapper)) {
            _zappersMap[IZapper(zapper).pool()].add(zapper);
            emit AddZapper(zapper);
        }
    }

    function removeZapper(address zapper) external controllerOnly {
        EnumerableSet.AddressSet storage zapperSet = _zappersMap[IZapper(zapper).pool()];
        if (zapperSet.contains(zapper)) {
            _zappersMap[IZapper(zapper).pool()].remove(zapper);
            emit RemoveZapper(zapper);
        }
    }

    function zappers(address pool) external view override returns (address[] memory) {
        EnumerableSet.AddressSet storage zapperSet = _zappersMap[pool];
        return zapperSet.values();
    }
}

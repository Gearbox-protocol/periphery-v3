// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Holdings, 2023
pragma solidity ^0.8.10;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IZapper} from "@gearbox-protocol/integrations-v3/contracts/interfaces/zappers/IZapper.sol";
import {IZapperRegister} from "../interfaces/IZapperRegister.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";

contract ZapperRegister is ACLNonReentrantTrait, ContractsRegisterTrait, IZapperRegister {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Contract version
    uint256 public constant version = 3_00;

    mapping(address => EnumerableSet.AddressSet) internal _zappersMap;

    constructor(address addressProvider)
        ACLNonReentrantTrait(addressProvider)
        ContractsRegisterTrait(addressProvider)
    {}

    function addZapper(address zapper) external nonZeroAddress(zapper) controllerOnly {
        address pool = IZapper(zapper).pool();
        _ensureRegisteredPool(pool);

        EnumerableSet.AddressSet storage zapperSet = _zappersMap[pool];
        if (!zapperSet.contains(zapper)) {
            zapperSet.add(zapper);
            emit AddZapper(zapper);
        }
    }

    function removeZapper(address zapper) external nonZeroAddress(zapper) controllerOnly {
        EnumerableSet.AddressSet storage zapperSet = _zappersMap[IZapper(zapper).pool()];
        if (zapperSet.contains(zapper)) {
            zapperSet.remove(zapper);
            emit RemoveZapper(zapper);
        }
    }

    function zappers(address pool) external view override returns (address[] memory) {
        return _zappersMap[pool].values();
    }
}

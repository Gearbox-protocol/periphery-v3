import {MarketData} from "../types/MarketData.sol";
import {PoolState} from "../types/PoolState.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {MarketFilter} from "../types/CreditAccountState.sol";

import "forge-std/console.sol";

/// @title Data compressor 3.0.
/// @notice Collects data from various contracts for use in the dApp
/// Do not use for data from data compressor for state-changing functions
interface IMarketCompressor is IVersion {
    function getMarketData(address pool) external view returns (MarketData memory result);

    function getMarkets(MarketFilter memory filter) external view returns (MarketData[] memory result);
}

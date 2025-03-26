// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2024.
pragma solidity ^0.8.23;

import {IBot} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IBot.sol";
import {IZapper} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IZapper.sol";
import {IBotListV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IBotListV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IAddressProvider} from "@gearbox-protocol/permissionless/contracts/interfaces/IAddressProvider.sol";
import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {
    AP_BOT_LIST,
    AP_MARKET_CONFIGURATOR_FACTORY,
    DOMAIN_BOT,
    DOMAIN_ZAPPER,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/permissionless/contracts/libraries/ContractLiterals.sol";

import {ITokenCompressor} from "../interfaces/ITokenCompressor.sol";
import {IPeripheryCompressor} from "../interfaces/IPeripheryCompressor.sol";
import {BaseLib} from "../libraries/BaseLib.sol";
import {AP_PERIPHERY_COMPRESSOR, AP_TOKEN_COMPRESSOR} from "../libraries/Literals.sol";
import {BotState, ConnectedBotState, ZapperState} from "../types/PeripheryState.sol";

interface IBotListV30x {
    function getBotStatus(address bot, address creditManager, address creditAccount)
        external
        view
        returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions);
}

contract PeripheryCompressor is IPeripheryCompressor {
    /// @notice Contract version
    uint256 public constant override version = 3_10;

    /// @notice Contract type
    bytes32 public constant override contractType = AP_PERIPHERY_COMPRESSOR;

    /// @notice Address provider contract address
    address public immutable addressProvider;

    /// @notice Market configurator factory contract address
    address public immutable marketConfiguratorFactory;

    address internal immutable _tokenCompressor;

    constructor(address addressProvider_) {
        addressProvider = addressProvider_;
        marketConfiguratorFactory =
            IAddressProvider(addressProvider_).getAddressOrRevert(AP_MARKET_CONFIGURATOR_FACTORY, NO_VERSION_CONTROL);

        _tokenCompressor = IAddressProvider(addressProvider_).getAddressOrRevert(AP_TOKEN_COMPRESSOR, 3_10);
    }

    function getZappers(address marketConfigurator, address pool)
        external
        view
        override
        returns (ZapperState[] memory zappers)
    {
        address[] memory allZappers = IMarketConfigurator(marketConfigurator).getPeripheryContracts(DOMAIN_ZAPPER);
        uint256 numZappers = allZappers.length;
        zappers = new ZapperState[](numZappers);
        uint256 num;
        for (uint256 i; i < numZappers; ++i) {
            address zapper = allZappers[i];
            if (IZapper(zapper).pool() != pool) continue;
            ZapperState memory zapperState = ZapperState({
                baseParams: BaseLib.getBaseParams(zapper, "ZAPPER::UNKNOWN", address(0)),
                tokenIn: ITokenCompressor(_tokenCompressor).getTokenInfo(IZapper(zapper).tokenIn()),
                tokenOut: ITokenCompressor(_tokenCompressor).getTokenInfo(IZapper(zapper).tokenOut())
            });
            zappers[num++] = zapperState;
        }
        assembly {
            mstore(zappers, num)
        }
    }

    function getBots(address marketConfigurator) external view override returns (BotState[] memory botStates) {
        address[] memory bots = IMarketConfigurator(marketConfigurator).getPeripheryContracts(DOMAIN_BOT);
        uint256 numBots = bots.length;
        botStates = new BotState[](numBots);
        for (uint256 i; i < numBots; ++i) {
            address bot = bots[i];
            botStates[i].baseParams = BaseLib.getBaseParams(bot, "BOT::UNKNOWN", address(0));
            try IBot(bot).requiredPermissions() returns (uint192 requiredPermissions) {
                botStates[i].requiredPermissions = requiredPermissions;
            } catch {}
        }
    }

    function getConnectedBots(address marketConfigurator, address creditAccount)
        external
        view
        override
        returns (ConnectedBotState[] memory botStates)
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address botList = ICreditFacadeV3(ICreditManagerV3(creditManager).creditFacade()).botList();
        uint256 botListVersion = IBotListV3(botList).version();

        address[] memory bots = IMarketConfigurator(marketConfigurator).getPeripheryContracts(DOMAIN_BOT);
        uint256 numBots = bots.length;
        botStates = new ConnectedBotState[](numBots);
        uint256 num;
        for (uint256 i; i < numBots; ++i) {
            address bot = bots[i];
            ConnectedBotState memory botState;
            if (botListVersion < 3_10) {
                (botState.permissions, botState.forbidden,) =
                    IBotListV30x(botList).getBotStatus(bot, creditManager, creditAccount);
            } else {
                (botState.permissions, botState.forbidden) = IBotListV3(botList).getBotStatus(bot, creditAccount);
            }
            if (botState.permissions != 0) {
                botState.baseParams = BaseLib.getBaseParams(bot, "BOT::UNKNOWN", address(0));
                botState.creditAccount = creditAccount;
                try IBot(bot).requiredPermissions() returns (uint192 requiredPermissions) {
                    botState.requiredPermissions = requiredPermissions;
                } catch {}
                botStates[num++] = botState;
            }
        }
        assembly {
            mstore(bots, num)
        }
    }
}

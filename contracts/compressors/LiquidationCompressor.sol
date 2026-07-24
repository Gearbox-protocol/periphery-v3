// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {BitMask} from "@gearbox-protocol/core-v3/contracts/libraries/BitMask.sol";
import {OptionalCall} from "@gearbox-protocol/core-v3/contracts/libraries/OptionalCall.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

import {BaseCompressor} from "./BaseCompressor.sol";
import {ILiquidationSubcompressor} from "../interfaces/ILiquidationSubcompressor.sol";
import {ILiquidationCompressor} from "../interfaces/ILiquidationCompressor.sol";
import {LiquidationData, LiquidationOutput} from "../types/LiquidationInfo.sol";

import {AP_LIQUIDATION_COMPRESSOR} from "../libraries/Literals.sol";

struct VersionInfo {
    uint256 latest;
    mapping(uint256 majorVersion => uint256) latestByMajor;
    mapping(uint256 minorVersion => uint256) latestByMinor;
    EnumerableSet.UintSet versionsSet;
}

contract LiquidationCompressor is BaseCompressor, Ownable, ILiquidationCompressor {
    using BitMask for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint256 public constant version = 3_13;
    bytes32 public constant contractType = AP_LIQUIDATION_COMPRESSOR;

    mapping(bytes32 cType => VersionInfo) internal compressorVersionInfo;
    EnumerableSet.Bytes32Set internal compressorTypesSet;

    mapping(bytes32 => bytes32) public liquidatableTypeToCompressorType;

    mapping(bytes32 => mapping(uint256 => uint256)) public liquidatableTypeToSpecificCompressorVersion;

    mapping(bytes32 => mapping(uint256 => address)) public compressorTypeToCompressor;

    constructor(address _owner, address addressProvider_) BaseCompressor(addressProvider_) {
        _transferOwnership(_owner);
    }

    /// @notice Returns liquidation preview data for the credit account's withdrawal token (at most one).
    ///         If none is found, returns a standard CreditFacade liquidation path for all enabled collateral.
    function getLiquidationData(address liquidator, address creditAccount)
        external
        view
        returns (LiquidationData memory)
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        uint256 collateralTokensCount = ICreditManagerV3(creditManager).collateralTokensCount();

        for (uint256 i = 0; i < collateralTokensCount; i++) {
            address token = ICreditManagerV3(creditManager).getTokenByMask(1 << i);
            address compressor = _getCompressorForToken(token);

            if (compressor == address(0)) {
                continue;
            }

            return ILiquidationSubcompressor(compressor).getLiquidationData(liquidator, creditAccount, token);
        }

        return _getStandardLiquidationData(liquidator, creditAccount, creditManager);
    }

    /// @dev Standard liquidation: repay `totalValue * liquidationDiscount` in underlying and withdraw all
    ///      enabled collateral tokens to the liquidator via a single CreditFacade.liquidateCreditAccount call.
    function _getStandardLiquidationData(address liquidator, address creditAccount, address creditManager)
        internal
        view
        returns (LiquidationData memory data)
    {
        uint256 enabledTokensMask;
        {
            CollateralDebtData memory cdd = ICreditManagerV3(creditManager)
                .calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
            (,, uint16 liquidationDiscount,,) = ICreditManagerV3(creditManager).fees();

            data.requiredUnderlyingAmount = cdd.totalValue * liquidationDiscount / PERCENTAGE_FACTOR;
            enabledTokensMask = cdd.enabledTokensMask;
        }

        data.isLiquidatorEligible = true;
        data.kycProtocol = "";
        data.kycToken = address(0);

        (data.expectedOutputs, data.liquidationCall) = _buildStandardLiquidationCall(
            liquidator, creditAccount, creditManager, enabledTokensMask, data.requiredUnderlyingAmount
        );
    }

    function _buildStandardLiquidationCall(
        address liquidator,
        address creditAccount,
        address creditManager,
        uint256 enabledTokensMask,
        uint256 requiredUnderlyingAmount
    ) internal view returns (LiquidationOutput[] memory expectedOutputs, MultiCall memory liquidationCall) {
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        uint256 numTokens = enabledTokensMask.calcEnabledTokens();

        expectedOutputs = new LiquidationOutput[](numTokens);
        MultiCall[] memory calls = new MultiCall[](numTokens + 1);

        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.addCollateral,
                (ICreditManagerV3(creditManager).underlying(), requiredUnderlyingAmount)
            )
        });

        for (uint256 i; i < numTokens; ++i) {
            (expectedOutputs[i], calls[i + 1], enabledTokensMask) = _nextEnabledTokenCall({
                creditFacade: creditFacade,
                creditManager: creditManager,
                creditAccount: creditAccount,
                liquidator: liquidator,
                enabledTokensMask: enabledTokensMask
            });
        }

        liquidationCall = MultiCall({
            target: creditFacade,
            callData: abi.encodeWithSignature(
                "liquidateCreditAccount(address,address,(address,bytes)[])", creditAccount, liquidator, calls
            )
        });
    }

    function _nextEnabledTokenCall(
        address creditFacade,
        address creditManager,
        address creditAccount,
        address liquidator,
        uint256 enabledTokensMask
    )
        internal
        view
        returns (LiquidationOutput memory output, MultiCall memory call, uint256 remainingMask)
    {
        uint256 tokenMask = enabledTokensMask.lsbMask();
        address token = ICreditManagerV3(creditManager).getTokenByMask(tokenMask);
        uint256 amount = IERC20(token).balanceOf(creditAccount);

        output = LiquidationOutput({
            token: token,
            amount: amount,
            delayed: false,
            redeemerAddress: address(0),
            claimableAt: 0
        });
        call = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, amount, liquidator))
        });
        remainingMask = enabledTokensMask.disable(tokenMask);
    }

    function setSubcompressor(address subcompressor) external onlyOwner {
        bytes32 cType = IVersion(subcompressor).contractType();
        uint256 ver = IVersion(subcompressor).version();

        compressorTypeToCompressor[cType][ver] = subcompressor;

        VersionInfo storage info = compressorVersionInfo[cType];
        if (ver > info.latest) info.latest = ver;
        uint256 majorVersion = _getMajorVersion(ver);
        if (ver > info.latestByMajor[majorVersion]) info.latestByMajor[majorVersion] = ver;
        uint256 minorVersion = _getMinorVersion(ver);
        if (ver > info.latestByMinor[minorVersion]) info.latestByMinor[minorVersion] = ver;
        info.versionsSet.add(ver);
        compressorTypesSet.add(cType);
    }

    function setLiquidatableTypeToCompressorType(bytes32 liquidatableType, bytes32 compressorType)
        external
        onlyOwner
    {
        liquidatableTypeToCompressorType[liquidatableType] = compressorType;
    }

    function setLiquidatableVersionToSpecificCompressorVersion(
        bytes32 liquidatableType,
        uint256 liquidatableVersion,
        uint256 compressorVersion
    ) external onlyOwner {
        liquidatableTypeToSpecificCompressorVersion[liquidatableType][liquidatableVersion] = compressorVersion;
    }

    function _getCompressorForToken(address token) internal view returns (address) {
        (bytes32 cType, uint256 cVersion) = _getContractTypeAndVersion(token);
        bytes32 compressorType = liquidatableTypeToCompressorType[cType];
        uint256 specificVersion = liquidatableTypeToSpecificCompressorVersion[cType][cVersion];
        if (specificVersion != 0) {
            return compressorTypeToCompressor[compressorType][specificVersion];
        } else {
            uint256 minorVersion = _getMinorVersion(cVersion);
            return compressorTypeToCompressor[compressorType][_getLatestPatchVersion(compressorType, minorVersion)];
        }
    }

    function _getLatestPatchVersion(bytes32 cType, uint256 minorVersion) internal view returns (uint256 ver) {
        ver = compressorVersionInfo[cType].latestByMinor[_getMinorVersion(minorVersion)];
    }

    function _getMajorVersion(uint256 ver) internal pure returns (uint256) {
        return ver - ver % 100;
    }

    function _getMinorVersion(uint256 ver) internal pure returns (uint256) {
        return ver - ver % 10;
    }

    function _getContractTypeAndVersion(address phantomToken) internal view returns (bytes32 cType, uint256 cVersion) {
        (bool success, bytes memory result) =
            OptionalCall.staticCallOptionalSafe(phantomToken, abi.encodeCall(IVersion.contractType, ()), 100_000);

        if (success) {
            cType = abi.decode(result, (bytes32));
        } else {
            cType = bytes32(0);
        }

        (success, result) =
            OptionalCall.staticCallOptionalSafe(phantomToken, abi.encodeCall(IVersion.version, ()), 100_000);
        if (success) {
            cVersion = abi.decode(result, (uint256));
        } else {
            cVersion = 0;
        }

        return (cType, cVersion);
    }
}

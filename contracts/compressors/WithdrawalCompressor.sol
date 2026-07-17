// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionalCall} from "@gearbox-protocol/core-v3/contracts/libraries/OptionalCall.sol";

import {BaseCompressor} from "./BaseCompressor.sol";
import {IWithdrawalSubcompressor} from "../interfaces/IWithdrawalSubcompressor.sol";
import {IWithdrawalCompressor} from "../interfaces/IWithdrawalCompressor.sol";
import {
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal,
    WithdrawalStatus
} from "../types/WithdrawalInfo.sol";
import {WithdrawalLib} from "../types/WithdrawalInfo.sol";

import {AP_WITHDRAWAL_COMPRESSOR} from "../libraries/Literals.sol";

struct VersionInfo {
    uint256 latest;
    mapping(uint256 majorVersion => uint256) latestByMajor;
    mapping(uint256 minorVersion => uint256) latestByMinor;
    EnumerableSet.UintSet versionsSet;
}

contract WithdrawalCompressor is BaseCompressor, Ownable {
    using WithdrawalLib for WithdrawableAsset[];
    using WithdrawalLib for RequestableWithdrawal[];
    using WithdrawalLib for ClaimableWithdrawal[];
    using WithdrawalLib for PendingWithdrawal[];
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint256 public constant version = 3_13;
    bytes32 public constant contractType = AP_WITHDRAWAL_COMPRESSOR;

    mapping(bytes32 cType => VersionInfo) internal compressorVersionInfo;
    EnumerableSet.Bytes32Set internal compressorTypesSet;

    mapping(bytes32 => bytes32) public withdrawableTypeToCompressorType;

    mapping(bytes32 => mapping(uint256 => uint256)) public withdrawableTypeToSpecificCompressorVersion;

    mapping(bytes32 => mapping(uint256 => address)) public compressorTypeToCompressor;

    constructor(address _owner, address addressProvider_) BaseCompressor(addressProvider_) {
        _transferOwnership(_owner);
    }

    function getWithdrawableAssets(address creditManager) public view returns (WithdrawableAsset[] memory) {
        uint256 collateralTokensCount = ICreditManagerV3(creditManager).collateralTokensCount();

        WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](0);

        for (uint256 i = 0; i < collateralTokensCount; i++) {
            address token = ICreditManagerV3(creditManager).getTokenByMask(1 << i);
            address compressor = _getCompressorForToken(token);

            if (compressor == address(0)) {
                continue;
            }

            WithdrawableAsset[] memory assets =
                IWithdrawalSubcompressor(compressor).getWithdrawableAssets(creditManager, token);
            withdrawableAssets = withdrawableAssets.concat(assets);
        }

        return withdrawableAssets;
    }

    function getCurrentWithdrawals(address creditAccount)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        uint256 collateralTokensCount = ICreditManagerV3(creditManager).collateralTokensCount();

        ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](0);
        PendingWithdrawal[] memory pendingWithdrawals = new PendingWithdrawal[](0);

        for (uint256 i = 0; i < collateralTokensCount; i++) {
            address token = ICreditManagerV3(creditManager).getTokenByMask(1 << i);
            address compressor = _getCompressorForToken(token);

            if (compressor == address(0) || IERC20(token).balanceOf(creditAccount) <= 1) {
                continue;
            }

            (ClaimableWithdrawal[] memory cwCurrent, PendingWithdrawal[] memory pwCurrent) =
                IWithdrawalSubcompressor(compressor).getCurrentWithdrawals(creditAccount, token);

            claimableWithdrawals = claimableWithdrawals.concat(cwCurrent);
            pendingWithdrawals = pendingWithdrawals.concat(pwCurrent);
        }

        return (claimableWithdrawals.filterEmpty(), pendingWithdrawals.filterEmpty());
    }

    function getExternalAccountCurrentWithdrawals(address withdrawalToken, address account)
        external
        view
        returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
    {
        address compressor = _getCompressorForToken(withdrawalToken);
        if (compressor == address(0)) {
            return (new ClaimableWithdrawal[](0), new PendingWithdrawal[](0));
        }

        return IWithdrawalSubcompressor(compressor).getExternalAccountCurrentWithdrawals(account, withdrawalToken);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory withdrawal)
    {
        return _getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount, new bytes(0));
    }

    function getWithdrawalRequestResult(
        address creditAccount,
        address token,
        address withdrawalToken,
        uint256 amount,
        bytes calldata extraData
    ) external view returns (RequestableWithdrawal memory withdrawal) {
        return _getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount, extraData);
    }

    function getWithdrawalRequestResult(address creditAccount, address token, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory withdrawal)
    {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address withdrawalToken = _getWithdrawalTokenForToken(creditManager, token);
        return _getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount, new bytes(0));
    }

    function _getWithdrawalRequestResult(
        address creditAccount,
        address token,
        address withdrawalToken,
        uint256 amount,
        bytes memory extraData
    ) internal view returns (RequestableWithdrawal memory withdrawal) {
        uint256 balance = IERC20(token).balanceOf(creditAccount);

        if (balance < amount) {
            amount = balance;
        }

        address compressor = _getCompressorForToken(withdrawalToken);

        if (compressor != address(0)) {
            withdrawal = IWithdrawalSubcompressor(compressor)
                .getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount, extraData);
        }

        return withdrawal;
    }

    function setSubcompressor(address subcompressor) external onlyOwner {
        bytes32 cType = IVersion(subcompressor).contractType();
        uint256 ver = IVersion(subcompressor).version();

        compressorTypeToCompressor[IVersion(subcompressor).contractType()][IVersion(subcompressor).version()] =
        subcompressor;

        VersionInfo storage info = compressorVersionInfo[cType];
        if (ver > info.latest) info.latest = ver;
        uint256 majorVersion = _getMajorVersion(ver);
        if (ver > info.latestByMajor[majorVersion]) info.latestByMajor[majorVersion] = ver;
        uint256 minorVersion = _getMinorVersion(ver);
        if (ver > info.latestByMinor[minorVersion]) info.latestByMinor[minorVersion] = ver;
        info.versionsSet.add(ver);
        compressorTypesSet.add(cType);
    }

    function getWithdrawalStatus(address[] memory redeemers) external view returns (WithdrawalStatus[] memory) {
        WithdrawalStatus[] memory statuses = new WithdrawalStatus[](redeemers.length);
        for (uint256 i = 0; i < redeemers.length; i++) {
            statuses[i] = getWithdrawalStatus(redeemers[i]);
        }
        return statuses;
    }

    function getWithdrawalStatus(address redeemer) public view returns (WithdrawalStatus) {
        (bool success, bytes memory result) =
            OptionalCall.staticCallOptionalSafe(redeemer, abi.encodeWithSignature("gateway()"), 100_000);
        if (!success || result.length != 32) return WithdrawalStatus.NULL;
        address gateway = abi.decode(result, (address));

        (success, result) =
            OptionalCall.staticCallOptionalSafe(gateway, abi.encodeWithSignature("phantomToken()"), 100_000);
        if (!success || result.length != 32) return WithdrawalStatus.NULL;
        address phantomToken = abi.decode(result, (address));

        address compressor = _getCompressorForToken(phantomToken);
        if (compressor == address(0)) return WithdrawalStatus.NULL;

        return IWithdrawalSubcompressor(compressor).getWithdrawalStatus(redeemer);
    }

    function setWithdrawableTypeToCompressorType(bytes32 withdrawableType, bytes32 compressorType) external onlyOwner {
        withdrawableTypeToCompressorType[withdrawableType] = compressorType;
    }

    function setWithdrawableVersionToSpecificCompressorVersion(
        bytes32 withdrawableType,
        uint256 withdrawableVersion,
        uint256 compressorVersion
    ) external onlyOwner {
        withdrawableTypeToSpecificCompressorVersion[withdrawableType][withdrawableVersion] = compressorVersion;
    }

    function _getWithdrawalTokenForToken(address creditManager, address token) internal view returns (address) {
        WithdrawableAsset[] memory withdrawableAssets = getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            if (withdrawableAssets[i].token == token) {
                return withdrawableAssets[i].withdrawalPhantomToken;
            }
        }

        return address(0);
    }

    function _getCompressorForToken(address token) internal view returns (address) {
        (bytes32 cType, uint256 cVersion) = _getContractTypeAndVersion(token);
        bytes32 compressorType = withdrawableTypeToCompressorType[cType];
        uint256 specificVersion = withdrawableTypeToSpecificCompressorVersion[cType][cVersion];
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

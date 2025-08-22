// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseCompressor} from "./BaseCompressor.sol";
import {IWithdrawalSubcompressor} from "../interfaces/IWithdrawalSubcompressor.sol";
import {IWithdrawalCompressor} from "../interfaces/IWithdrawalCompressor.sol";
import {
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../types/WithdrawalInfo.sol";
import {WithdrawalLib} from "../types/WithdrawalInfo.sol";

import {AP_WITHDRAWAL_COMPRESSOR} from "../libraries/Literals.sol";

contract WithdrawalCompressor is BaseCompressor, Ownable {
    using WithdrawalLib for WithdrawableAsset[];
    using WithdrawalLib for RequestableWithdrawal[];
    using WithdrawalLib for ClaimableWithdrawal[];
    using WithdrawalLib for PendingWithdrawal[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = AP_WITHDRAWAL_COMPRESSOR;

    mapping(bytes32 => bytes32) public withdrawableTypeToCompressorType;

    mapping(bytes32 => address) public compressorTypeToCompressor;

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

    function getWithdrawalRequestResult(address creditAccount, address token, uint256 amount)
        external
        view
        returns (RequestableWithdrawal memory withdrawal)
    {
        uint256 balance = IERC20(token).balanceOf(creditAccount);

        if (balance < amount) {
            amount = balance;
        }

        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        address withdrawalToken = _getWithdrawalTokenForToken(creditManager, token);

        address compressor = _getCompressorForToken(withdrawalToken);

        if (compressor != address(0)) {
            withdrawal = IWithdrawalSubcompressor(compressor).getWithdrawalRequestResult(
                creditAccount, token, withdrawalToken, amount
            );
        }

        return withdrawal;
    }

    function setSubcompressor(address subcompressor) external onlyOwner {
        compressorTypeToCompressor[IVersion(subcompressor).contractType()] = subcompressor;
    }

    function setWithdrawableTypeToCompressorType(bytes32 withdrawableType, bytes32 compressorType) external onlyOwner {
        withdrawableTypeToCompressorType[withdrawableType] = compressorType;
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
        return compressorTypeToCompressor[withdrawableTypeToCompressorType[_getContractType(token)]];
    }

    function _getContractType(address phantomToken) internal view returns (bytes32) {
        try IVersion(phantomToken).contractType() returns (bytes32 cType) {
            return cType;
        } catch {
            return bytes32(0);
        }
    }
}

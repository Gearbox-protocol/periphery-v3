// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";
import {CreditLogic} from "@gearbox-protocol/core-v3/contracts/libraries/CreditLogic.sol";
import {SanityCheckTrait} from "@gearbox-protocol/core-v3/contracts/traits/SanityCheckTrait.sol";

import {IMarketConfigurator} from "@gearbox-protocol/permissionless/contracts/interfaces/IMarketConfigurator.sol";
import {IContractsRegister} from "@gearbox-protocol/permissionless/contracts/interfaces/IContractsRegister.sol";

struct SeizedCollateral {
    address[] tokensToSeize;
    uint256[] amountsToSeize;
}

struct ExtraParams {
    MultiCall[] calls;
    bytes lossPolicyData;
    address wrappedUnderlying;
}

/**
 * @title TreasuryLiquidator
 * @notice This contract allows the treasury to liquidate credit accounts by providing the funds
 * needed for liquidation and receiving the seized collateral. The treasury can set exchange rates
 * for different token pairs, as well as approve liquidators to use this contract.
 */
contract TreasuryLiquidator is SanityCheckTrait {
    using SafeERC20 for IERC20;
    using CreditLogic for CollateralDebtData;

    /// @notice Contract type for identification
    bytes32 public constant contractType = "TREASURY_LIQUIDATOR";

    /// @notice Contract version
    uint256 public constant version = 3_10;

    /// @notice Precision for exchange rates
    uint256 public constant RATE_PRECISION = 1e18;

    /// @notice The treasury address that funds are taken from and returned to
    address public immutable treasury;

    /// @notice The market configurator address
    address public immutable marketConfigurator;

    /// @notice Mapping of approved liquidators who can use this contract
    mapping(address => bool) public isLiquidator;

    /// @notice Mapping of minimum exchange rates (assetIn => assetOut => rate)
    /// Rate is in RATE_PRECISION format, e.g., 1e18 means 1:1
    mapping(address => mapping(address => uint256)) public minExchangeRates;

    // EVENTS
    event LiquidateFromTreasury(
        address indexed creditFacade, address indexed creditAccount, address indexed liquidator
    );
    event LiquidateMultipleFromTreasury(
        address indexed creditFacade, address indexed creditAccount, address indexed liquidator
    );
    event PartiallyLiquidateFromTreasury(
        address indexed creditFacade, address indexed creditAccount, address indexed liquidator
    );
    event SetLiquidatorStatus(address indexed liquidator, bool status);
    event SetMinExchangeRate(address indexed assetIn, address indexed assetOut, uint256 rate);

    // ERRORS
    error CallerNotTreasuryException();
    error CallerNotApprovedLiquidatorException();
    error InsufficientExchangeRateException(uint256 received, uint256 expected);
    error InsufficientTreasuryFundsException();
    error UnsupportedTokenPairException();
    error InvalidWithdrawalException();
    error InvalidCreditSuiteException();

    /// @notice Modifier to verify the sender is the treasury
    modifier onlyTreasury() {
        if (msg.sender != treasury) revert CallerNotTreasuryException();
        _;
    }

    /// @notice Modifier to verify the sender is an approved liquidator
    modifier onlyLiquidator() {
        if (!isLiquidator[msg.sender]) revert CallerNotApprovedLiquidatorException();
        _;
    }

    /// @notice Modifier to verify the credit facade is from the market configurator
    modifier onlyCFFromMarketConfigurator(address creditFacade) {
        address creditManager = ICreditFacadeV3(creditFacade).creditManager();
        bool isValidCM = IContractsRegister(IMarketConfigurator(marketConfigurator).contractsRegister()).isCreditManager(
            creditManager
        );
        if (!isValidCM || ICreditManagerV3(creditManager).creditFacade() != creditFacade) {
            revert InvalidCreditSuiteException();
        }
        _;
    }

    /**
     * @notice Constructor
     * @param _treasury The address of the treasury
     */
    constructor(address _treasury, address _marketConfigurator)
        nonZeroAddress(_treasury)
        nonZeroAddress(_marketConfigurator)
    {
        treasury = _treasury;
        marketConfigurator = _marketConfigurator;
    }

    /**
     * @notice Set liquidator status
     * @param liquidator The address to set status for
     * @param status True to approve, false to revoke
     */
    function setLiquidatorStatus(address liquidator, bool status) external onlyTreasury nonZeroAddress(liquidator) {
        if (isLiquidator[liquidator] == status) return;
        isLiquidator[liquidator] = status;
        emit SetLiquidatorStatus(liquidator, status);
    }

    /**
     * @notice Set minimum exchange rate between two assets
     * @param assetIn The asset being provided for liquidation
     * @param assetOut The asset expected to be received from liquidation
     * @param rate The minimum exchange rate (RATE_PRECISION format)
     */
    function setMinExchangeRate(address assetIn, address assetOut, uint256 rate)
        external
        onlyTreasury
        nonZeroAddress(assetIn)
        nonZeroAddress(assetOut)
    {
        if (minExchangeRates[assetIn][assetOut] == rate) return;

        minExchangeRates[assetIn][assetOut] = rate;
        emit SetMinExchangeRate(assetIn, assetOut, rate);
    }

    /**
     * @notice Liquidate a credit account using funds from the treasury
     * @param creditFacade The credit facade contract
     * @param creditAccount The credit account to liquidate
     * @param extraParams Additional parameters for the liquidation
     */
    function liquidateFromTreasurySingleAsset(
        address creditFacade,
        address creditAccount,
        address tokenToSeize,
        ExtraParams calldata extraParams
    ) external onlyLiquidator onlyCFFromMarketConfigurator(creditFacade) {
        _validateCalls(extraParams.calls);

        address underlying = ICreditFacadeV3(creditFacade).underlying();

        uint256 requiredRate = minExchangeRates[underlying][tokenToSeize];
        if (requiredRate == 0) revert UnsupportedTokenPairException();

        uint256 totalDebt;

        {
            address creditManager = ICreditFacadeV3(creditFacade).creditManager();
            CollateralDebtData memory cdd =
                ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_ONLY);
            totalDebt = cdd.calcTotalDebt();

            _transferUnderlying(underlying, extraParams.wrappedUnderlying, totalDebt);
            IERC20(underlying).forceApprove(creditManager, totalDebt);
        }

        MultiCall[] memory finalCalls = new MultiCall[](2);
        finalCalls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, totalDebt))
        });
        finalCalls[1] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral,
                (tokenToSeize, totalDebt * requiredRate / RATE_PRECISION, treasury)
            )
        });

        finalCalls = _concatCalls(extraParams.calls, finalCalls);

        ICreditFacadeV3(creditFacade).liquidateCreditAccount(
            creditAccount, treasury, finalCalls, extraParams.lossPolicyData
        );

        emit LiquidateFromTreasury(creditFacade, creditAccount, msg.sender);
    }

    /**
     * @notice Liquidate a credit account using funds from the treasury
     * @param creditFacade The credit facade contract
     * @param creditAccount The credit account to liquidate
     * @param seizedCollateral The tokens to seize
     * @param extraParams Additional parameters for the liquidation
     */
    function liquidateFromTreasuryMultiAsset(
        address creditFacade,
        address creditAccount,
        SeizedCollateral calldata seizedCollateral,
        ExtraParams calldata extraParams
    ) external onlyLiquidator onlyCFFromMarketConfigurator(creditFacade) {
        _validateCalls(extraParams.calls);

        address underlying = ICreditFacadeV3(creditFacade).underlying();

        uint256 underlyingOut = _computeUnderlyingOut(underlying, seizedCollateral);

        _transferUnderlying(underlying, extraParams.wrappedUnderlying, underlyingOut);

        {
            address creditManager = ICreditFacadeV3(creditFacade).creditManager();
            IERC20(underlying).forceApprove(creditManager, underlyingOut);
        }

        MultiCall[] memory finalCalls =
            _generateMultiAssetCalls(creditFacade, underlying, underlyingOut, seizedCollateral);
        finalCalls = _concatCalls(extraParams.calls, finalCalls);

        ICreditFacadeV3(creditFacade).liquidateCreditAccount(
            creditAccount, treasury, finalCalls, extraParams.lossPolicyData
        );

        emit LiquidateMultipleFromTreasury(creditFacade, creditAccount, msg.sender);
    }

    /**
     * @notice Partially liquidate a credit account using funds from the treasury
     * @param creditFacade The credit facade contract
     * @param creditAccount The credit account to partially liquidate
     * @param token The collateral token to seize
     * @param repaidAmount The amount of underlying to repay
     * @param priceUpdates Optional price updates to apply before liquidation
     */
    function partiallyLiquidateFromTreasury(
        address creditFacade,
        address creditAccount,
        address token,
        uint256 repaidAmount,
        PriceUpdate[] calldata priceUpdates,
        address wrappedUnderlying
    ) external onlyLiquidator onlyCFFromMarketConfigurator(creditFacade) {
        address underlying = ICreditFacadeV3(creditFacade).underlying();

        uint256 requiredRate = minExchangeRates[underlying][token];
        if (requiredRate == 0) revert UnsupportedTokenPairException();

        uint256 minSeizedAmount = repaidAmount * requiredRate / RATE_PRECISION;

        _transferUnderlying(underlying, wrappedUnderlying, repaidAmount);
        {
            address creditManager = ICreditFacadeV3(creditFacade).creditManager();
            IERC20(underlying).forceApprove(creditManager, repaidAmount);
        }

        ICreditFacadeV3(creditFacade).partiallyLiquidateCreditAccount(
            creditAccount, token, repaidAmount, minSeizedAmount, treasury, priceUpdates
        );

        emit PartiallyLiquidateFromTreasury(creditFacade, creditAccount, msg.sender);
    }

    function _transferUnderlying(address underlying, address wrappedUnderlying, uint256 amount) internal {
        uint256 balance = IERC20(underlying).balanceOf(treasury);
        uint256 wrappedAssets;

        if (wrappedUnderlying != address(0)) {
            wrappedAssets = IERC4626(wrappedUnderlying).maxWithdraw(treasury);
        }

        if (balance >= amount) {
            IERC20(underlying).safeTransferFrom(treasury, address(this), amount);
        } else if (balance + wrappedAssets >= amount) {
            IERC20(underlying).safeTransferFrom(treasury, address(this), balance);
            IERC4626(wrappedUnderlying).withdraw(amount - balance, address(this), treasury);
        } else {
            revert InsufficientTreasuryFundsException();
        }
    }

    function _computeUnderlyingOut(address underlying, SeizedCollateral calldata seizedCollateral)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 len = seizedCollateral.tokensToSeize.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 requiredRate = minExchangeRates[underlying][seizedCollateral.tokensToSeize[i]];
            if (requiredRate == 0) revert UnsupportedTokenPairException();
            amountOut += seizedCollateral.amountsToSeize[i] * RATE_PRECISION / requiredRate;
        }
    }

    function _generateMultiAssetCalls(
        address creditFacade,
        address underlying,
        uint256 underlyingOut,
        SeizedCollateral calldata seizedCollateral
    ) internal view returns (MultiCall[] memory calls) {
        calls = new MultiCall[](1 + seizedCollateral.tokensToSeize.length);
        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, underlyingOut))
        });
        uint256 len = seizedCollateral.tokensToSeize.length;
        for (uint256 i = 0; i < len; ++i) {
            calls[1 + i] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.withdrawCollateral,
                    (seizedCollateral.tokensToSeize[i], seizedCollateral.amountsToSeize[i], treasury)
                )
            });
        }
    }

    function _concatCalls(MultiCall[] memory calls0, MultiCall[] memory calls1)
        internal
        pure
        returns (MultiCall[] memory)
    {
        uint256 len0 = calls0.length;
        uint256 len1 = calls1.length;

        if (len0 == 0) return calls1;
        if (len1 == 0) return calls0;

        MultiCall[] memory calls = new MultiCall[](len0 + len1);
        for (uint256 i = 0; i < len0; ++i) {
            calls[i] = calls0[i];
        }
        for (uint256 i = 0; i < len1; ++i) {
            calls[len0 + i] = calls1[i];
        }
        return calls;
    }

    function _validateCalls(MultiCall[] calldata calls) internal view {
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes4 selector = bytes4(calls[i].callData);
            if (selector == ICreditFacadeV3Multicall.withdrawCollateral.selector) {
                (,, address to) = abi.decode(calls[i].callData[4:], (address, uint256, address));
                if (to != treasury) revert InvalidWithdrawalException();
            }
        }
    }
}

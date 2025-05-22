// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

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
    bytes32 public constant contractType = "HELPER::TREASURY_LIQUIDATOR";

    /// @notice Contract version
    uint256 public constant version = 3_10;

    /// @notice Precision for exchange rates
    uint256 public constant RATE_PRECISION = 1e18;

    /// @notice The treasury address that funds are taken from and returned to
    address public immutable treasury;

    /// @notice Mapping of approved liquidators who can use this contract
    mapping(address => bool) public isLiquidator;

    /// @notice Mapping of minimum exchange rates (assetIn => assetOut => rate)
    /// Rate is in RATE_PRECISION format, e.g., 1e18 means 1:1
    mapping(address => mapping(address => uint256)) public minExchangeRates;

    // EVENTS
    event LiquidateFromTreasury(
        address indexed creditFacade, address indexed creditAccount, address indexed liquidator, address tokenOut
    );
    event LiquidateMultipleFromTreasury(
        address indexed creditFacade, address indexed creditAccount, address indexed liquidator, address[] tokensOut
    );
    event PartiallyLiquidateFromTreasury(
        address indexed creditFacade, address indexed creditAccount, address indexed liquidator, address token
    );
    event SetLiquidatorStatus(address indexed liquidator, bool status);
    event SetMinExchangeRate(address indexed assetIn, address indexed assetOut, uint256 rate);

    // ERRORS
    error CallerNotTreasuryException();
    error CallerNotApprovedLiquidatorException();
    error InsufficientExchangeRateException(uint256 received, uint256 expected);
    error UnsupportedTokenPairException();
    error InvalidWithdrawalException();

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

    /**
     * @notice Constructor
     * @param _treasury The address of the treasury
     */
    constructor(address _treasury) nonZeroAddress(_treasury) {
        treasury = _treasury;
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
     * @param tokenToSeize The token to receive from liquidation
     * @param calls Additional calls to be executed before swaps with treasury. Any
     *              withdrawals can be sent to treasury only.
     * @param lossPolicyData Additional data for the loss policy
     */
    function liquidateFromTreasurySingleAsset(
        address creditFacade,
        address creditAccount,
        address tokenToSeize,
        MultiCall[] calldata calls,
        bytes calldata lossPolicyData
    ) external onlyLiquidator {
        _validateCalls(calls);

        address underlying = ICreditFacadeV3(creditFacade).underlying();

        uint256 requiredRate = minExchangeRates[underlying][tokenToSeize];
        if (requiredRate == 0) revert UnsupportedTokenPairException();

        address creditManager = ICreditFacadeV3(creditFacade).creditManager();
        CollateralDebtData memory cdd = _getCDD(creditAccount, creditManager);
        uint256 totalDebt = cdd.calcTotalDebt();

        IERC20(underlying).safeTransferFrom(treasury, address(this), totalDebt);
        IERC20(underlying).forceApprove(creditManager, totalDebt);

        MultiCall[] memory finalCalls = new MultiCall[](2);
        finalCalls[0] = MultiCall({
            target: creditManager,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, totalDebt))
        });
        finalCalls[1] = MultiCall({
            target: creditManager,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral,
                (tokenToSeize, totalDebt * requiredRate / RATE_PRECISION, treasury)
            )
        });

        finalCalls = _concatCalls(calls, finalCalls);

        ICreditFacadeV3(creditFacade).liquidateCreditAccount(creditAccount, treasury, finalCalls, lossPolicyData);

        emit LiquidateFromTreasury(creditFacade, creditAccount, msg.sender, tokenToSeize);
    }

    /**
     * @notice Liquidate a credit account using funds from the treasury
     * @param creditFacade The credit facade contract
     * @param creditAccount The credit account to liquidate
     * @param tokensToSeize The tokens to receive from liquidation
     * @param amountsToSeize The amounts of tokens to receive from liquidation
     * @param calls Additional calls to be executed before swaps with treasury. Any
     *              withdrawals can be sent to treasury only.
     * @param lossPolicyData Additional data for the loss policy
     */
    function liquidateFromTreasuryMultiAsset(
        address creditFacade,
        address creditAccount,
        address[] calldata tokensToSeize,
        uint256[] calldata amountsToSeize,
        MultiCall[] calldata calls,
        bytes calldata lossPolicyData
    ) external onlyLiquidator {
        _validateCalls(calls);

        address underlying = ICreditFacadeV3(creditFacade).underlying();

        address creditManager = ICreditFacadeV3(creditFacade).creditManager();

        uint256 underlyingOut = _computeUnderlyingOut(underlying, tokensToSeize, amountsToSeize);

        IERC20(underlying).safeTransferFrom(treasury, address(this), underlyingOut);
        IERC20(underlying).forceApprove(creditManager, underlyingOut);

        MultiCall[] memory finalCalls = new MultiCall[](1 + tokensToSeize.length);
        finalCalls[0] = MultiCall({
            target: creditManager,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (underlying, underlyingOut))
        });
        for (uint256 i = 0; i < tokensToSeize.length; ++i) {
            finalCalls[1 + i] = MultiCall({
                target: creditManager,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.withdrawCollateral, (tokensToSeize[i], amountsToSeize[i], treasury)
                )
            });
        }

        finalCalls = _concatCalls(calls, finalCalls);

        ICreditFacadeV3(creditFacade).liquidateCreditAccount(creditAccount, treasury, finalCalls, lossPolicyData);

        emit LiquidateMultipleFromTreasury(creditFacade, creditAccount, msg.sender, tokensToSeize);
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
        PriceUpdate[] calldata priceUpdates
    ) external onlyLiquidator {
        address underlying = ICreditFacadeV3(creditFacade).underlying();

        uint256 requiredRate = minExchangeRates[underlying][token];
        if (requiredRate == 0) revert UnsupportedTokenPairException();

        uint256 minSeizedAmount = repaidAmount * requiredRate / RATE_PRECISION;

        IERC20(underlying).safeTransferFrom(treasury, address(this), repaidAmount);
        address creditManager = ICreditFacadeV3(creditFacade).creditManager();
        IERC20(underlying).forceApprove(creditManager, repaidAmount);

        ICreditFacadeV3(creditFacade).partiallyLiquidateCreditAccount(
            creditAccount, token, repaidAmount, minSeizedAmount, treasury, priceUpdates
        );

        emit PartiallyLiquidateFromTreasury(creditFacade, creditAccount, msg.sender, token);
    }

    function _getCDD(address creditAccount, address creditManager)
        internal
        view
        virtual
        returns (CollateralDebtData memory)
    {
        return ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
    }

    function _computeUnderlyingOut(address underlying, address[] memory tokensToSeize, uint256[] memory amountsToSeize)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 len = tokensToSeize.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 requiredRate = minExchangeRates[underlying][tokensToSeize[i]];
            if (requiredRate == 0) revert UnsupportedTokenPairException();
            amountOut += amountsToSeize[i] * RATE_PRECISION / requiredRate;
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

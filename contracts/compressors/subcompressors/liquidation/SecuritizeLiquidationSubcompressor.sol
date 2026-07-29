// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundaiton, 2025.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {CreditLogic} from "@gearbox-protocol/core-v3/contracts/libraries/CreditLogic.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

import {
    IERC4626Adapter
} from "@gearbox-protocol/integrations-v3/contracts/integrations/erc4626/interfaces/IERC4626Adapter.sol";
import {
    SecuritizeRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/SecuritizeRedemptionPhantomToken.sol";
import {
    SecuritizeRedeemer
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/SecuritizeRedeemer.sol";
import {
    ISecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/interfaces/ISecuritizeRedemptionGateway.sol";
import {
    ISecuritizeRedemptionGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/interfaces/ISecuritizeRedemptionGatewayAdapter.sol";
import {
    ISecuritizeLiquidator
} from "@gearbox-protocol/integrations-v3/contracts/integrations/securitize/interfaces/ISecuritizeLiquidator.sol";

import {ILiquidationSubcompressor} from "../../../interfaces/ILiquidationSubcompressor.sol";
import {LiquidationData, LiquidationLib, LiquidationOutput} from "../../../types/LiquidationInfo.sol";
import {LiquidationPriceUpdates} from "../../../libraries/LiquidationPriceUpdates.sol";

/// @title Securitize liquidation subcompressor
/// @notice Builds liquidation preview data for Securitize redemption phantom tokens.
///         Chooses between a stablecoin-only CreditFacade path (sufficient liquidity) and
///         `SecuritizeLiquidator.liquidatePendingRedemption` (insufficient liquidity).
contract SecuritizeLiquidationSubcompressor is ILiquidationSubcompressor {
    using CreditLogic for CollateralDebtData;
    using LiquidationLib for MultiCall[];
    using LiquidationLib for LiquidationOutput[];
    using LiquidationLib for address[];

    uint256 public constant version = 3_13;
    bytes32 public constant contractType = "GLOBAL::SECURITIZE_LIQ_SC";

    uint256 internal constant EXPECTED_REDEMPTION_DURATION = 90 days;

    struct LiquidationParams {
        address liquidator;
        address creditAccount;
        address creditManager;
        address creditFacade;
        address gateway;
        address gatewayAdapter;
        address underlying;
        address underlyingAdapter;
        address stableCoinToken;
        address dsToken;
        address phantomToken;
        uint256 requiredUnderlyingAmount;
        uint256 totalValue;
        uint16 liquidationDiscount;
        address[] redeemers;
        PriceUpdate[] priceUpdates;
    }

    function getLiquidationData(
        address liquidator,
        address creditAccount,
        address phantomToken,
        PriceUpdate[] calldata priceUpdates
    ) external returns (LiquidationData memory data) {
        LiquidationParams memory ctx = _initContext(liquidator, creditAccount, phantomToken, priceUpdates);
        LiquidationPriceUpdates.applyUpdates(ctx.creditFacade, priceUpdates);

        (uint256 collateralValue, uint256 liquidityAmount) = _calcCollateralAndLiquidityValues(ctx);

        CollateralDebtData memory cdd = ICreditManagerV3(ctx.creditManager)
            .calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        ctx.totalValue = cdd.totalValue;

        bool enoughLiquidity = liquidityAmount * ctx.liquidationDiscount >= cdd.calcTotalDebt() * PERCENTAGE_FACTOR;

        if (enoughLiquidity) {
            return _buildStablecoinPath(ctx);
        }

        ctx.requiredUnderlyingAmount = collateralValue * ctx.liquidationDiscount / PERCENTAGE_FACTOR;
        return _buildPendingRedemptionPath(ctx);
    }

    function _initContext(
        address liquidator,
        address creditAccount,
        address phantomToken,
        PriceUpdate[] calldata priceUpdates
    ) internal view returns (LiquidationParams memory ctx) {
        address gateway = SecuritizeRedemptionPhantomToken(phantomToken).redemptionGateway();
        address creditManager = ICreditAccountV3(creditAccount).creditManager();

        ctx.liquidator = liquidator;
        ctx.creditAccount = creditAccount;
        ctx.creditManager = creditManager;
        ctx.creditFacade = ICreditManagerV3(creditManager).creditFacade();
        ctx.gateway = gateway;
        ctx.gatewayAdapter = ICreditManagerV3(creditManager).contractToAdapter(gateway);
        ctx.underlying = ICreditManagerV3(creditManager).underlying();
        ctx.underlyingAdapter = ICreditManagerV3(creditManager).contractToAdapter(ctx.underlying);
        ctx.stableCoinToken = ISecuritizeRedemptionGateway(gateway).stableCoinToken();
        ctx.dsToken = ISecuritizeRedemptionGateway(gateway).dsToken();
        ctx.phantomToken = phantomToken;
        ctx.redeemers = ISecuritizeRedemptionGateway(gateway).getUnclaimedRedeemers(creditAccount);
        ctx.priceUpdates = priceUpdates;

        (,, ctx.liquidationDiscount,,) = ICreditManagerV3(creditManager).fees();
    }

    function _calcCollateralAndLiquidityValues(LiquidationParams memory ctx)
        internal
        view
        returns (uint256 collateralValue, uint256 liquidityAmount)
    {
        for (uint256 i; i < ctx.redeemers.length; ++i) {
            uint256 stablecoinAmount = IERC20(ctx.stableCoinToken).balanceOf(ctx.redeemers[i]);
            uint256 redemptionValue = SecuritizeRedeemer(ctx.redeemers[i]).getCurrentRedemptionValue();

            collateralValue += stablecoinAmount > redemptionValue ? stablecoinAmount : redemptionValue;
            liquidityAmount += stablecoinAmount;
        }

        liquidityAmount += IERC20(ctx.underlying).balanceOf(ctx.creditAccount);
        liquidityAmount += IERC20(ctx.stableCoinToken).balanceOf(ctx.creditAccount);

        address priceOracle = ICreditManagerV3(ctx.creditManager).priceOracle();
        uint256 dsTokenBalance = IERC20(ctx.dsToken).balanceOf(ctx.creditAccount);
        collateralValue += IPriceOracleV3(priceOracle).convert(dsTokenBalance, ctx.dsToken, ctx.underlying);
    }

    /// @dev Path A: claim claimable stablecoins, wrap to underlying, liquidate via CreditFacade with zero capital.
    function _buildStablecoinPath(LiquidationParams memory ctx) internal view returns (LiquidationData memory data) {
        data.requiredUnderlyingAmount = 0;
        data.isLiquidatorEligible = true;

        // Liquidator profit ≈ totalValue * liquidationPremium (= totalValue - discounted totalValue).
        uint256 premiumAmount = ctx.totalValue - ctx.totalValue * ctx.liquidationDiscount / PERCENTAGE_FACTOR;

        data.expectedOutputs = new LiquidationOutput[](0);
        data.expectedOutputs = data.expectedOutputs
            .append(
                LiquidationOutput({
                    token: ctx.underlying,
                    amount: premiumAmount,
                    delayed: false,
                    redeemerAddress: address(0),
                    claimableAt: 0
                })
            );

        address[] memory redeemersToClaim = _claimableRedeemers(ctx);
        uint256 stableCoinBalance = IERC20(ctx.stableCoinToken).balanceOf(ctx.creditAccount);

        // Avoid RemainingTokenBalanceIncreasedException: depositDiff leftover must be <= pre-multicall balance.
        // If CA starts with 0 stablecoin, leftover must be 0 after claiming into it.
        uint256 depositLeftover = stableCoinBalance > 0 ? 1 : 0;
        bool shouldDeposit = redeemersToClaim.length > 0 || stableCoinBalance > depositLeftover;

        MultiCall[] memory calls = new MultiCall[](0);

        if (redeemersToClaim.length > 0) {
            calls = calls.append(
                MultiCall({
                    target: ctx.gatewayAdapter,
                    callData: abi.encodeCall(ISecuritizeRedemptionGatewayAdapter.claim, (redeemersToClaim))
                })
            );
        }
        if (shouldDeposit) {
            calls = calls.append(
                MultiCall({
                    target: ctx.underlyingAdapter,
                    callData: abi.encodeCall(IERC4626Adapter.depositDiff, (depositLeftover))
                })
            );
        }

        calls = LiquidationPriceUpdates.prependOnDemandPriceUpdates(ctx.creditFacade, ctx.priceUpdates, calls);

        data.liquidationCall = MultiCall({
            target: ctx.creditFacade,
            callData: abi.encodeWithSignature(
                "liquidateCreditAccount(address,address,(address,bytes)[])", ctx.creditAccount, ctx.liquidator, calls
            )
        });
    }

    /// @dev Path B: liquidate via SecuritizeLiquidator (redeemer transfers + DS withdraw built on-chain).
    function _buildPendingRedemptionPath(LiquidationParams memory ctx)
        internal
        view
        returns (LiquidationData memory data)
    {
        data.requiredUnderlyingAmount = ctx.requiredUnderlyingAmount;
        _setEligibility(data, ctx);

        data.expectedOutputs = new LiquidationOutput[](0);

        for (uint256 i; i < ctx.redeemers.length; ++i) {
            address redeemer = ctx.redeemers[i];
            data.expectedOutputs = data.expectedOutputs
                .append(
                    LiquidationOutput({
                        token: ctx.stableCoinToken,
                        amount: _redeemerOutputAmount(redeemer, ctx.stableCoinToken),
                        delayed: true,
                        redeemerAddress: redeemer,
                        claimableAt: _claimableAt(redeemer)
                    })
                );
        }

        uint256 dsTokenBalance = IERC20(ctx.dsToken).balanceOf(ctx.creditAccount);
        if (dsTokenBalance > 0) {
            data.expectedOutputs = data.expectedOutputs
                .append(
                    LiquidationOutput({
                        token: ctx.dsToken,
                        amount: dsTokenBalance,
                        delayed: false,
                        redeemerAddress: address(0),
                        claimableAt: 0
                    })
                );
        }

        data.liquidationCall = MultiCall({
            target: ISecuritizeRedemptionGateway(ctx.gateway).transferMaster(),
            callData: abi.encodeCall(
                ISecuritizeLiquidator.liquidatePendingRedemption,
                (ctx.creditAccount, ctx.gateway, ctx.priceUpdates, bytes(""))
            )
        });
    }

    function _setEligibility(LiquidationData memory data, LiquidationParams memory ctx) internal view {
        (bool isEligible,) = ISecuritizeRedemptionGateway(ctx.gateway).isEligibleAccountOwner(ctx.liquidator);
        if (isEligible) {
            data.isLiquidatorEligible = true;
        } else {
            data.isLiquidatorEligible = false;
            data.kycProtocol = "securitize";
            data.kycToken = ctx.dsToken;
        }
    }

    function _claimableRedeemers(LiquidationParams memory ctx) internal view returns (address[] memory result) {
        result = new address[](0);
        for (uint256 i; i < ctx.redeemers.length; ++i) {
            if (IERC20(ctx.stableCoinToken).balanceOf(ctx.redeemers[i]) > 0) {
                result = result.append(ctx.redeemers[i]);
            }
        }
    }

    function _redeemerOutputAmount(address redeemer, address stableCoinToken) internal view returns (uint256) {
        uint256 stablecoinAmount = IERC20(stableCoinToken).balanceOf(redeemer);
        uint256 redemptionValue = SecuritizeRedeemer(redeemer).getCurrentRedemptionValue();
        return stablecoinAmount > redemptionValue ? stablecoinAmount : redemptionValue;
    }

    function _claimableAt(address redeemer) internal view returns (uint256) {
        uint256 startingTimestamp = SecuritizeRedeemer(redeemer).startingTimestamp();
        uint256 expected = startingTimestamp + EXPECTED_REDEMPTION_DURATION;
        return block.timestamp > expected ? block.timestamp : expected;
    }
}

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
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
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
import {ISecuritizeWallet} from "../../../interfaces/ISecuritizeWallet.sol";
import {IRWAFactory} from "../../../interfaces/base/IRWAFactory.sol";
import {LiquidationData, LiquidationLib, LiquidationOutput, RWALiquidatorInfo} from "../../../types/LiquidationInfo.sol";
import {LiquidationPriceUpdates} from "../../../libraries/LiquidationPriceUpdates.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

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
        uint256 requiredAmount;
        uint256 totalValue;
        uint16 liquidationDiscount;
        bool isCreditAccountFrozen;
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

        CollateralDebtData memory cdd = ICreditManagerV3(ctx.creditManager)
            .calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        ctx.totalValue = cdd.totalValue;
        ctx.liquidationDiscount = _getLiquidationDiscount(ctx.creditManager, cdd);

        (uint256 collateralValue, uint256 liquidityAmount) = _calcCollateralAndLiquidityValues(ctx);

        bool enoughLiquidity = liquidityAmount * ctx.liquidationDiscount >= cdd.calcTotalDebt() * PERCENTAGE_FACTOR;

        if (enoughLiquidity) {
            return _buildStablecoinPath(ctx);
        }

        ctx.requiredAmount = collateralValue * ctx.liquidationDiscount / PERCENTAGE_FACTOR;
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

        address wallet = ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount);
        address factory = ISecuritizeWallet(wallet).getFactory();
        ctx.isCreditAccountFrozen = IRWAFactory(factory).isFrozen(creditAccount);
    }

    function _getLiquidationDiscount(address creditManager, CollateralDebtData memory cdd)
        internal
        view
        returns (uint16)
    {
        (,, uint16 liquidationDiscount,, uint16 liquidationDiscountExpired) = ICreditManagerV3(creditManager).fees();
        return cdd.totalDebtUSD > cdd.twvUSD ? liquidationDiscount : liquidationDiscountExpired;
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

    /// @dev Path A: claim claimable stablecoins, ensure premium is available in stablecoins (unwrapping
    ///      underlying if needed), wrap the remainder, and withdraw the premium as stablecoins.
    function _buildStablecoinPath(LiquidationParams memory ctx) internal view returns (LiquidationData memory data) {
        data.requiredToken = address(0);
        data.requiredAmount = 0;
        data.isLiquidatorEligible = true;
        data.isCreditAccountFrozen = ctx.isCreditAccountFrozen;

        // Liquidator profit ≈ totalValue * liquidationPremium (= totalValue - discounted totalValue).
        uint256 premiumAmount = ctx.totalValue - ctx.totalValue * ctx.liquidationDiscount / PERCENTAGE_FACTOR;

        address[] memory redeemersToClaim = _claimableRedeemers(ctx);
        uint256 stableCoinBalance = IERC20(ctx.stableCoinToken).balanceOf(ctx.creditAccount);
        uint256 stableAfterClaim = stableCoinBalance + _claimableStablecoinAmount(redeemersToClaim, ctx.stableCoinToken);
        uint256 stablecoinShortfall =
            premiumAmount > stableAfterClaim ? premiumAmount - stableAfterClaim : 0;

        data.expectedOutputs = new LiquidationOutput[](0);
        if (premiumAmount > 0) {
            data.expectedOutputs = data.expectedOutputs.append(
                LiquidationOutput({
                    token: ctx.stableCoinToken,
                    amount: premiumAmount,
                    delayed: false,
                    redeemerAddress: address(0),
                    claimableAt: 0
                })
            );
        }

        MultiCall[] memory calls = new MultiCall[](0);

        if (redeemersToClaim.length > 0) {
            calls = calls.append(
                MultiCall({
                    target: ctx.gatewayAdapter,
                    callData: abi.encodeCall(ISecuritizeRedemptionGatewayAdapter.claim, (redeemersToClaim))
                })
            );
        }
        if (stablecoinShortfall > 0) {
            // Convert underlying vault shares to stablecoins to cover the premium.
            calls = calls.append(
                MultiCall({
                    target: ctx.underlyingAdapter,
                    callData: abi.encodeCall(IERC4626Adapter.withdraw, (stablecoinShortfall, address(0), address(0)))
                })
            );
        }
        if (stableAfterClaim > premiumAmount) {
            // Wrap excess stablecoins into underlying for debt repayment; leave premium for withdrawal.
            calls = calls.append(
                MultiCall({
                    target: ctx.underlyingAdapter,
                    callData: abi.encodeCall(IERC4626Adapter.depositDiff, (premiumAmount))
                })
            );
        }
        if (premiumAmount > 0) {
            calls = calls.append(
                MultiCall({
                    target: ctx.creditFacade,
                    callData: abi.encodeCall(
                        ICreditFacadeV3Multicall.withdrawCollateral,
                        (ctx.stableCoinToken, premiumAmount, ctx.liquidator)
                    )
                })
            );
        }

        calls = LiquidationPriceUpdates.prependOnDemandPriceUpdates(ctx.creditFacade, ctx.priceUpdates, calls);

        data.liquidationCall = MultiCall({
            target: ctx.creditFacade,
            callData: abi.encodeWithSignature(
                "liquidateCreditAccount(address,address,(address,bytes)[])",
                ctx.creditAccount,
                ctx.liquidator,
                calls
            )
        });
    }

    /// @dev Path B: liquidate via SecuritizeLiquidator (liquidator pays stablecoins that get wrapped on-chain).
    function _buildPendingRedemptionPath(LiquidationParams memory ctx)
        internal
        view
        returns (LiquidationData memory data)
    {
        data.requiredToken = ctx.stableCoinToken;
        data.requiredAmount = ctx.requiredAmount;
        data.isCreditAccountFrozen = ctx.isCreditAccountFrozen;
        _setEligibility(data, ctx);

        data.expectedOutputs = new LiquidationOutput[](0);

        for (uint256 i; i < ctx.redeemers.length; ++i) {
            address redeemer = ctx.redeemers[i];
            data.expectedOutputs = data.expectedOutputs.append(
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
            data.expectedOutputs = data.expectedOutputs.append(
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

    function getRWALiquidatorInfo(address token) external view returns (RWALiquidatorInfo memory info) {
        address gateway = SecuritizeRedemptionPhantomToken(token).redemptionGateway();
        address liquidator = ISecuritizeRedemptionGateway(gateway).transferMaster();
        info.gateway = gateway;
        info.liquidatorAddress = liquidator;
        info.contractType = IVersion(liquidator).contractType();
    }

    function _claimableRedeemers(LiquidationParams memory ctx) internal view returns (address[] memory result) {
        result = new address[](0);
        for (uint256 i; i < ctx.redeemers.length; ++i) {
            if (IERC20(ctx.stableCoinToken).balanceOf(ctx.redeemers[i]) > 0) {
                result = result.append(ctx.redeemers[i]);
            }
        }
    }

    function _claimableStablecoinAmount(address[] memory redeemers, address stableCoinToken)
        internal
        view
        returns (uint256 amount)
    {
        for (uint256 i; i < redeemers.length; ++i) {
            amount += IERC20(stableCoinToken).balanceOf(redeemers[i]);
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

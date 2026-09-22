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
import {BitMask} from "@gearbox-protocol/core-v3/contracts/libraries/BitMask.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

import {MidasGateway} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasGateway.sol";
import {MidasRedeemer} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasRedeemer.sol";
import {
    MidasRedemptionVaultPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/MidasRedemptionVaultPhantomToken.sol";
import {
    IMidasGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/interfaces/IMidasGatewayAdapter.sol";
import {
    IMidasLiquidator
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/interfaces/IMidasLiquidator.sol";
import {MidasMode} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/interfaces/IMidasGateway.sol";
import {
    IMidasAccessControl
} from "@gearbox-protocol/integrations-v3/contracts/integrations/midas/interfaces/external/IMidasAccessControl.sol";

import {ILiquidationSubcompressor} from "../../../interfaces/ILiquidationSubcompressor.sol";
import {LiquidationData, LiquidationLib, LiquidationOutput, RWALiquidatorInfo} from "../../../types/LiquidationInfo.sol";
import {LiquidationPriceUpdates} from "../../../libraries/LiquidationPriceUpdates.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

/// @title Midas liquidation subcompressor
contract MidasLiquidationSubcompressor is ILiquidationSubcompressor {
    using BitMask for uint256;
    using LiquidationLib for MultiCall[];
    using LiquidationLib for LiquidationOutput[];

    uint256 public constant version = 3_13;
    bytes32 public constant contractType = "GLOBAL::MIDAS_LIQ_SC";

    struct LiquidationParams {
        address liquidator;
        address creditAccount;
        address creditManager;
        address creditFacade;
        address gateway;
        address gatewayAdapter;
        address quoteToken;
        address phantomToken;
        uint256 requiredAmount;
        uint256 enabledTokensMask;
        uint256 claimableTotal;
        bool quoteTokenHandled;
        address[] redeemers;
        LiquidationOutput[] expectedOutputs;
        MultiCall[] calls;
    }

    function getLiquidationData(
        address liquidator,
        address creditAccount,
        address phantomToken,
        PriceUpdate[] calldata priceUpdates
    ) external returns (LiquidationData memory data) {
        address gateway = MidasRedemptionVaultPhantomToken(phantomToken).gateway();
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        LiquidationPriceUpdates.applyUpdates(creditFacade, priceUpdates);

        data.requiredToken = ICreditManagerV3(creditManager).underlying();
        data.requiredAmount = _getRequiredAmount(creditAccount, creditManager);
        data.isCreditAccountFrozen = false;
        _setEligibility(data, liquidator, gateway);

        LiquidationParams memory ctx = _initContext({
            liquidator: liquidator,
            creditAccount: creditAccount,
            creditManager: creditManager,
            gateway: gateway,
            phantomToken: phantomToken,
            requiredAmount: data.requiredAmount
        });

        _appendAddCollateral(ctx);
        _appendRedeemerCalls(ctx);
        _appendEnabledTokenWithdrawals(ctx);
        _appendClaimableQuoteIfNeeded(ctx);

        ctx.calls = LiquidationPriceUpdates.prependOnDemandPriceUpdates(creditFacade, priceUpdates, ctx.calls);

        data.expectedOutputs = ctx.expectedOutputs;
        data.liquidationCall = MultiCall({
            target: MidasGateway(gateway).transferMaster(),
            callData: abi.encodeCall(
                IMidasLiquidator.liquidateWithRedeemerTransfers, (creditAccount, gateway, ctx.calls, bytes(""))
            )
        }        );
    }

    function getRWALiquidatorInfo(address token) external view returns (RWALiquidatorInfo memory info) {
        address gateway = MidasRedemptionVaultPhantomToken(token).gateway();
        address liquidator = MidasGateway(gateway).transferMaster();
        info.gateway = gateway;
        info.liquidatorAddress = liquidator;
        info.contractType = IVersion(liquidator).contractType();
    }

    function _getRequiredAmount(address creditAccount, address creditManager) internal view returns (uint256) {
        CollateralDebtData memory cdd = ICreditManagerV3(creditManager)
            .calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        (,, uint16 liquidationDiscount,,) = ICreditManagerV3(creditManager).fees();
        return cdd.totalValue * liquidationDiscount / PERCENTAGE_FACTOR;
    }

    function _setEligibility(LiquidationData memory data, address liquidator, address gateway) internal view {
        if (MidasGateway(gateway).mode() != MidasMode.Permissioned) {
            data.isLiquidatorEligible = true;
            return;
        }

        address accessControl = MidasGateway(gateway).accessControl();
        if (IMidasAccessControl(accessControl).hasRole(MidasGateway(gateway).greenlistedRole(), liquidator)) {
            data.isLiquidatorEligible = true;
        } else {
            data.isLiquidatorEligible = false;
            data.kycProtocol = "midas";
            data.kycToken = MidasGateway(gateway).mToken();
        }
    }

    function _initContext(
        address liquidator,
        address creditAccount,
        address creditManager,
        address gateway,
        address phantomToken,
        uint256 requiredAmount
    ) internal view returns (LiquidationParams memory ctx) {
        ctx.liquidator = liquidator;
        ctx.creditAccount = creditAccount;
        ctx.creditManager = creditManager;
        ctx.gateway = gateway;
        ctx.phantomToken = phantomToken;
        ctx.requiredAmount = requiredAmount;

        ctx.creditFacade = ICreditManagerV3(creditManager).creditFacade();
        ctx.gatewayAdapter = ICreditManagerV3(creditManager).contractToAdapter(gateway);
        ctx.quoteToken = MidasGateway(gateway).quoteToken();
        ctx.redeemers = MidasGateway(gateway).pendingRedeemers(creditAccount);
        ctx.enabledTokensMask = ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount);
        ctx.claimableTotal = _claimableTotal(ctx.redeemers);
        ctx.expectedOutputs = new LiquidationOutput[](0);
        ctx.calls = new MultiCall[](0);
    }

    function _claimableTotal(address[] memory redeemers) internal view returns (uint256 claimableTotal) {
        for (uint256 i; i < redeemers.length; ++i) {
            claimableTotal += MidasRedeemer(redeemers[i]).claimableTokenOutAmount();
        }
    }

    function _appendAddCollateral(LiquidationParams memory ctx) internal view {
        if (ctx.requiredAmount == 0) return;

        ctx.calls = ctx.calls.append(
            MultiCall({
                target: ctx.creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.addCollateral,
                    (ICreditManagerV3(ctx.creditManager).underlying(), ctx.requiredAmount)
                )
            })
        );
    }

    function _appendRedeemerCalls(LiquidationParams memory ctx) internal view {
        uint256 expectedRedemptionDuration = MidasGateway(ctx.gateway).expectedRedemptionDuration();

        for (uint256 i; i < ctx.redeemers.length; ++i) {
            address redeemer = ctx.redeemers[i];

            uint256 claimableAmount = MidasRedeemer(redeemer).claimableTokenOutAmount();
            if (claimableAmount > 0) {
                ctx.calls = ctx.calls.append(
                    MultiCall({
                        target: ctx.gatewayAdapter,
                        callData: abi.encodeCall(IMidasGatewayAdapter.withdrawFromRedeemer, (redeemer, claimableAmount))
                    })
                );
            }

            uint256 pendingAmount = MidasRedeemer(redeemer).pendingTokenOutAmount();
            if (pendingAmount > 0) {
                ctx.calls = ctx.calls.append(
                    MultiCall({
                        target: ctx.gatewayAdapter,
                        callData: abi.encodeCall(IMidasGatewayAdapter.transferRedeemer, (redeemer, ctx.liquidator))
                    })
                );

                ctx.expectedOutputs = ctx.expectedOutputs.append(
                    LiquidationOutput({
                        token: ctx.quoteToken,
                        amount: pendingAmount,
                        delayed: true,
                        redeemerAddress: redeemer,
                        claimableAt: MidasRedeemer(redeemer).redemptionStartTimestamp() + expectedRedemptionDuration
                    })
                );
            }
        }
    }

    function _appendEnabledTokenWithdrawals(LiquidationParams memory ctx) internal view {
        uint256 enabledTokensMask = ctx.enabledTokensMask;

        while (enabledTokensMask != 0) {
            uint256 tokenMask = enabledTokensMask.lsbMask();
            address token = ICreditManagerV3(ctx.creditManager).getTokenByMask(tokenMask);

            if (token != ctx.phantomToken) {
                uint256 amount = IERC20(token).balanceOf(ctx.creditAccount);
                if (token == ctx.quoteToken) {
                    amount += ctx.claimableTotal;
                    ctx.quoteTokenHandled = true;
                }

                if (amount > 1) {
                    ctx.expectedOutputs = ctx.expectedOutputs.append(
                        LiquidationOutput({
                            token: token,
                            amount: amount,
                            delayed: false,
                            redeemerAddress: address(0),
                            claimableAt: 0
                        })
                    );
                    ctx.calls = ctx.calls.append(
                        MultiCall({
                            target: ctx.creditFacade,
                            callData: abi.encodeCall(
                                ICreditFacadeV3Multicall.withdrawCollateral, (token, amount, ctx.liquidator)
                            )
                        })
                    );
                }
            }

            enabledTokensMask = enabledTokensMask.disable(tokenMask);
        }
    }

    function _appendClaimableQuoteIfNeeded(LiquidationParams memory ctx) internal pure {
        if (ctx.claimableTotal == 0 || ctx.quoteTokenHandled) return;

        ctx.expectedOutputs = ctx.expectedOutputs.append(
            LiquidationOutput({
                token: ctx.quoteToken,
                amount: ctx.claimableTotal,
                delayed: false,
                redeemerAddress: address(0),
                claimableAt: 0
            })
        );
        ctx.calls = ctx.calls.append(
            MultiCall({
                target: ctx.creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.withdrawCollateral, (ctx.quoteToken, ctx.claimableTotal, ctx.liquidator)
                )
            })
        );
    }
}

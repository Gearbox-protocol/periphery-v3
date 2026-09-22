// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
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

import {
    TreehouseRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedemptionGateway.sol";
import {
    TreehouseRedeemer
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedeemer.sol";
import {
    TreehouseRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/TreehouseRedemptionPhantomToken.sol";
import {
    ITreehouseRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/interfaces/ITreehouseRedemptionGateway.sol";
import {
    ITreehouseLiquidator
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/interfaces/ITreehouseLiquidator.sol";
import {
    ITreehouseRedemptionV3,
    RedemptionInfo
} from "@gearbox-protocol/integrations-v3/contracts/integrations/treehouse/interfaces/external/ITreehouseRedemptionV3.sol";

import {ILiquidationSubcompressor} from "../../../interfaces/ILiquidationSubcompressor.sol";
import {LiquidationData, LiquidationLib, LiquidationOutput, RWALiquidatorInfo} from "../../../types/LiquidationInfo.sol";
import {LiquidationPriceUpdates} from "../../../libraries/LiquidationPriceUpdates.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";

/// @title Treehouse liquidation subcompressor
contract TreehouseLiquidationSubcompressor is ILiquidationSubcompressor {
    using BitMask for uint256;
    using LiquidationLib for MultiCall[];
    using LiquidationLib for LiquidationOutput[];

    uint256 public constant version = 3_10;
    bytes32 public constant contractType = "GLOBAL::TREEHOUSE_LIQ_SC";

    struct LiquidationParams {
        address liquidator;
        address creditAccount;
        address creditManager;
        address creditFacade;
        address gateway;
        address gatewayAdapter;
        address vaultUnderlying;
        address phantomToken;
        uint256 requiredAmount;
        uint256 enabledTokensMask;
        uint256 claimableTotal;
        bool vaultUnderlyingHandled;
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
        address gateway = TreehouseRedemptionPhantomToken(phantomToken).gateway();
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();

        LiquidationPriceUpdates.applyUpdates(creditFacade, priceUpdates);

        data.requiredToken = ICreditManagerV3(creditManager).underlying();
        data.requiredAmount = _getRequiredAmount(creditAccount, creditManager);
        data.isCreditAccountFrozen = false;
        data.isLiquidatorEligible = true;

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
        _appendClaimableUnderlyingIfNeeded(ctx);

        ctx.calls = LiquidationPriceUpdates.prependOnDemandPriceUpdates(creditFacade, priceUpdates, ctx.calls);

        data.expectedOutputs = ctx.expectedOutputs;
        data.liquidationCall = MultiCall({
            target: TreehouseRedemptionGateway(gateway).transferMaster(),
            callData: abi.encodeCall(
                ITreehouseLiquidator.liquidateWithRedeemerTransfers, (creditAccount, gateway, ctx.calls, bytes(""))
            )
        });
    }

    function getRWALiquidatorInfo(address token) external view returns (RWALiquidatorInfo memory info) {
        address gateway = TreehouseRedemptionPhantomToken(token).gateway();
        address liquidator = TreehouseRedemptionGateway(gateway).transferMaster();
        info.gateway = gateway;
        info.liquidatorAddress = liquidator;
        info.contractType = IVersion(liquidator).contractType();
    }

    function _getRequiredAmount(address creditAccount, address creditManager) internal view returns (uint256) {
        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
        (,, uint16 liquidationDiscount,,) = ICreditManagerV3(creditManager).fees();
        return cdd.totalValue * liquidationDiscount / PERCENTAGE_FACTOR;
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
        ctx.vaultUnderlying = TreehouseRedemptionGateway(gateway).vaultUnderlying();
        ctx.redeemers = TreehouseRedemptionGateway(gateway).pendingRedeemers(creditAccount);
        ctx.enabledTokensMask = ICreditManagerV3(creditManager).enabledTokensMaskOf(creditAccount);
        ctx.claimableTotal = _claimableTotal(ctx.redeemers);
        ctx.expectedOutputs = new LiquidationOutput[](0);
        ctx.calls = new MultiCall[](0);
    }

    function _claimableTotal(address[] memory redeemers) internal view returns (uint256 claimableTotal) {
        for (uint256 i; i < redeemers.length; ++i) {
            claimableTotal += TreehouseRedeemer(redeemers[i]).claimableAmount();
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
        address redemptionV3 = TreehouseRedemptionGateway(ctx.gateway).redemptionV3();
        uint256 waitingPeriod = ITreehouseRedemptionV3(redemptionV3).waitingPeriod();

        for (uint256 i; i < ctx.redeemers.length; ++i) {
            address redeemer = ctx.redeemers[i];

            uint256 claimableAmount = TreehouseRedeemer(redeemer).claimableAmount();
            if (claimableAmount > 0) {
                ctx.calls = ctx.calls.append(
                    MultiCall({
                        target: ctx.gatewayAdapter,
                        callData: abi.encodeCall(ITreehouseRedemptionGateway.finalizeRedeem, (redeemer))
                    })
                );
            }

            uint256 pendingAmount = TreehouseRedeemer(redeemer).pendingAmount();
            if (pendingAmount > 0) {
                ctx.calls = ctx.calls.append(
                    MultiCall({
                        target: ctx.gatewayAdapter,
                        callData: abi.encodeCall(
                            ITreehouseRedemptionGateway.transferRedeemer, (redeemer, ctx.liquidator)
                        )
                    })
                );

                RedemptionInfo memory redemptionInfo = ITreehouseRedemptionV3(redemptionV3).getRedeemInfo(redeemer, 0);

                ctx.expectedOutputs = ctx.expectedOutputs.append(
                    LiquidationOutput({
                        token: ctx.vaultUnderlying,
                        amount: pendingAmount,
                        delayed: true,
                        redeemerAddress: redeemer,
                        claimableAt: uint256(redemptionInfo.startTime) + waitingPeriod
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
                if (token == ctx.vaultUnderlying) {
                    amount += ctx.claimableTotal;
                    ctx.vaultUnderlyingHandled = true;
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

    function _appendClaimableUnderlyingIfNeeded(LiquidationParams memory ctx) internal pure {
        if (ctx.claimableTotal == 0 || ctx.vaultUnderlyingHandled) return;

        ctx.expectedOutputs = ctx.expectedOutputs.append(
            LiquidationOutput({
                token: ctx.vaultUnderlying,
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
                    ICreditFacadeV3Multicall.withdrawCollateral,
                    (ctx.vaultUnderlying, ctx.claimableTotal, ctx.liquidator)
                )
            })
        );
    }
}

// // SPDX-License-Identifier: MIT
// // Gearbox Protocol. Generalized leverage for DeFi protocols
// // (c) Gearbox Foundaiton, 2025.
// pragma solidity ^0.8.23;

// import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
// import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

// import {IWithdrawalSubcompressor} from "../../../interfaces/IWithdrawalSubcompressor.sol";
// import {
//     WithdrawalOutput,
//     WithdrawableAsset,
//     RequestableWithdrawal,
//     ClaimableWithdrawal,
//     PendingWithdrawal,
//     WithdrawalLib
// } from "../../../types/WithdrawalInfo.sol";
// import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";

// import {IMellowRedeemQueueAdapter} from
//     "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowRedeemQueueAdapter.sol";
// import {
//     IMellowRedeemQueue,
//     Request
// } from "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowRedeemQueue.sol";
// import {IMellowFlexibleRedeemGateway} from
//     "@gearbox-protocol/integrations-v3/contracts/interfaces/mellow/IMellowFlexibleRedeemGateway.sol";
// import {MellowFlexibleRedeemPhantomToken} from
//     "@gearbox-protocol/integrations-v3/contracts/helpers/mellow/MellowFlexibleRedeemPhantomToken.sol";
// import {IMellowFlexibleVault} from
//     "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowFlexibleVault.sol";
// import {IMellowRateOracle} from "@gearbox-protocol/integrations-v3/contracts/integrations/mellow/IMellowRateOracle.sol";

// import {WAD} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";

// uint256 constant PRICE_NUMERATOR = 1e36;

// struct OracleReport {
//     uint224 priceD18;
//     uint32 timestamp;
//     bool isSuspicious;
// }

// interface IMellowRateOracleExt {
//     function reports(address asset) external view returns (uint256);
//     function reportAt(address asset, uint256 index) external view returns (OracleReport memory);
//     function acceptedAt(address asset, uint256 index) external view returns (uint32);
// }

// contract MellowFlexibleRedeemSubcompressor is IWithdrawalSubcompressor {
//     using WithdrawalLib for PendingWithdrawal[];

//     uint256 public constant version = 3_10;
//     bytes32 public constant contractType = "GLOBAL::MELF_REDEEM_WD_SC";

//     function getWithdrawableAssets(address, address token) external view returns (WithdrawableAsset[] memory) {
//         address redeemQueueGateway = MellowFlexibleRedeemPhantomToken(token).redeemQueueGateway();
//         address asset = IMellowFlexibleRedeemGateway(redeemQueueGateway).asset();
//         address vaultToken = IMellowFlexibleRedeemGateway(redeemQueueGateway).vaultToken();
//         WithdrawableAsset[] memory withdrawableAssets = new WithdrawableAsset[](1);
//         withdrawableAssets[0] = WithdrawableAsset(vaultToken, token, asset, _getRedeemInterval(redeemQueueGateway));
//         return withdrawableAssets;
//     }

//     function getCurrentWithdrawals(address creditAccount, address token)
//         external
//         view
//         returns (ClaimableWithdrawal[] memory, PendingWithdrawal[] memory)
//     {
//         address redeemQueueGateway = MellowFlexibleRedeemPhantomToken(token).redeemQueueGateway();

//         ClaimableWithdrawal[] memory claimableWithdrawals = new ClaimableWithdrawal[](1);
//         claimableWithdrawals[0] = _getClaimableWithdrawal(creditAccount, token, redeemQueueGateway);

//         if (claimableWithdrawals[0].outputs.length == 0 || claimableWithdrawals[0].outputs[0].amount == 0) {
//             claimableWithdrawals = new ClaimableWithdrawal[](0);
//         }

//         PendingWithdrawal[] memory pendingWithdrawals = _getPendingWithdrawals(creditAccount, token, redeemQueueGateway);

//         for (uint256 i = 0; i < pendingWithdrawals.length; ++i) {
//             pendingWithdrawals[i].withdrawalPhantomToken = token;
//         }

//         return (claimableWithdrawals, pendingWithdrawals);
//     }

//     function getWithdrawalRequestResult(address creditAccount, address token, address withdrawalToken, uint256 amount)
//         external
//         view
//         returns (RequestableWithdrawal memory requestableWithdrawal)
//     {
//         address redeemQueueGateway = MellowFlexibleRedeemPhantomToken(withdrawalToken).redeemQueueGateway();

//         address redeemQueueAdapter =
//             ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(redeemQueueGateway);

//         requestableWithdrawal.token = token;
//         requestableWithdrawal.amountIn = amount;
//         requestableWithdrawal.outputs = new WithdrawalOutput[](1);
//         requestableWithdrawal.requestCalls = new MultiCall[](1);
//         requestableWithdrawal.claimableAt = block.timestamp + _getRedeemInterval(redeemQueueGateway);

//         requestableWithdrawal.requestCalls[0] =
//             MultiCall(address(redeemQueueAdapter), abi.encodeCall(IMellowRedeemQueueAdapter.redeem, (amount)));

//         requestableWithdrawal.outputs[0] = WithdrawalOutput(withdrawalToken, true, 0);

//         address mellowRateOracle = MellowFlexibleRedeemPhantomToken(withdrawalToken).mellowRateOracle();

//         address asset = IMellowFlexibleRedeemGateway(redeemQueueGateway).asset();

//         uint256 sharesRate = _getLastAcceptedRate(mellowRateOracle, asset);
//         requestableWithdrawal.outputs[0].amount = amount * sharesRate / WAD;

//         return requestableWithdrawal;
//     }

//     function _getPendingWithdrawals(address creditAccount, address withdrawalToken, address redeemQueueGateway)
//         internal
//         view
//         returns (PendingWithdrawal[] memory pendingWithdrawals)
//     {
//         address asset = IMellowFlexibleRedeemGateway(redeemQueueGateway).asset();
//         address vaultToken = IMellowFlexibleRedeemGateway(redeemQueueGateway).vaultToken();
//         address depositor = IMellowFlexibleRedeemGateway(redeemQueueGateway).accountToRedeemer(creditAccount);

//         address redeemQueue = IMellowFlexibleRedeemGateway(redeemQueueGateway).mellowRedeemQueue();

//         Request[] memory requests = IMellowRedeemQueue(redeemQueue).requestsOf(depositor, 0, type(uint256).max);

//         pendingWithdrawals = new PendingWithdrawal[](requests.length);

//         for (uint256 i = 0; i < requests.length; ++i) {
//             if (!requests[i].isClaimable) {
//                 pendingWithdrawals[i].token = vaultToken;
//                 pendingWithdrawals[i].expectedOutputs = new WithdrawalOutput[](1);
//                 pendingWithdrawals[i].expectedOutputs[0] = WithdrawalOutput(asset, false, 0);
//                 pendingWithdrawals[i].claimableAt = _getClaimableAt(requests[i].timestamp, redeemQueueGateway);

//                 address mellowRateOracle = MellowFlexibleRedeemPhantomToken(withdrawalToken).mellowRateOracle();
//                 uint256 sharesRate = _getLastAcceptedRate(mellowRateOracle, asset);
//                 pendingWithdrawals[i].expectedOutputs[0].amount = requests[i].shares * sharesRate / WAD;
//             }
//         }

//         return pendingWithdrawals;
//     }

//     function _getClaimableWithdrawal(address creditAccount, address withdrawalToken, address redeemQueueGateway)
//         internal
//         view
//         returns (ClaimableWithdrawal memory withdrawal)
//     {
//         address asset = IMellowFlexibleRedeemGateway(redeemQueueGateway).asset();
//         address vaultToken = IMellowFlexibleRedeemGateway(redeemQueueGateway).vaultToken();

//         withdrawal.token = vaultToken;
//         uint256 claimable = IMellowFlexibleRedeemGateway(redeemQueueGateway).getClaimableAssets(creditAccount);

//         if (claimable > 0) {
//             withdrawal.outputs = new WithdrawalOutput[](1);
//             withdrawal.outputs[0] = WithdrawalOutput(asset, false, claimable);
//             withdrawal.withdrawalPhantomToken = withdrawalToken;
//             withdrawal.withdrawalTokenSpent = claimable;

//             address redeemQueueAdapter =
//                 ICreditManagerV3(ICreditAccountV3(creditAccount).creditManager()).contractToAdapter(redeemQueueGateway);

//             withdrawal.claimCalls = new MultiCall[](1);
//             withdrawal.claimCalls[0] =
//                 MultiCall(address(redeemQueueAdapter), abi.encodeCall(IMellowRedeemQueueAdapter.claim, (claimable)));
//         }

//         return withdrawal;
//     }

//     function _getClaimableAt(uint256 timestamp, address redeemQueueGateway) internal view returns (uint256) {
//         uint256 elapsedTime = block.timestamp - timestamp;
//         uint256 redeemInterval = _getRedeemInterval(redeemQueueGateway);
//         return elapsedTime > redeemInterval ? block.timestamp : block.timestamp + redeemInterval - elapsedTime;
//     }

//     function _getRedeemInterval(address redeemQueueGateway) internal view returns (uint256) {
//         address redeemQueue = IMellowFlexibleRedeemGateway(redeemQueueGateway).mellowRedeemQueue();
//         address vault = IMellowRedeemQueue(redeemQueue).vault();
//         address oracle = IMellowFlexibleVault(vault).oracle();
//         (,,,,,, uint256 redeemInterval) = IMellowRateOracle(oracle).securityParams();
//         return redeemInterval + 1 days;
//     }

//     /// @notice Retrieves the last non-suspicious report from Mellow's OracleSubmitter for the queue's asset
//     function _getLastAcceptedRate(address mellowRateOracle, address asset) internal view returns (uint256) {
//         uint256 reportNum = IMellowRateOracleExt(mellowRateOracle).reports(asset);

//         for (uint256 i = reportNum; i > 0; i--) {
//             OracleReport memory report = IMellowRateOracleExt(mellowRateOracle).reportAt(asset, i - 1);

//             if (!report.isSuspicious || IMellowRateOracleExt(mellowRateOracle).acceptedAt(asset, i - 1) != 0) {
//                 return PRICE_NUMERATOR / report.priceD18;
//             }
//         }

//         return 0;
//     }
// }

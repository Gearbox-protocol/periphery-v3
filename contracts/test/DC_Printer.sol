// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DataCompressorV2_10} from "../data/DataCompressor_2_1.sol";
import {DataCompressorV3_00} from "../data/DataCompressor_3_0.sol";
import {CreditAccountData, CreditManagerData, PoolData, TokenBalance, ContractAdapter} from "../data/Types.sol";

import "forge-std/console.sol";

address constant ap = 0x5BcB06c56e8F28da0b038a373199240ca3F5a2f4;

contract DCTest {
    DataCompressorV2_10 public dc2;
    DataCompressorV3_00 public dc3;

    function setUp() public {
        dc2 = new DataCompressorV2_10(ap);
        dc3 = new DataCompressorV3_00(ap);
    }

    function _printPools(PoolData[] memory pools) internal view {
        uint256 len = pools.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                PoolData memory pool = pools[i];
                console.log("\n\n");
                console.log(IERC20Metadata(pool.underlying).symbol(), pool.addr);
                console.log("-------------------------------");

                console.log("dieselToken: ", pool.dieselToken);
                ///
                console.log("linearCumulativeIndex: ", pool.linearCumulativeIndex);
                console.log("availableLiquidity: ", pool.availableLiquidity);
                console.log("expectedLiquidity: ", pool.expectedLiquidity);
                //
                console.log("totalBorrowed: ", pool.totalBorrowed);
                console.log("totalDebtLimit: ", pool.totalDebtLimit);
                // CreditManagerDebtParams[] creditManagerDebtParams;
                console.log("totalAssets: ", pool.totalAssets);
                console.log("totalSupply: ", pool.totalSupply);
                console.log("supplyRate", pool.supplyRate);
                console.log("baseInterestRate: ", pool.baseInterestRate);
                console.log("dieselRate_RAY: ", pool.dieselRate_RAY);
                console.log("withdrawFee", pool.withdrawFee);
                console.log("cumulativeIndex_RAY:", pool.cumulativeIndex_RAY);
                console.log("baseInterestIndexLU:", pool.baseInterestIndexLU);
                console.log("version: ", pool.version);
                // QuotaInfo[] quotas;
                // LinearModel lirm;
                console.log("isPaused", pool.isPaused);
            }
        }
    }

    function _printCreditManagers(CreditManagerData[] memory cms) internal view {
        uint256 len = cms.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                CreditManagerData memory cm = cms[i];
                console.log("\n\n");
                console.log(IERC20Metadata(cm.underlying).symbol(), cm.addr);
                console.log("-------------------------------");
                console.log("cfVersion: ", cm.cfVersion);
                console.log("creditFacace: ", cm.creditFacade); // V2 only: address of creditFacade
                console.log("creditConfigurator: ", cm.creditConfigurator); // V2 only: address of creditConfigurator
                console.log("pool: ", cm.pool);
                console.log("totalDebt: ", cm.totalDebt);
                console.log("totalDebtLimit: ", cm.totalDebtLimit);
                console.log("baseBorrowRate: ", cm.baseBorrowRate);
                console.log("minDebt: ", cm.minDebt);
                console.log("maxDebt: ", cm.maxDebt);
                console.log("availableToBorrow: ", cm.availableToBorrow);
                // address[] collateralTokens);
                // ContractAdapter[] adapters);
                // uint256[] liquidationThresholds);
                console.log("isDegenMode: ", cm.isDegenMode); // V2 only: true if contract is in Degen mode
                console.log("degenNFT: ", cm.degenNFT); // V2 only: degenNFT, address(0) if not in degen mode
                console.log("forbiddenTokenMask: ", cm.forbiddenTokenMask); // V2 only: mask which forbids some particular tokens
                console.log("maxEnabledTokensLength: ", cm.maxEnabledTokensLength); // V2 only: in V1 as many tokens as the CM can support (256)
                console.log("feeInterest: ", cm.feeInterest); // Interest fee protocol charges: fee = interest accrues * feeInterest
                console.log("feeLiquidation: ", cm.feeLiquidation); // Liquidation fee protocol charges: fee = totalValue * feeLiquidation
                console.log("liquidationDiscount: ", cm.liquidationDiscount); // Miltiplier to get amount which liquidator should pay: amount = totalValue * liquidationDiscount
                console.log("feeLiquidationExpired: ", cm.feeLiquidationExpired); // Liquidation fee protocol charges on expired accounts
                console.log("liquidationDiscountExpired: ", cm.liquidationDiscountExpired); // Multiplier for the amount the liquidator has to pay when closing an expired account
                // V3 Fileds
                // QuotaInfo[] quotas);
                // LinearModel lirm);
                console.log("sPaused: ", cm.isPaused);
            }
        }
    }

    function test_dc_pools() public view {
        PoolData[] memory pools = dc2.getPoolsV1List();
        console.log("V1 pools");
        _printPools(pools);

        pools = dc3.getPoolsV3List();
        console.log("\nV3 pools");
        _printPools(pools);
    }

    function test_dc_credit_managers() public view {
        CreditManagerData[] memory cms = dc2.getCreditManagersV2List();
        console.log("V2 credit managers");
        _printCreditManagers(cms);

        cms = dc3.getCreditManagersV3List();
        console.log("\n\nV3 credit managers");
        _printCreditManagers(cms);
    }
}

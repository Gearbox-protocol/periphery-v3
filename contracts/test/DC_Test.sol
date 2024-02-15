// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DataCompressorV2_1} from "../data/DataCompressorV2_1.sol";
import {DataCompressorV3} from "../data/DataCompressorV3.sol";
import {IDataCompressorV3, PriceOnDemand} from "../interfaces/IDataCompressorV3.sol";
import {CreditAccountData, CreditManagerData, PoolData, TokenBalance, ContractAdapter} from "../data/Types.sol";

import {NetworkDetector} from "@gearbox-protocol/sdk-gov/contracts/NetworkDetector.sol";

import "forge-std/console.sol";

address constant ap = 0x9ea7b04Da02a5373317D745c1571c84aaD03321D;

contract DCTest {
    DataCompressorV2_1 public dc2;
    DataCompressorV3 public dc3;

    uint256 chainId;

    constructor() {
        NetworkDetector nd = new NetworkDetector();
        chainId = nd.chainId();
    }

    modifier liveTestOnly() {
        if (chainId == 1) {
            _;
        }
    }

    function setUp() public liveTestOnly {
        dc2 = new DataCompressorV2_1(ap);
        dc3 = new DataCompressorV3(ap);
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
                console.log("baseInterestIndex: ", pool.baseInterestIndex);
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
                console.log("lastBaseInterestUpdate:", pool.lastBaseInterestUpdate);
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

    function test_dc_01_pools() public view liveTestOnly {
        PoolData[] memory pools = dc2.getPoolsV1List();
        console.log("V1 pools");
        _printPools(pools);

        pools = dc3.getPoolsV3List();
        console.log("\nV3 pools");
        _printPools(pools);
    }

    function test_dc_02_credit_managers() public view liveTestOnly {
        CreditManagerData[] memory cms = dc2.getCreditManagersV2List();
        console.log("V2 credit managers");
        _printCreditManagers(cms);

        cms = dc3.getCreditManagersV3List();
        console.log("\n\nV3 credit managers");
        _printCreditManagers(cms);
    }

    function test_dc_03_credit_accounts() public liveTestOnly {
        CreditAccountData[] memory cas = dc2.getCreditAccountsByBorrower(address(this));
        console.log("V2 credit accounts", cas.length);

        cas = dc3.getCreditAccountsByBorrower(address(this), new PriceOnDemand[](0));
        console.log("V3 credit accounts", cas.length);
    }

    // function test_dc_04_borrower() public liveTestOnly {
    //     dc3.getCreditAccountsByBorrower(0xf13df765f3047850Cede5aA9fDF20a12A75f7F70, new PriceOnDemand[](0));
    // }
}

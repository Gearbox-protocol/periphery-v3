// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {VmSafe} from "forge-std/Vm.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IERC4626Adapter} from "@gearbox-protocol/integrations-v3/contracts/interfaces/erc4626/IERC4626Adapter.sol";
import {
    IERC20ZapperDeposits
} from "@gearbox-protocol/integrations-v3/contracts/interfaces/zappers/IERC20ZapperDeposits.sol";

import {ISecuritizeDegenNFT} from "../../../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "../../../interfaces/ISecuritizeKYCFactory.sol";
import {IDSToken} from "../../../interfaces/external/securitize/IDSToken.sol";

import {SecuritizeAttachTestHelper} from "./SecuritizeAttachTestHelper.sol";

contract SecuritizeDefaultLiquidityAttachTest is SecuritizeAttachTestHelper {
    address public factory;
    address public degenNFT;
    address public cUSDC;

    VmSafe.Wallet public investorWallet;
    address public investor;
    address public depositor;

    address public dsToken;
    address public registrar;

    address public pool;
    address public creditManager;
    address public zapper;

    function setUp() public {
        _setUp();

        // Roles and contracts deployment ---------------------------------------------------------------------------- //

        investorWallet = vm.createWallet("investor");
        investor = investorWallet.addr;
        depositor = makeAddr("depositor");

        factory = _deploy("KYC_FACTORY::SECURITIZE", 3_10, abi.encode(addressProvider, securitize));
        cUSDC = _deploy("KYC_UNDERLYING::DEFAULT", 3_10, abi.encode(addressProvider, factory, USDC, "Compliant ", "c"));
        degenNFT = ISecuritizeKYCFactory(factory).getDegenNFT();

        DSTokenInfo memory info = _attachSecuritize(degenNFT, investor);
        dsToken = info.token;
        registrar = info.registrar;

        // Instance owner actions ------------------------------------------------------------------------------------ //

        _addPriceFeed(USDC_PRICE_FEED, 1 days, "Chainlink USDC price feed");
        _allowPriceFeed(USDC, USDC_PRICE_FEED);
        _allowPriceFeed(cUSDC, USDC_PRICE_FEED);
        _allowPriceFeed(dsToken, onePriceFeed);

        _configureLocal(degenNFT, abi.encodeCall(ISecuritizeDegenNFT.addRegistrar, (registrar)));

        // Risk curator actions -------------------------------------------------------------------------------------- //

        // NOTE: adding degen NFT as periphery contract is required to use it in the credit suite
        _addPeripheryContract(degenNFT);

        // NOTE: mint small amount of underlying to risk curator to mint dead pool shares
        deal({token: USDC, to: riskCurator.addr, give: 1e5});
        _startOmniPrank(riskCurator);
        ERC20(USDC).approve(cUSDC, 1e5);
        ERC4626(cUSDC).deposit(1e5, address(marketConfigurator));
        _stopOmniPrank();

        MarketParams memory marketParams = _getDefaultMarketParams(cUSDC);
        marketParams.underlyingPriceFeed = USDC_PRICE_FEED;
        pool = _createMockMarket(cUSDC, marketParams);
        _addToken(
            pool,
            TokenParams({
                token: USDC,
                priceFeed: USDC_PRICE_FEED,
                reservePriceFeed: USDC_PRICE_FEED,
                quotaLimit: 10_000_000e6,
                quotaRate: 1
            })
        );
        _addToken(
            pool,
            TokenParams({
                token: dsToken,
                priceFeed: onePriceFeed,
                reservePriceFeed: onePriceFeed,
                quotaLimit: 10_000_000e6,
                quotaRate: 1
            })
        );
        // NOTE: updating rates also adds new tokens to the quota keeper
        _updateQuotaRates(pool);

        zapper = _deploy("ZAPPER::ERC4626_UNDERLYING", 3_10, abi.encode(pool));
        _addPeripheryContract(zapper);

        CreditSuiteParams memory creditSuiteParams = _getDefaultCreditSuiteParams();
        creditSuiteParams.debtLimit = 1_000_000e6;
        creditSuiteParams.minDebt = 50_000e6;
        creditSuiteParams.maxDebt = 1_000_000e6;
        creditSuiteParams.degenNFT = degenNFT;
        creditManager = _createMockCreditSuite(pool, creditSuiteParams);

        _addCollateralToken(creditManager, USDC, 98_00);
        _addCollateralToken(creditManager, dsToken, 90_00);
        _allowAdapter(creditManager, "ERC4626_VAULT", abi.encode(creditManager, cUSDC, address(0)));

        // NOTE: can't borrow in the same block as facade deployment
        vm.roll(block.number + 1);
    }

    function test_open_credit_account_via_securitize_factory() public {
        deal({token: USDC, to: depositor, give: 1_000_000e6});
        vm.prank(securitize);
        IDSToken(dsToken).issueTokens(investor, 60_000e18);

        vm.startPrank(depositor);
        ERC20(USDC).approve(zapper, 1_000_000e6);
        IERC20ZapperDeposits(zapper).deposit(1_000_000e6, depositor);
        vm.stopPrank();

        address wallet = ISecuritizeKYCFactory(factory).precomputeWalletAddress(creditManager, investor);
        vm.prank(investor);
        ERC20(dsToken).approve(wallet, 60_000e18);

        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address adapter = ICreditManagerV3(creditManager).contractToAdapter(cUSDC);

        MultiCall[] memory calls = new MultiCall[](5);
        calls[0] = MultiCall({
            target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (50_000e6))
        });
        calls[1] = MultiCall({target: adapter, callData: abi.encodeCall(IERC4626Adapter.redeemDiff, (1))});
        calls[2] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (USDC, type(uint256).max, investor))
        });
        calls[3] = MultiCall({
            target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (dsToken, 60_000e18))
        });
        calls[4] = MultiCall({
            target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (dsToken, 54_000e6, 0))
        });

        ISecuritizeDegenNFT.RegisterMessage[] memory messages = new ISecuritizeDegenNFT.RegisterMessage[](1);
        messages[0] = _signRegisterVaultMessage(investorWallet, registrar, degenNFT);

        vm.prank(investor);
        ISecuritizeKYCFactory(factory).openCreditAccount(creditManager, calls, messages);
    }
}

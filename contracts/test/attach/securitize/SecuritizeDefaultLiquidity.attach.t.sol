// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {PriceFeedMock} from "@gearbox-protocol/core-v3/contracts/test/mocks/oracles/PriceFeedMock.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {DefaultKYCUnderlying} from "../../../kyc/DefaultKYCUnderlying.sol";
import {SecuritizeDegenNFT} from "../../../kyc/SecuritizeDegenNFT.sol";
import {SecuritizeKYCFactory} from "../../../kyc/SecuritizeKYCFactory.sol";

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IERC4626Adapter} from "@gearbox-protocol/integrations-v3/contracts/interfaces/erc4626/IERC4626Adapter.sol";
import {ERC4626UnderlyingZapper} from "@gearbox-protocol/integrations-v3/contracts/zappers/ERC4626UnderlyingZapper.sol";

import {MockDSToken} from "./mocks/MockDSToken.sol";
import {MockRegistrar} from "./mocks/MockRegistrar.sol";

import {PeripheryAttachTestBase} from "../PeripheryAttachTestBase.sol";

contract SecuritizeDefaultLiquidityAttachTest is PeripheryAttachTestBase {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDC_PRICE_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address public factory;
    address public cUSDC;

    MockDSToken public dsToken;
    MockRegistrar public registrar;
    PriceFeedMock public dsTokenPriceFeed;

    address public securitize;
    address public investor;
    address public depositor;

    address public pool;
    address public creditManager;
    address public zapper;

    function setUp() public {
        super._setUp();
        vm.skip(block.chainid != 1, "Not Ethereum mainnet");
        _attachMarketConfigurator();

        // Roles, mocks and contracts deployment --------------------------------------------------------------------- //

        securitize = makeAddr("securitize");
        investor = makeAddr("investor");
        depositor = makeAddr("depositor");

        dsToken = new MockDSToken(securitize);
        registrar = new MockRegistrar(securitize, address(dsToken));
        dsTokenPriceFeed = new PriceFeedMock({_price: 1e8, _decimals: 8});

        _addPublicDomain("KYC_FACTORY");
        _addPublicDomain("KYC_UNDERLYING");

        _uploadContract("DEGEN_NFT::SECURITIZE", 3_10, type(SecuritizeDegenNFT).creationCode);
        _uploadContract("KYC_FACTORY::SECURITIZE", 3_10, type(SecuritizeKYCFactory).creationCode);
        _uploadContract("KYC_UNDERLYING::DEFAULT", 3_10, type(DefaultKYCUnderlying).creationCode);
        _uploadContract("ZAPPER::ERC4626_UNDERLYING", 3_10, type(ERC4626UnderlyingZapper).creationCode);

        factory = _deploy("KYC_FACTORY::SECURITIZE", 3_10, abi.encode(addressProvider, securitize));
        cUSDC = _deploy("KYC_UNDERLYING::DEFAULT", 3_10, abi.encode(factory, USDC, "Compliant ", "c"));

        // Securitize actions ---------------------------------------------------------------------------------------- //

        vm.startPrank(securitize);
        dsToken.authorize(investor);
        dsToken.setRegistrar(address(registrar), true);
        registrar.grantOperator(factory);
        vm.stopPrank();

        // Instance owner actions ------------------------------------------------------------------------------------ //

        _configureLocal(factory, abi.encodeCall(SecuritizeKYCFactory.addRegistrar, (address(registrar))));

        _addPriceFeed(USDC_PRICE_FEED, 1 days, "Chainlink USDC price feed");
        _allowPriceFeed(USDC, USDC_PRICE_FEED);
        _allowPriceFeed(cUSDC, USDC_PRICE_FEED);

        _addPriceFeed(address(dsTokenPriceFeed), 1 days, "Mock DSToken price feed");
        _allowPriceFeed(address(dsToken), address(dsTokenPriceFeed));

        // Risk curator actions -------------------------------------------------------------------------------------- //

        // NOTE: adding degen NFT as periphery contract is required to use it in the credit suite
        address degenNFT = SecuritizeKYCFactory(factory).getDegenNFT();
        _addPeripheryContract(degenNFT);

        // NOTE: mint small amount of underlying to risk curator to mint dead pool shares
        deal({token: USDC, to: riskCurator, give: 1e5});
        vm.startPrank(riskCurator);
        ERC20(USDC).approve(cUSDC, 1e5);
        ERC4626(cUSDC).deposit(1e5, address(marketConfigurator));
        vm.stopPrank();

        MarketParams memory marketParams = _getDefaultMarketParams(cUSDC);
        marketParams.underlyingPriceFeed = address(USDC_PRICE_FEED);
        pool = _createMockMarket(cUSDC, marketParams);
        _addToken(
            pool,
            TokenConfig({
                token: USDC,
                priceFeed: USDC_PRICE_FEED,
                reservePriceFeed: USDC_PRICE_FEED,
                quotaLimit: 10_000_000e6,
                quotaRate: 1
            })
        );
        _addToken(
            pool,
            TokenConfig({
                token: address(dsToken),
                priceFeed: address(dsTokenPriceFeed),
                reservePriceFeed: address(dsTokenPriceFeed),
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
        _addCollateralToken(creditManager, address(dsToken), 90_00);
        _allowAdapter(creditManager, "ERC4626_VAULT", abi.encode(creditManager, cUSDC, address(0)));

        // NOTE: can't borrow in the same block as facade deployment
        vm.roll(block.number + 1);
    }

    function test_open_credit_account_via_securitize_factory() public {
        deal({token: USDC, to: depositor, give: 1_000_000e6});
        deal({token: address(dsToken), to: investor, give: 60_000e18});

        vm.startPrank(depositor);
        ERC20(USDC).approve(zapper, 1_000_000e6);
        ERC4626UnderlyingZapper(zapper).deposit(1_000_000e6, depositor);
        vm.stopPrank();

        address wallet = SecuritizeKYCFactory(factory).precomputeWalletAddress(creditManager, investor);
        vm.prank(investor);
        ERC20(address(dsToken)).approve(wallet, 60_000e18);

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
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (address(dsToken), 60_000e18))
        });
        calls[4] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (address(dsToken), 54_000e6, 0))
        });

        address[] memory tokensToRegister = new address[](1);
        tokensToRegister[0] = address(dsToken);

        vm.prank(investor);
        SecuritizeKYCFactory(factory).openCreditAccount(creditManager, calls, tokensToRegister);
    }
}

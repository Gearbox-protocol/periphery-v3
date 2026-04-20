// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AttachTestBase} from "@gearbox-protocol/permissionless/contracts/test/suite/AttachTestBase.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";

import {IERC4626Adapter} from "@gearbox-protocol/integrations-v3/contracts/interfaces/erc4626/IERC4626Adapter.sol";

import {ISecuritizeDegenNFT} from "../../../interfaces/ISecuritizeDegenNFT.sol";
import {ISecuritizeKYCFactory} from "../../../interfaces/ISecuritizeKYCFactory.sol";
import {IDSToken} from "../../../interfaces/external/securitize/IDSToken.sol";

import {SecuritizeAttachHelper} from "./SecuritizeAttachHelper.sol";

contract SecuritizeOnDemandLiquidityAttachTest is Test, SecuritizeAttachHelper {
    address public cUSDC;
    address public pool;
    address[] public creditManagers;
    address public liquidityProvider;

    VmSafe.Wallet public investor;
    address public depositor;

    function setUp() public {
        vm.skip(ADDRESS_PROVIDER.code.length == 0, "Not in an attach mode");
        vm.skip(block.chainid != 1, "Not Ethereum mainnet");
        // NOTE: even though we compile our contracts under Shanghai EVM version,
        // more recent one is usually needed to interact with third-party contracts
        vm.setEvmVersion("osaka");

        deployer = vm.createWallet("Fake Deployer");
        author = vm.createWallet("Fake Author");
        auditor = vm.createWallet("Fake Auditor");
        riskCurator = vm.createWallet("Fake Risk Curator");

        deal({token: USDC, to: riskCurator.addr, give: 100_000e6});

        securitize = makeAddr("securitize");
        investor = vm.createWallet("investor");
        depositor = makeAddr("depositor");

        _setUp();
        _setUpBytecode();
        _attachSecuritize(investor.addr);

        // NOTE: adding degen NFT as periphery contract is required to use it in the credit suite
        _addPeripheryContract(degenNFT);

        _addPriceFeed(USDC_PRICE_FEED, 1 days, "Chainlink USDC price feed");
        _allowPriceFeed(USDC, USDC_PRICE_FEED);
        for (uint256 i; i < dsTokens.length; ++i) {
            _allowPriceFeed(dsTokens[i].token, onePriceFeed);
            _configureLocal(degenNFT, abi.encodeCall(ISecuritizeDegenNFT.addRegistrar, (dsTokens[i].registrar)));
        }

        (cUSDC, pool, creditManagers, liquidityProvider) = _createMarketWithOnDemandKYCUnderlying(depositor);

        // NOTE: can't borrow in the same block as facade deployment
        vm.roll(block.number + 1);
    }

    function test_open_credit_account_via_securitize_factory() public repeatTestForEachDSToken {
        deal({token: USDC, to: depositor, give: 1_000_000e6});
        vm.prank(securitize);
        IDSToken(dsTokens[idx].token).issueTokens(investor.addr, 60_000e18);

        vm.prank(depositor);
        ERC20(USDC).approve(liquidityProvider, 1_000_000e6);

        address wallet = ISecuritizeKYCFactory(factory).precomputeWalletAddress(creditManagers[idx], investor.addr);
        _omniPrank(investor);
        ERC20(dsTokens[idx].token).approve(wallet, 60_000e18);

        address creditFacade = ICreditManagerV3(creditManagers[idx]).creditFacade();
        address adapter = ICreditManagerV3(creditManagers[idx]).contractToAdapter(cUSDC);

        MultiCall[] memory calls = new MultiCall[](5);
        calls[0] = MultiCall({
            target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (50_000e6))
        });
        calls[1] = MultiCall({target: adapter, callData: abi.encodeCall(IERC4626Adapter.redeemDiff, (1))});
        calls[2] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.withdrawCollateral, (USDC, type(uint256).max, investor.addr)
            )
        });
        calls[3] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (dsTokens[idx].token, 60_000e18))
        });
        calls[4] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (dsTokens[idx].token, 54_000e6, 0))
        });

        address[] memory tokensToRegister = new address[](1);
        tokensToRegister[0] = dsTokens[idx].token;

        ISecuritizeDegenNFT.RegisterMessage[] memory signaturesToCache = new ISecuritizeDegenNFT.RegisterMessage[](1);
        signaturesToCache[0] = _signRegisterVaultMessage(investor, dsTokens[idx]);

        _omniPrank(investor);
        ISecuritizeKYCFactory(factory)
            .openCreditAccount(creditManagers[idx], calls, tokensToRegister, signaturesToCache);
    }
}

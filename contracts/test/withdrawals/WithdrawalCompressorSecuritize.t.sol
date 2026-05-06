// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditConfiguratorV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditConfiguratorV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {IPriceFeed} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeed.sol";
import {IPoolV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolV3.sol";
import {IPoolQuotaKeeperV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPoolQuotaKeeperV3.sol";
import {ITumblerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ITumblerV3.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IPriceFeedStore.sol";

import {VmSafe} from "forge-std/Vm.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Test} from "forge-std/Test.sol";
import {WithdrawalCompressor} from "../../compressors/WithdrawalCompressor.sol";
import {
    SecuritizeRedemptionSubcompressor
} from "../../compressors/subcompressors/withdrawal/SecuritizeRedemptionSubcompressor.sol";
import {
    SecuritizeRedemptionGateway
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionGateway.sol";
import {
    SecuritizeRedemptionPhantomToken
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedemptionPhantomToken.sol";
import {
    SecuritizeRedemptionGatewayAdapter
} from "@gearbox-protocol/integrations-v3/contracts/adapters/securitize/SecuritizeRedemptionGatewayAdapter.sol";
import {
    SecuritizeLiquidator
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeLiquidator.sol";
import {
    SecuritizeRedeemer
} from "@gearbox-protocol/integrations-v3/contracts/helpers/securitize/SecuritizeRedeemer.sol";

import {
    WithdrawalLib,
    WithdrawalOutput,
    WithdrawableAsset,
    RequestableWithdrawal,
    ClaimableWithdrawal,
    PendingWithdrawal
} from "../../types/WithdrawalInfo.sol";
import "forge-std/console.sol";

interface IVaultRegistrar {
    function operatorNonce(address investor, address operator) external view returns (uint256);
}

interface ISecuritizeNAVProvider {
    function rate() external view returns (uint256);
}

interface ISecuritizeDegenNFT {
    struct Signature {
        uint256 deadline;
        bytes signature;
    }

    struct RegisterMessage {
        address token;
        Signature signature;
    }
    function getDSTokens() external view returns (address[] memory);
    function getRegistrar(address token) external view returns (address);
    function setOperatorStatus(address operator, address gateway, bool status) external;
}

interface ISecuritizeKYCFactory {
    function precomputeWalletAddress(address creditManager, address investor) external view returns (address);
    function openCreditAccount(
        address creditManager,
        MultiCall[] calldata calls,
        address[] calldata tokensToRegister,
        ISecuritizeDegenNFT.RegisterMessage[] calldata signaturesToCache
    ) external returns (address creditAccount, address wallet);
    function multicall(
        address creditAccount,
        MultiCall[] calldata calls,
        address[] calldata tokensToRegister,
        ISecuritizeDegenNFT.RegisterMessage[] calldata signaturesToCache
    ) external;
    function getDegenNFT() external view returns (address);
    function isCreditAccount(address creditAccount) external view returns (bool);
}

contract WithdrawalCompressorTest is Test {
    using Address for address;

    WithdrawalCompressor public wc;
    SecuritizeRedemptionSubcompressor public srssc;

    address public kycFactory;
    VmSafe.Wallet public investor;
    address public securitizeDegenNFT;
    address[] public dsTokens;
    address public wallet;

    address public creditManager;

    address public redemptionGateway;
    address public securitizeLiquidator;

    address user;

    function setUp() public {
        user = makeAddr("user");
        address addressProvider = makeAddr("addressProvider");

        wc = new WithdrawalCompressor(address(this), addressProvider);
        srssc = new SecuritizeRedemptionSubcompressor();

        wc.setSubcompressor(address(srssc));
        wc.setWithdrawableTypeToCompressorType("PHANTOM_TOKEN::SECURITIZE_RD", "GLOBAL::SECURITIZE_WD_SC");
        creditManager = vm.envOr("ATTACH_CREDIT_MANAGER", address(0));
        kycFactory = vm.envOr("SECURITIZE_KYC_FACTORY", address(0));
        if (kycFactory == address(0)) {
            return;
        }
        securitizeDegenNFT = ISecuritizeKYCFactory(kycFactory).getDegenNFT();
        dsTokens = ISecuritizeDegenNFT(securitizeDegenNFT).getDSTokens();
        uint256 investorPrivateKey = vm.envOr("INVESTOR_PRIVATE_KEY", uint256(0));
        investor = vm.createWallet(investorPrivateKey);
        user = investor.addr;
        wallet = ISecuritizeKYCFactory(kycFactory).precomputeWalletAddress(address(creditManager), investor.addr);

        securitizeLiquidator = vm.envOr("SECURITIZE_LIQUIDATOR", address(0));
        redemptionGateway = vm.envOr("SECURITIZE_REDEMPTION_GATEWAY", address(0));

        address newSecuritizeLiquidator = address(new SecuritizeLiquidator(kycFactory));

        vm.etch(securitizeLiquidator, address(newSecuritizeLiquidator).code);
    }

    function test_WCS_01_testWithdrawalsSecuritize() public {
        address creditAccount = _openCreditAccount();

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;
            uint256 amount = 50 * 10 ** IERC20Metadata(token).decimals();
            deal(token, creditAccount, amount);

            RequestableWithdrawal memory requestableWithdrawal =
                wc.getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount);

            vm.prank(user);
            ISecuritizeKYCFactory(kycFactory)
                .multicall(
                    creditAccount,
                    requestableWithdrawal.requestCalls,
                    new address[](0),
                    new ISecuritizeDegenNFT.RegisterMessage[](0)
                );

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);

            wc.getCurrentWithdrawals(creditAccount);

            _fulfillWithdrawal(
                creditAccount, withdrawableAssets[i].withdrawalPhantomToken, requestableWithdrawal.claimableAt
            );

            (ClaimableWithdrawal[] memory claimableWithdrawals,) = wc.getCurrentWithdrawals(creditAccount);

            vm.prank(user);
            ISecuritizeKYCFactory(kycFactory)
                .multicall(
                    creditAccount,
                    claimableWithdrawals[0].claimCalls,
                    new address[](0),
                    new ISecuritizeDegenNFT.RegisterMessage[](0)
                );

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);
        }
    }

    function test_WCS_02_testLiquidationSecuritize() public {
        address creditAccount = _openCreditAccount();
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address underlying = ICreditManagerV3(creditManager).underlying();
        address pool = ICreditManagerV3(creditManager).pool();

        WithdrawableAsset[] memory withdrawableAssets = wc.getWithdrawableAssets(creditManager);

        for (uint256 i = 0; i < withdrawableAssets.length; i++) {
            address token = withdrawableAssets[i].token;
            address withdrawalToken = withdrawableAssets[i].withdrawalPhantomToken;
            uint256 amount = 500 * 10 ** IERC20Metadata(token).decimals();
            deal(token, creditAccount, amount);

            RequestableWithdrawal memory requestableWithdrawal =
                wc.getWithdrawalRequestResult(creditAccount, token, withdrawalToken, amount);

            vm.prank(user);
            ISecuritizeKYCFactory(kycFactory)
                .multicall(
                    creditAccount,
                    requestableWithdrawal.requestCalls,
                    new address[](0),
                    new ISecuritizeDegenNFT.RegisterMessage[](0)
                );

            IERC20(withdrawableAssets[i].withdrawalPhantomToken).balanceOf(creditAccount);
            IERC20(withdrawableAssets[i].underlying).balanceOf(creditAccount);

            uint256 debtAmount = requestableWithdrawal.outputs[0].amount * 9200 / 10000;

            // {
            //     uint256 stableCoinAmount = requestableWithdrawal.outputs[0].amount / 10;
            //     deal(withdrawableAssets[i].underlying, creditAccount, stableCoinAmount);
            //     debtAmount += stableCoinAmount * 9850 / 10000;
            // }

            {
                deal(token, creditAccount, amount / 100);
                debtAmount += requestableWithdrawal.outputs[0].amount * 9200 / 1000000;
            }

            vm.prank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
            IERC20(withdrawableAssets[i].underlying).transfer(user, debtAmount * 5);

            vm.startPrank(user);
            IERC20(withdrawableAssets[i].underlying).approve(underlying, type(uint256).max);
            IERC4626(underlying).deposit(debtAmount * 5, user);
            IERC20(underlying).transfer(pool, debtAmount * 3);
            IERC20(underlying).approve(securitizeLiquidator, type(uint256).max);
            vm.stopPrank();

            MultiCall[] memory calls = new MultiCall[](3);
            calls[0] = MultiCall({
                target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
            });
            calls[1] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota,
                    (withdrawableAssets[i].withdrawalPhantomToken, int96(uint96(debtAmount * 2)), 0)
                )
            });
            // calls[2] = MultiCall({
            //     target: creditFacade,
            //     callData: abi.encodeCall(
            //         ICreditFacadeV3Multicall.updateQuota,
            //         (withdrawableAssets[i].underlying, int96(uint96(debtAmount * 2)), 0)
            //     )
            // });
            calls[2] = MultiCall({
                target: creditFacade,
                callData: abi.encodeCall(
                    ICreditFacadeV3Multicall.updateQuota, (token, int96(uint96(debtAmount * 2)), 0)
                )
            });

            vm.prank(user);
            ISecuritizeKYCFactory(kycFactory)
                .multicall(creditAccount, calls, new address[](0), new ISecuritizeDegenNFT.RegisterMessage[](0));

            vm.roll(block.number + 1);

            vm.prank(creditAccount);
            IERC20(underlying).transfer(user, debtAmount);

            vm.mockCall( 
                0x8fAc01686D4C7444C31152AaC025B45Cb0a95ccD,
                abi.encodeWithSelector(ISecuritizeNAVProvider.rate.selector),
                abi.encode(1150000000)
            );

            vm.prank(user);
            SecuritizeLiquidator(securitizeLiquidator)
                .liquidatePendingRedemption(creditAccount, redemptionGateway, new PriceUpdate[](0));

            SecuritizeRedemptionGateway(redemptionGateway).getUnclaimedRedeemers(creditAccount);
            SecuritizeRedemptionGateway(redemptionGateway).getUnclaimedRedeemers(user);
        }
    }

    function _fulfillWithdrawal(address creditAccount, address withdrawalPhantomToken, uint256 claimableAt) public {
        bytes32 cType = IVersion(withdrawalPhantomToken).contractType();

        if (cType == "PHANTOM_TOKEN::SECURITIZE_RD") {
            vm.mockCall(
                0x8fAc01686D4C7444C31152AaC025B45Cb0a95ccD,
                abi.encodeWithSelector(ISecuritizeNAVProvider.rate.selector),
                abi.encode(1150000000)
            );
            vm.warp(claimableAt + 1);
            address redeemer = SecuritizeRedemptionGateway(redemptionGateway).getRedeemers(creditAccount)[0];
            uint256 redemptionValue = SecuritizeRedeemer(redeemer).getCurrentRedemptionValue();
            address token = SecuritizeRedemptionPhantomToken(withdrawalPhantomToken).stableCoinToken();
            vm.prank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
            IERC20(token).transfer(redeemer, redemptionValue);
        }
    }

    function _openCreditAccount() internal returns (address creditAccount) {
        ISecuritizeDegenNFT.RegisterMessage[] memory signaturesToCache = new ISecuritizeDegenNFT.RegisterMessage[](1);
        address[] memory dsToken = new address[](1);
        for (uint256 i = 0; i < dsTokens.length; i++) {
            try ICreditManagerV3(creditManager).getTokenMaskOrRevert(dsTokens[i]) returns (uint256) {
                signaturesToCache[0] = _signRegisterVaultMessage(investor, dsTokens[i]);
                dsToken[0] = dsTokens[i];
                break;
            } catch {}
        }

        vm.prank(user);
        (creditAccount,) = ISecuritizeKYCFactory(kycFactory)
            .openCreditAccount(address(creditManager), new MultiCall[](0), dsToken, signaturesToCache);
    }

    // function _prepareTest() internal {
    //     address creditConfigurator = ICreditManagerV3(creditManager).creditConfigurator();
    //     address priceOracle = ICreditManagerV3(creditManager).priceOracle();
    //     address acl = ICreditConfiguratorV3(creditConfigurator).acl();
    //     address configurator = Ownable(acl).owner();

    //     securitizeLiquidator = address(new SecuritizeLiquidator(kycFactory));

    //     redemptionGateway = address(
    //         new SecuritizeRedemptionGateway(
    //             0x17418038ecF73BA4026c4f428547BF099706F27B, // ACRED
    //             0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
    //             0xa0759A0DFdE5395a1892aEd90eB5665698CFaa05, // LARGE ACRED HOLDER
    //             securitizeDegenNFT,
    //             securitizeLiquidator,
    //             0x8fAc01686D4C7444C31152AaC025B45Cb0a95ccD // ACRED NAV PROVIDER
    //         )
    //     );

    //     address redemptionPhantomToken = address(new SecuritizeRedemptionPhantomToken(redemptionGateway));

    //     address usdcPF = IPriceOracleV3(priceOracle).priceFeeds(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    //     vm.mockCall(
    //         usdcPF,
    //         abi.encodeWithSelector(IPriceFeed.latestRoundData.selector),
    //         abi.encode(1800, 10 ** 8, block.timestamp, block.timestamp, 1800)
    //     );

    //     vm.startPrank(configurator);
    //     IPriceOracleV3(priceOracle).setPriceFeed(redemptionPhantomToken, usdcPF, 1800);
    //     IPriceOracleV3(priceOracle).setReservePriceFeed(redemptionPhantomToken, usdcPF, 1800);
    //     {
    //         address pool = ICreditManagerV3(creditManager).pool();
    //         address poolQuotaKeeper = IPoolV3(pool).poolQuotaKeeper();
    //         address tumbler = IPoolQuotaKeeperV3(poolQuotaKeeper).gauge();
    //         ITumblerV3(tumbler).addToken(redemptionPhantomToken);
    //         ITumblerV3(tumbler).updateRates();
    //         IPoolQuotaKeeperV3(poolQuotaKeeper).setTokenLimit(redemptionPhantomToken, 1000000000 * 1e6);
    //     }
    //     ICreditConfiguratorV3(creditConfigurator).addCollateralToken(redemptionPhantomToken, 9000);
    //     vm.stopPrank();

    //     address redemptionGatewayAdapter =
    //         address(new SecuritizeRedemptionGatewayAdapter(creditManager, redemptionGateway, redemptionPhantomToken));

    //     vm.prank(configurator);
    //     ICreditConfiguratorV3(creditConfigurator).allowAdapter(redemptionGatewayAdapter);

    //     vm.prank(0xBcD875f0D62B9AA22481c81975F9AE1753Fc559A);
    //     ISecuritizeDegenNFT(securitizeDegenNFT)
    //         .setOperatorStatus(0x17418038ecF73BA4026c4f428547BF099706F27B, redemptionGateway, true);
    // }

    function _sign(VmSafe.Wallet memory signer, bytes32 domainSeparator, bytes32 structHash)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest = ECDSA.toTypedDataHash(domainSeparator, structHash);
        if (signer.privateKey != 0) {
            // for test contexts and script contexts where the private key is known, e.g.,
            // with explicitly set `--private-key` flag
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, digest);
            return abi.encodePacked(r, s, v);
        } else if (signer.addr != address(0)) {
            // for script contexts where the private key is not known, e.g.,
            // with `--keystore` or `--ledger` flags
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.addr, digest);
            return abi.encodePacked(r, s, v);
        }
        revert("Signer not initialized");
    }

    function _buildDomainSeparator(address eip712Contract) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            IERC5267(eip712Contract).eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function _signRegisterVaultMessage(VmSafe.Wallet memory signer, address dsToken)
        internal
        view
        returns (ISecuritizeDegenNFT.RegisterMessage memory message)
    {
        address registrar = ISecuritizeDegenNFT(securitizeDegenNFT).getRegistrar(dsToken);

        bytes32 domainSeparator = _buildDomainSeparator(registrar);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "RegisterVault(address investor,address operator,address token,uint256 nonce,uint256 deadline)"
                ),
                signer.addr,
                securitizeDegenNFT,
                dsToken,
                IVaultRegistrar(registrar).operatorNonce(signer.addr, securitizeDegenNFT),
                type(uint256).max
            )
        );
        return ISecuritizeDegenNFT.RegisterMessage({
            token: dsToken,
            signature: ISecuritizeDegenNFT.Signature({
                deadline: type(uint256).max, signature: _sign(signer, domainSeparator, structHash)
            })
        });
    }
}

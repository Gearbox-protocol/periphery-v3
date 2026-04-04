// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {VmSafe} from "forge-std/Vm.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {AttachTestBase} from "@gearbox-protocol/permissionless/contracts/test/suite/AttachTestBase.sol";

import {ERC4626UnderlyingZapper} from "@gearbox-protocol/integrations-v3/contracts/zappers/ERC4626UnderlyingZapper.sol";

import {ISecuritizeDegenNFT} from "../../../interfaces/ISecuritizeDegenNFT.sol";
import {IDSRegistryService} from "../../../interfaces/external/securitize/IDSRegistryService.sol";
import {IDSServiceConsumer} from "../../../interfaces/external/securitize/IDSServiceConsumer.sol";
import {IDSTrustService} from "../../../interfaces/external/securitize/IDSTrustService.sol";
import {IVaultRegistrar} from "../../../interfaces/external/securitize/IVaultRegistrar.sol";

import {DefaultKYCUnderlying} from "../../../kyc/DefaultKYCUnderlying.sol";
import {MonopolizedOnDemandLP} from "../../../kyc/MonopolizedOnDemandLP.sol";
import {OnDemandKYCUnderlying} from "../../../kyc/OnDemandKYCUnderlying.sol";
import {SecuritizeDegenNFT} from "../../../kyc/SecuritizeDegenNFT.sol";
import {SecuritizeKYCFactory} from "../../../kyc/SecuritizeKYCFactory.sol";

import {MockDSToken} from "./mocks/MockDSToken.sol";
import {MockVaultRegistrar} from "./mocks/MockVaultRegistrar.sol";

contract SecuritizeAttachTestHelper is AttachTestBase {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDC_PRICE_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address public securitize;

    function _setUp() internal override {
        vm.skip(ADDRESS_PROVIDER.code.length == 0, "Not in an attach mode");
        vm.skip(block.chainid != 1, "Not Ethereum mainnet");
        // NOTE: even though we compile our contracts under Shanghai EVM version,
        // more recent one is usually needed to interact with third-party contracts
        vm.setEvmVersion("osaka");

        super._setUp();

        _addPublicDomain("KYC_FACTORY");
        _addPublicDomain("KYC_UNDERLYING");
        _addPublicDomain("ON_DEMAND_LP");

        _uploadContract("DEGEN_NFT::SECURITIZE", 3_10, type(SecuritizeDegenNFT).creationCode);
        _uploadContract("KYC_FACTORY::SECURITIZE", 3_10, type(SecuritizeKYCFactory).creationCode);
        _uploadContract("KYC_UNDERLYING::DEFAULT", 3_10, type(DefaultKYCUnderlying).creationCode);
        _uploadContract("KYC_UNDERLYING::ON_DEMAND", 3_10, type(OnDemandKYCUnderlying).creationCode);
        _uploadContract("ON_DEMAND_LP::MONOPOLIZED", 3_10, type(MonopolizedOnDemandLP).creationCode);
        _uploadContract("ZAPPER::ERC4626_UNDERLYING", 3_10, type(ERC4626UnderlyingZapper).creationCode);

        securitize = makeAddr("securitize");
    }

    function _attachSecuritize(address degenNFT, address investor) internal returns (DSTokenInfo memory info) {
        address vaultRegistrar = vm.envOr("VAULT_REGISTRAR", address(0));
        if (vaultRegistrar != address(0)) {
            info = _attachWithLiveRegistrar(vaultRegistrar, degenNFT, investor);
        } else {
            address dsToken = vm.envOr("DS_TOKEN", address(0));
            if (dsToken != address(0)) {
                info = _attachWithMockRegistrar(dsToken, degenNFT, investor);
            } else {
                info = _attachWithMockDSToken(degenNFT, investor);
            }
        }
    }

    struct DSTokenInfo {
        address token;
        address registryService;
        address trustService;
        address registrar;
    }

    function _attachWithMockDSToken(address degenNFT, address investor) internal returns (DSTokenInfo memory info) {
        info.token = address(new MockDSToken(securitize));
        info.registrar = address(new MockVaultRegistrar(securitize, info.token));
        info.registryService = info.token;
        info.trustService = info.token;

        vm.startPrank(securitize);
        MockDSToken(info.token).registerInvestor("Fake investor", "Fake investor");
        MockDSToken(info.token).addWallet(investor, "Fake investor");
        MockDSToken(info.token).setRegistrar(info.registrar, true);
        IVaultRegistrar(info.registrar).addOperator(degenNFT);
        vm.stopPrank();
    }

    function _attachWithMockRegistrar(address token, address degenNFT, address investor)
        internal
        returns (DSTokenInfo memory info)
    {
        info.token = token;
        info.registryService = IDSServiceConsumer(token).getDSService(IDSServiceConsumer(token).REGISTRY_SERVICE());
        info.trustService = IDSServiceConsumer(token).getDSService(IDSServiceConsumer(token).TRUST_SERVICE());
        info.registrar = address(new MockVaultRegistrar(securitize, token));

        address master = address(uint160(uint256(vm.load(info.trustService, bytes32(0)))));
        vm.prank(master);
        IDSTrustService(info.trustService).setServiceOwner(securitize);

        vm.startPrank(securitize);
        IDSTrustService(info.trustService).setRole(info.registrar, IDSTrustService(info.trustService).TRANSFER_AGENT());
        IDSRegistryService(info.registryService).registerInvestor("Fake investor", "Fake collision hash");
        IDSRegistryService(info.registryService).addWallet(investor, "Fake investor");
        IVaultRegistrar(info.registrar).addOperator(degenNFT);
        vm.stopPrank();
    }

    function _attachWithLiveRegistrar(address registrar, address degenNFT, address investor)
        internal
        returns (DSTokenInfo memory info)
    {
        info.token = IVaultRegistrar(registrar).token();
        info.registryService =
            IDSServiceConsumer(info.token).getDSService(IDSServiceConsumer(info.token).REGISTRY_SERVICE());
        info.trustService = IDSServiceConsumer(info.token).getDSService(IDSServiceConsumer(info.token).TRUST_SERVICE());
        info.registrar = registrar;

        address master = address(uint160(uint256(vm.load(info.trustService, bytes32(0)))));
        vm.prank(master);
        IDSTrustService(info.trustService).setServiceOwner(securitize);

        vm.startPrank(securitize);
        IDSTrustService(info.trustService).setRole(info.registrar, IDSTrustService(info.trustService).TRANSFER_AGENT());
        IDSRegistryService(info.registryService).registerInvestor("Fake investor", "Fake collision hash");
        IDSRegistryService(info.registryService).addWallet(investor, "Fake investor");
        IVaultRegistrar(info.registrar).addOperator(degenNFT);
        vm.stopPrank();
    }

    function _signRegisterVaultMessage(VmSafe.Wallet memory investor, address registrar, address operator)
        internal
        returns (ISecuritizeDegenNFT.RegisterMessage memory message)
    {
        address token = IVaultRegistrar(registrar).token();
        bytes32 domainSeparator = _buildDomainSeparator(registrar);
        bytes32 messageHash = keccak256(
            abi.encode(
                keccak256(
                    "RegisterVault(address investor,address operator,address token,uint256 nonce,uint256 deadline)"
                ),
                investor.addr,
                operator,
                token,
                IVaultRegistrar(registrar).operatorNonce(investor.addr, operator),
                type(uint256).max
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(domainSeparator, messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(investor, digest);
        return ISecuritizeDegenNFT.RegisterMessage({
            token: token,
            signature: ISecuritizeDegenNFT.Signature({
                deadline: type(uint256).max, signature: abi.encodePacked(r, s, v)
            })
        });
    }
}

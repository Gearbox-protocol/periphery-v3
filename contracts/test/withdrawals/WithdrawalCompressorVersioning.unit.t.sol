// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2026.
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

import {WithdrawalCompressorHarness} from "./WithdrawalCompressorHarness.sol";
import {MockWithdrawalSubcompressor} from "./mocks/MockWithdrawalSubcompressor.sol";
import {MockWithdrawablePhantomToken} from "./mocks/MockWithdrawablePhantomToken.sol";

/// @title WithdrawalCompressor versioning unit tests
/// @notice U:[WC-V]: Unit tests for subcompressor type and version selection
contract WithdrawalCompressorVersioningUnitTest is Test {
    bytes32 internal constant WITHDRAWABLE_TYPE = "PHANTOM_TOKEN::TEST_WITHDRAWAL";
    bytes32 internal constant OTHER_WITHDRAWABLE_TYPE = "PHANTOM_TOKEN::OTHER_WITHDRAWAL";
    bytes32 internal constant COMPRESSOR_TYPE = "GLOBAL::TEST_WD_SC";
    bytes32 internal constant OTHER_COMPRESSOR_TYPE = "GLOBAL::OTHER_WD_SC";

    WithdrawalCompressorHarness internal wc;

    function setUp() public {
        wc = new WithdrawalCompressorHarness(address(this), makeAddr("addressProvider"));
    }

    /// @notice U:[WC-V-1]: Compressor type is chosen from the withdrawable type mapping
    function test_U_WC_V_01_picksCompressorTypeFromMapping() public {
        MockWithdrawalSubcompressor scA = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);
        MockWithdrawalSubcompressor scB = new MockWithdrawalSubcompressor(OTHER_COMPRESSOR_TYPE, 3_13);

        wc.setSubcompressor(address(scA));
        wc.setSubcompressor(address(scB));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);

        MockWithdrawablePhantomToken token = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_13);

        assertEq(wc.getCompressorForToken(address(token)), address(scA), "Incorrect compressor type mapping");
    }

    /// @notice U:[WC-V-2]: A specific compressor version override is used when configured
    function test_U_WC_V_02_usesSpecificCompressorVersionWhenSet() public {
        MockWithdrawalSubcompressor sc311 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_11);
        MockWithdrawalSubcompressor sc312 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_12);
        MockWithdrawalSubcompressor sc313 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);

        wc.setSubcompressor(address(sc311));
        wc.setSubcompressor(address(sc312));
        wc.setSubcompressor(address(sc313));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);
        wc.setWithdrawableVersionToSpecificCompressorVersion(WITHDRAWABLE_TYPE, 3_12, 3_11);

        MockWithdrawablePhantomToken token = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_12);

        assertEq(wc.getCompressorForToken(address(token)), address(sc311), "Specific compressor version not used");
    }

    /// @notice U:[WC-V-3]: Without a specific override, the latest patch for the same minor version is used
    function test_U_WC_V_03_usesLatestPatchForSameMinorWhenNoSpecificVersion() public {
        MockWithdrawalSubcompressor sc311 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_11);
        MockWithdrawalSubcompressor sc312 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_12);
        MockWithdrawalSubcompressor sc313 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);

        wc.setSubcompressor(address(sc311));
        wc.setSubcompressor(address(sc313));
        wc.setSubcompressor(address(sc312));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);

        MockWithdrawablePhantomToken token = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_11);

        assertEq(
            wc.getCompressorForToken(address(token)), address(sc313), "Latest patch for minor version not selected"
        );
    }

    /// @notice U:[WC-V-4]: Latest patch lookup is scoped to the withdrawable's minor version
    function test_U_WC_V_04_usesLatestPatchForMatchingMinorOnly() public {
        MockWithdrawalSubcompressor sc313 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);
        MockWithdrawalSubcompressor sc320 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_20);
        MockWithdrawalSubcompressor sc321 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_21);

        wc.setSubcompressor(address(sc313));
        wc.setSubcompressor(address(sc320));
        wc.setSubcompressor(address(sc321));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);

        MockWithdrawablePhantomToken token = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_20);

        assertEq(
            wc.getCompressorForToken(address(token)), address(sc321), "Latest patch for minor version 320 not selected"
        );
    }

    /// @notice U:[WC-V-5]: Specific compressor version overrides latest patch selection
    function test_U_WC_V_05_specificVersionOverridesLatestPatch() public {
        MockWithdrawalSubcompressor sc311 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_11);
        MockWithdrawalSubcompressor sc313 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);

        wc.setSubcompressor(address(sc311));
        wc.setSubcompressor(address(sc313));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);
        wc.setWithdrawableVersionToSpecificCompressorVersion(WITHDRAWABLE_TYPE, 3_11, 3_11);

        MockWithdrawablePhantomToken token = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_11);

        assertEq(wc.getCompressorForToken(address(token)), address(sc311), "Specific override should beat latest patch");
    }

    /// @notice U:[WC-V-6]: Unmapped withdrawable types resolve to the zero address
    function test_U_WC_V_06_returnsZeroWhenWithdrawableTypeNotMapped() public {
        MockWithdrawalSubcompressor sc313 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);
        wc.setSubcompressor(address(sc313));

        MockWithdrawablePhantomToken token = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_13);

        assertEq(wc.getCompressorForToken(address(token)), address(0), "Unmapped withdrawable should return zero");
    }

    /// @notice U:[WC-V-7]: Different withdrawable types can map to different compressor types
    function test_U_WC_V_07_differentWithdrawableTypesMapToDifferentCompressors() public {
        MockWithdrawalSubcompressor scA = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);
        MockWithdrawalSubcompressor scB = new MockWithdrawalSubcompressor(OTHER_COMPRESSOR_TYPE, 3_13);

        wc.setSubcompressor(address(scA));
        wc.setSubcompressor(address(scB));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);
        wc.setWithdrawableTypeToCompressorType(OTHER_WITHDRAWABLE_TYPE, OTHER_COMPRESSOR_TYPE);

        MockWithdrawablePhantomToken tokenA = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_13);
        MockWithdrawablePhantomToken tokenB = new MockWithdrawablePhantomToken(OTHER_WITHDRAWABLE_TYPE, 3_13);

        assertEq(wc.getCompressorForToken(address(tokenA)), address(scA), "First withdrawable mapping incorrect");
        assertEq(wc.getCompressorForToken(address(tokenB)), address(scB), "Second withdrawable mapping incorrect");
    }

    /// @notice U:[WC-V-8]: A newer withdrawable version resolves to the latest registered subcompressor
    ///         for the same minor, without a matching subcompressor version or a specific override
    function test_U_WC_V_08_newWithdrawableVersionResolvesToLatestSubcompressor() public {
        MockWithdrawalSubcompressor sc311 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_11);
        MockWithdrawalSubcompressor sc312 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_12);
        MockWithdrawalSubcompressor sc313 = new MockWithdrawalSubcompressor(COMPRESSOR_TYPE, 3_13);

        wc.setSubcompressor(address(sc311));
        wc.setSubcompressor(address(sc312));
        wc.setSubcompressor(address(sc313));
        wc.setWithdrawableTypeToCompressorType(WITHDRAWABLE_TYPE, COMPRESSOR_TYPE);

        MockWithdrawablePhantomToken token314 = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_14);
        MockWithdrawablePhantomToken token315 = new MockWithdrawablePhantomToken(WITHDRAWABLE_TYPE, 3_15);

        assertEq(
            wc.getCompressorForToken(address(token314)),
            address(sc313),
            "New withdrawable version should resolve to latest registered subcompressor"
        );

        assertEq(
            wc.getCompressorForToken(address(token315)),
            address(sc313),
            "New withdrawable version should resolve to latest registered subcompressor"
        );
    }
}

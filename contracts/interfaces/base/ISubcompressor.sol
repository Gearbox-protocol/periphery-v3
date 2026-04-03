// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISubcompressor {
    function getCompressedType() external view returns (bytes32 domain, bytes32 postfix);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {IDegenNFT} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IDegenNFT.sol";

interface ISecuritizeDegenNFT is IDegenNFT {
    event Mint(address indexed wallet);
    event Burn(address indexed wallet);

    error CallerIsNotCreditFacadeException(address caller);
    error CallerIsNotFactoryException(address caller);
    error DegenNFTAlreadyMintedException(address wallet);
    error DegenNFTNotMintedException(address wallet);

    function factory() external view returns (address);
    function isMinted(address wallet) external view returns (bool);
    function mint(address wallet) external;
    function burn(address wallet, uint256) external override;
}

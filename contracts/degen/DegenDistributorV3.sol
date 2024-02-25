// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {
    IAddressProviderV3,
    AP_TREASURY,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {IDegenNFTV2} from "@gearbox-protocol/core-v2/contracts/interfaces/IDegenNFTV2.sol";
import {IDegenDistributorV3} from "../interfaces/IDegenDistributorV3.sol";

bytes32 constant AP_DEGEN_NFT = "DEGEN_NFT";

contract DegenDistributorV3 is IDegenDistributorV3 {
    uint256 public constant version = 3_00;

    /// @dev Emits each time when call not by treasury
    error TreasuryOnlyException();

    /// @dev Returns the token distributed by the contract
    address public immutable override degenNFT;

    /// @dev DAO Treasury address
    address public immutable treasury;

    /// @dev The current merkle root of total claimable balances
    bytes32 public override merkleRoot;

    /// @dev The mapping that stores amounts already claimed by users
    mapping(address => uint256) public claimed;

    modifier treasuryOnly() {
        if (msg.sender != treasury) revert TreasuryOnlyException();
        _;
    }

    constructor(address addressProvider) {
        treasury = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
        degenNFT = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_DEGEN_NFT, 1);
    }

    function updateMerkleRoot(bytes32 newRoot) external treasuryOnly {
        bytes32 oldRoot = merkleRoot;
        merkleRoot = newRoot;
        emit RootUpdated(oldRoot, newRoot);
    }

    function claim(uint256 index, address account, uint256 totalAmount, bytes32[] calldata merkleProof)
        external
        override
    {
        require(claimed[account] < totalAmount, "MerkleDistributor: Nothing to claim");

        bytes32 node = keccak256(abi.encodePacked(index, account, totalAmount));
        require(MerkleProof.verify(merkleProof, merkleRoot, node), "MerkleDistributor: Invalid proof.");

        uint256 claimedAmount = totalAmount - claimed[account];
        claimed[account] += claimedAmount;
        IDegenNFTV2(degenNFT).mint(account, claimedAmount);

        emit Claimed(account, claimedAmount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IERC1271
 * @notice Interface for signature validation in smart contract wallets
 * @dev Standardized interface as defined in ERC-1271 for contract-based signatures
 */
interface IERC1271 {
    /**
     * @notice Magic value returned when signature is valid
     * @dev bytes4(keccak256("isValidSignature(bytes32,bytes)")
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

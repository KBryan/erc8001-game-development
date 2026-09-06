// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ECDSA
 * @notice Elliptic Curve Digital Signature Algorithm (ECDSA) operations
 * @dev Based on OpenZeppelin Contracts with EIP-2 malleability protection
 */
library ECDSA {
    
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    /**
     * @dev The signature derives the `address(0)`.
     */
    error ECDSAInvalidSignature();

    /**
     * @dev The signature has an invalid length.
     */
    error ECDSAInvalidSignatureLength(uint256 length);

    /**
     * @dev The signature has an S value that is in the upper half order.
     */
    error ECDSAInvalidSignatureS(bytes32 s);

    /**
     * @notice Recover signer address from hash and signature
     * @param hash keccak256 hash that was signed
     * @param signature Concatenated r, s, v values (65 bytes)
     * @return recovered The recovered address
     * @return err Recovery error status
     */
    function tryRecover(bytes32 hash, bytes memory signature)
        internal
        pure
        returns (address recovered, RecoverError err)
    {
        if (signature.length != 65) {
            return (address(0), RecoverError.InvalidSignatureLength);
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from signature
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        return tryRecover(hash, v, r, s);
    }

    /**
     * @notice Recover signer address from hash and signature components
     * @param hash keccak256 hash that was signed
     * @param v Recovery id (27 or 28)
     * @param r Signature r value
     * @param s Signature s value
     * @return recovered The recovered address
     * @return err Recovery error status
     */
    function tryRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (address recovered, RecoverError err)
    {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}
        
        // Check s is in lower half order (EIP-2 protection)
        bytes32 SECP256K1_N_DIV_2 = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
        if (uint256(s) > uint256(SECP256K1_N_DIV_2)) {
            return (address(0), RecoverError.InvalidSignatureS);
        }

        // Adjust v for Ethereum signed messages
        if (v != 27 && v != 28) {
            return (address(0), RecoverError.InvalidSignature);
        }

        // Recover address using the ecrecover builtin; it returns address(0)
        // on failure, which the check below converts into an explicit error.
        recovered = ecrecover(hash, v, r, s);

        if (recovered == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (recovered, RecoverError.NoError);
    }

    /**
     * @notice Recover signer address from hash and signature (reverts on failure)
     * @param hash keccak256 hash that was signed
     * @param signature Concatenated r, s, v values
     * @return The recovered address
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError err) = tryRecover(hash, signature);
        
        if (err == RecoverError.InvalidSignatureLength) {
            revert ECDSAInvalidSignatureLength(signature.length);
        }
        
        if (err == RecoverError.InvalidSignatureS) {
            bytes32 s;
            assembly ("memory-safe") {
                s := mload(add(signature, 0x60))
            }
            revert ECDSAInvalidSignatureS(s);
        }
        
        if (err != RecoverError.NoError) {
            revert ECDSAInvalidSignature();
        }

        return recovered;
    }

    /**
     * @notice Recover signer address from hash and signature components (reverts on failure)
     * @param hash keccak256 hash that was signed
     * @param v Recovery id
     * @param r Signature r value
     * @param s Signature s value
     * @return The recovered address
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError err) = tryRecover(hash, v, r, s);
        
        if (err == RecoverError.InvalidSignatureS) {
            revert ECDSAInvalidSignatureS(s);
        }
        
        if (err != RecoverError.NoError) {
            revert ECDSAInvalidSignature();
        }

        return recovered;
    }
}

# Gas Reference

## Introduction

Gas optimization is critical for gaming contracts where users make frequent, often small-value transactions. This appendix provides quick reference tables for common operations.

## Opcode Gas Costs

| **Category** | **Operation** | **Gas** |
|---|---|---|
| Arithmetic | ADD/SUB | 3 |
| Arithmetic | MUL | 5 |
| Arithmetic | DIV/SDIV | 5 |
| Arithmetic | MOD | 5 |
| Arithmetic | EXP | 10 + 50 * byte length |
| Comparison | LT/GT/SLT/SGT | 3 |
| Comparison | EQ | 3 |
| Comparison | ISZERO | 3 |
| Comparison | AND/OR/XOR/NOT | 3 |
| Memory | MLOAD | 3 |
| Memory | MSTORE | 3 + memory expansion |
| Memory | MSTORE8 | 3 + memory expansion |
| Storage | SLOAD (warm) | 100 |
| Storage | SLOAD (cold) | 2,100 |
| Storage | SSTORE (zero to nonzero) | 20,000 |
| Storage | SSTORE (nonzero to nonzero) | 2,900 cold / 100 warm |
| Storage | SSTORE (clearing to zero) | refunds 4,800 (post-London) |
| Control | JUMP | 8 |
| Control | JUMPI | 10 |
| Control | CALL (cold account) | 2,600 + memory |
| Control | CALL (warm account) | 100 + memory |

## Transaction Costs

| **Transaction Type** | **Base Gas** |
|---|---|
| Simple transfer | 21,000 |
| Token transfer (ERC20) | ~45,000 |
| ERC721 mint | ~60,000--150,000 |
| ERC1155 mint (single) | ~40,000 |
| Contract deployment | 32,000 + init code |

## Storage Optimization Patterns

| **Type** | **Bits** | **Per 256-bit Slot** |
|---|---|---|
| address | 160 | 1 |
| uint256 | 256 | 1 |
| uint128 | 128 | 2 |
| uint64 | 64 | 4 |
| uint32 | 32 | 8 |
| uint16 | 16 | 16 |
| uint8 | 8 | 32 |
| bool | 8 | 32 |

## Gas Optimization Checklist

- [ ] Pack storage variables so related values share a 256-bit slot
- [ ] Use custom errors instead of revert strings
- [ ] Use `calldata` instead of `memory` for external function parameters
- [ ] Apply `unchecked` only to provably-safe math (e.g., loop counters)
- [ ] Cache repeated storage reads in local variables
- [ ] Emit events instead of writing storage for historical data
- [ ] Mark fixed values `immutable` or `constant`
- [ ] Batch operations to amortize fixed per-transaction costs

## Layer-2 Gas Comparison

| **Operation** | **Ethereum** | **Base** | **Arbitrum** |
|---|---|---|---|
| Simple transfer | $2--5 | $0.001 | $0.10 |
| ERC20 transfer | $5--15 | $0.01 | $0.20 |
| Token swap | $20--50 | $0.05 | $0.50 |
| NFT mint | $10--30 | $0.02 | $0.30 |
| Complex game tx | $30--100 | $0.05 | $0.50 |

## Cheat Code Quick Reference

| **Cheat Code** | **Purpose** |
|---|---|
| `vm.prank(address)` | Execute next call as address |
| `vm.startPrank(address)` | Start pranking until stop |
| `vm.stopPrank()` | Stop active prank |
| `vm.deal(address, uint256)` | Set ETH balance |
| `vm.warp(uint256)` | Set block timestamp |
| `vm.roll(uint256)` | Set block number |
| `vm.expectRevert()` | Expect next call to revert |
| `vm.expectRevert(bytes4)` | Expect specific error selector |
| `vm.expectEmit(...)` | Expect event emission |
| `vm.mockCall(...)` | Mock external call |
| `vm.record()` | Start recording storage writes |
| `vm.accesses(address)` | Get recorded storage accesses |
| `vm.load(address, bytes32)` | Read storage slot |
| `vm.store(address, bytes32, bytes32)` | Write storage slot |
| `vm.createFork(string)` | Create network fork |
| `vm.selectFork(uint256)` | Switch to fork |
| `makeAddr("alice")` | Create labeled address (forge-std `Test` helper, not a `vm` cheatcode) |
| `vm.label(address, string)` | Label existing address |
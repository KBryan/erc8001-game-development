# Gas Reference

## Introduction

Gas optimization is critical for gaming contracts where users make frequent, often small-value transactions. This appendix provides quick reference tables for common operations.

## Opcode Gas Costs

| llc@{}}

**Category** | **Operation** | **Gas** |
|---|---|---|
| \multirow{5}{*}{Arithmetic} | ADD/SUB | 3 |
|  | MUL | 5 |
|  | DIV/SDIV | 5 |
|  | MOD | 5 |
|  | EXP | 10 + 50 * byte length |
| \multirow{4}{*}{Comparison} | LT/GT/SLT/SGT | 3 |
|  | EQ | 3 |
|  | ISZERO | 3 |
|  | AND/OR/XOR/NOT | 3 |
| \multirow{3}{*}{Memory} | MLOAD | 3 |
|  | MSTORE | 3 + memory expansion |
|  | MSTORE8 | 3 + memory expansion |
| \multirow{3}{*}{Storage} | SLOAD (warm) | 100 |
|  | SLOAD (cold) | 2100 |
|  | SSTORE (clean to dirty) | 20000 / 100 refund |
| \multirow{3}{*}{Control} | JUMP | 8 |
|  | JUMPI | 10 |
|  | CALL | 2600 + memory |

## Transaction Costs

| lc@{}}

**Transaction Type** | **Base Gas** |
|---|---|
| Simple transfer | 21,000 |
| Token transfer (ERC20) | ~45,000 |
| ERC721 mint | ~60,000--150,000 |
| ERC1155 mint (single) | ~40,000 |
| Contract deployment | 32,000 + init code |

## Storage Optimization Patterns

| lcc@{}}

**Type** | **Bits** | **Per 256-bit Slot** |
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

## Layer-2 Gas Comparison

| lccc@{}}

**Operation** | **Ethereum** | **Base** | **Arbitrum** |
|---|---|---|---|
| Simple transfer | \$2--5 | \$0.001 | \$0.10 |
| ERC20 transfer | \$5--15 | \$0.01 | \$0.20 |
| Token swap | \$20--50 | \$0.05 | \$0.50 |
| NFT mint | \$10--30 | \$0.02 | \$0.30 |
| Complex game tx | \$30--100 | \$0.05 | \$0.50 |

## Cheat Code Quick Reference

| p{5.5cm}p{8cm}@{}}

**Cheat Code** | **Purpose** |
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
| `vm.makeAddr(string)` | Create labeled address |
| `vm.label(address, string)` | Label existing address |
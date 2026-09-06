// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract ForkTest is Test {
    // Fork against mainnet
    string constant MAINNET_RPC = "https://eth.llamarpc.com";
    uint256 mainnetFork;
    
    function setUp() public {
        mainnetFork = vm.createFork(MAINNET_RPC);
    }
    
    function test_WETHPriceOnFork() public {
        vm.selectFork(mainnetFork);
        
        // Query real mainnet state
        IUniswapV2Pair wethUsdc = IUniswapV2Pair(
            0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc
        );
        
        (uint112 reserve0, uint112 reserve1,) = wethUsdc.getReserves();
        
        // WETH is token0, USDC is token1
        uint256 price = (uint256(reserve1) * 1e18) / reserve0;
        
        assertGt(price, 1000 * 1e6, "WETH should be > $1000");
    }
    
    function test_MultipleForks() public {
        uint256 baseFork = vm.createFork("https://mainnet.base.org");
        uint256 arbFork = vm.createFork("https://arb1.arbitrum.io/rpc");
        
        // Test on Base
        vm.selectFork(baseFork);
        assertEq(block.chainid, 8453);
        
        // Test on Arbitrum
        vm.selectFork(arbFork);
        assertEq(block.chainid, 42161);
    }
}
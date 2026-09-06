// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "../src/SimpleLottery.sol";

contract DeploySimpleLottery is Script {
    function run() external returns (SimpleLottery) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        SimpleLottery lottery = new SimpleLottery(
            0.01 ether,    // ticket price
            10,             // min entries
            100,            // commit duration (blocks)
            100             // reveal duration (blocks)
        );
        
        vm.stopBroadcast();
        
        return lottery;
    }
}
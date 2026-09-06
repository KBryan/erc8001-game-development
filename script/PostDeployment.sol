// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract PostDeployment is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address newOwner = vm.envAddress("NEW_OWNER");
        address token = vm.envAddress("TOKEN_ADDRESS");
        
        vm.startBroadcast(deployerKey);
        
        // Transfer ownership
        Ownable(token).transferOwnership(newOwner);
        
        // Grant admin role
        AccessControl(token).grantRole(
            keccak256("DEFAULT_ADMIN_ROLE"),
            newOwner
        );
        
        // Renounce deployer roles
        AccessControl(token).renounceRole(
            keccak256("DEFAULT_ADMIN_ROLE"),
            vm.addr(deployerKey)
        );
        
        vm.stopBroadcast();
    }
}
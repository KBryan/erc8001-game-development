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
        
        // Grant admin role.
        // CAUTION: DEFAULT_ADMIN_ROLE is bytes32(0), NOT keccak256 of its
        // name -- hashing the name grants a meaningless role while the
        // deployer silently keeps real admin.
        bytes32 adminRole = AccessControl(token).DEFAULT_ADMIN_ROLE();
        AccessControl(token).grantRole(adminRole, newOwner);

        // Renounce deployer roles
        AccessControl(token).renounceRole(adminRole, vm.addr(deployerKey));
        
        vm.stopBroadcast();
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/GameToken.sol";
import "../src/GameStaking.sol";

contract DeployGameFi is Script {
    struct NetworkConfig {
        address admin;
        uint256 maxSupply;
        uint256 dailyMintLimit;
    }
    
    mapping(uint256 => NetworkConfig) public configs;
    
    constructor() {
        // Admin address comes from the environment so no key is hardcoded
        address admin = vm.envOr("GAMEFI_ADMIN", address(0));

        // Base Mainnet
        configs[8453] = NetworkConfig({
            admin: admin,
            maxSupply: 1_000_000_000 ether,
            dailyMintLimit: 100_000 ether
        });

        // Arbitrum One
        configs[42161] = NetworkConfig({
            admin: admin,
            maxSupply: 1_000_000_000 ether,
            dailyMintLimit: 100_000 ether
        });
    }
    
    function run() external {
        uint256 chainId = block.chainid;
        NetworkConfig memory cfg = configs[chainId];
        
        require(cfg.admin != address(0), "Network not configured");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy token
        GameToken token = new GameToken(
            "GameToken",
            "GAME",
            cfg.maxSupply,
            cfg.dailyMintLimit
        );
        
        // Deploy staking
        GameStaking staking = new GameStaking(
            address(token),
            address(token)
        );
        
        // Setup roles
        token.grantRole(token.MINTER_ROLE(), cfg.admin);
        token.grantRole(token.GAME_CONTRACT_ROLE(), address(staking));
        
        vm.stopBroadcast();
        
        // Log addresses for verification
        console.log("GameToken deployed at:", address(token));
        console.log("GameStaking deployed at:", address(staking));
    }
}
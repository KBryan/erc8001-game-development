# Building Games with Ethereum Smart Contracts: 2026 Edition

A comprehensive guide to developing blockchain-based games using modern Ethereum development tools and best practices.

**Author:** Blockchain Gaming Research Group  
**Edition:** 2026 Edition  
**Solidity Version:** 0.8.26

## Overview

This book covers the complete journey of building games on Ethereum, from setting up your development environment to deploying production-grade GameFi applications. The 2026 edition represents a complete rewrite from the 2018 edition, incorporating:

- **Foundry** as the primary development framework (replacing Truffle)
- **Solidity 0.8.x** with built-in overflow protection and custom errors
- **Layer-2 deployment** strategies for reduced gas costs
- **Modern security practices** and formal verification techniques
- **DeFi integration** for yield-generating game mechanics
- **Verifiable randomness** through oracle solutions

## 2018 vs 2026: Key Differences

| Feature | 2018 Edition | 2026 Edition |
|---------|-------------|--------------|
| Solidity Version | 0.4.15–0.4.25 | 0.8.26 |
| Development Framework | Truffle Suite | Foundry |
| Testing Framework | JavaScript/Truffle | Solidity/Foundry |
| Primary Network | Ethereum Mainnet | L2 (Base, Arbitrum, Optimism) |
| Gas Costs | 50–200 gwei typical | 0.01–0.1 gwei on L2 |
| Randomness | Blockhash (insecure) | Chainlink VRF, Pyth Entropy |
| Price Oracles | None/Ad-hoc | Chainlink, Pyth |

## Table of Contents

1. **[Introduction to Ethereum Gaming](01-introduction.md)** - Technology overview and ecosystem evolution
2. **[Foundry Development Environment](02-foundry-setup.md)** - Project setup, Forge, Anvil, and Cast
3. **[Modern Solidity Development](03-modern-solidity.md)** - Language features, patterns, and optimizations
4. **[Smart Contract Security](04-security.md)** - Vulnerabilities, exploits, and defense patterns
5. **[Ponzi and Pyramid Schemes](05-ponzi-pyramid.md)** - Educational analysis of classic patterns
6. **[GameFi Architecture](06-gamefi.md)** - Token economics, staking, and DeFi integration
7. **[Lottery Systems](07-lotteries.md)** - Random number generation and lottery mechanics
8. **[Gambling Games](08-gambling.md)** - Provably fair gaming and betting contracts
9. **[Production Deployment](09-deployment.md)** - Mainnet deployment, verification, and monitoring
10. **[Advanced Testing](10-testing.md)** - Fuzzing, invariants, and integration testing
11. **[ERC-8001 Multiplayer Coordination](11-erc8001-multiplayer.md)** - Signed-intent coordination for multiplayer games

**[Appendix: Gas Optimization Reference](appendix-gas-reference.md)** - Quick reference for gas-efficient patterns

## Contract Reference

### Core GameFi Contracts
- `GameToken.sol` - ERC20 with gaming-specific features (mint limits, locking)
- `GameStaking.sol` - Tiered staking with lock periods and rewards
- `YieldManager.sol` - Treasury yield generation through Morpho
- `LootBoxManager.sol` - Randomized rewards with Pyth Entropy
- `PythPriceFeed.sol` - Price oracle integration
- `GamingErrors.sol` - Shared custom error definitions for gaming contracts

### ERC-8001 Coordination Contracts
- `IAgentCoordination.sol` - ERC-8001 interface and shared types
- `AgentCoordination.sol` - Reference implementation: EIP-712 intents, acceptances, lifecycle
- `GameCoordination.sol` - Game-specific extension: tournaments, battles, team rewards
- `MultiplayerGameLobby.sol` - Signed-intent lobbies with entry fees and winner payout
- `TeamStaking.sol` - Team staking with locked periods and shared rewards
- `ERC8001LootBox.sol` - Group loot boxes with Pyth Entropy randomness

### Lottery Contracts
- `SimpleLottery.sol` - Basic lottery with commit-reveal winner selection
- `RecurringLottery.sol` - Automated recurring lottery rounds
- `PowerballLottery.sol` - Multi-number lottery with progressive jackpots
- `VRFUpgradedLottery.sol` - Chainlink VRF integration

### Gambling Contracts
- `SatoshiDice.sol` - Classic dice game with provable fairness
- `Roulette.sol` - American roulette with multiple bet types

### Classic Pattern Examples (Educational)
- `SimplePonzi.sol` - Classic Ponzi scheme mechanics (for analysis, not deployment)
- `SimplePyramid.sol` - Classic pyramid scheme mechanics (for analysis, not deployment)
- Tests demonstrating Ponzi and Pyramid mechanics

## Building and Testing

The book's code is a working Foundry project. Dependencies are vendored as git submodules, so clone with `--recurse-submodules`:

```bash
git clone --recurse-submodules <repo-url>
cd erc8001-game-development

# Build all contracts
forge build

# Run the test suite
forge test
```

`ForkTest` requires a `MAINNET_RPC_URL` environment variable and is excluded from the default CI run. Continuous integration builds and tests every push via `.github/workflows/test.yml`.

## Converting to PDF

To generate a PDF from these Markdown files, use [Pandoc](https://pandoc.org/):

```bash
# Install pandoc and LaTeX
sudo apt-get install pandoc texlive-full

# Concatenate all chapters and convert
pandoc README.md 01-introduction.md 02-foundry-setup.md        03-modern-solidity.md 04-security.md 05-ponzi-pyramid.md        06-gamefi.md 07-lotteries.md 08-gambling.md        09-deployment.md 10-testing.md 11-erc8001-multiplayer.md appendix-gas-reference.md        -o ethereum-games-book.pdf        --pdf-engine=xelatex        -V geometry:margin=2.5cm        -V fontsize=11pt        --toc
```

## Prerequisites

- **Git** - Version control
- **Foundry** - `curl -L https://foundry.paradigm.xyz | bash`
- **Node.js** (optional) - For frontend integration
- **VS Code** with Solidity extension (recommended)

## Technology Stack

| Component | Tool |
|-----------|------|
| Language | Solidity 0.8.26 |
| Framework | Foundry |
| Build Tool | Forge |
| Local Node | Anvil |
| CLI | Cast |
| Testing | Native Solidity tests |
| Fuzzing | Built-in Foundry |

## License

© 2026 Blockchain Gaming Research Group. All rights reserved.

ISBN: pending

---

*Built with ❤️ for the Ethereum developer community.*

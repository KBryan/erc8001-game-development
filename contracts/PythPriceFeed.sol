// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
    
    function getPrice(bytes32 id) external view returns (Price memory price);
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory price);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

/**
 * @title PythPriceFeed
 * @notice Price oracle integration using Pyth Network
 */
contract PythPriceFeed {
    IPyth public pyth;
    
    // Price feed IDs
    bytes32 public constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 public constant BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    
    // Configuration
    uint256 public maxPriceAge = 300; // 5 minutes
    uint256 public confidenceMultiplier = 10; // 10x confidence for safety
    
    error StalePrice();
    error InvalidPrice();
    error ConfidenceTooLow();
    
    constructor(address _pyth) {
        pyth = IPyth(_pyth);
    }
    
    /**
     * @notice Get ETH price in USD with validation
     */
    function getEthPrice() external view returns (uint256 price, uint256 timestamp) {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(ETH_USD, maxPriceAge);
        
        _validatePrice(p);
        
        // Convert to 8 decimal format
        return (uint256(uint64(p.price)), p.publishTime);
    }
    
    /**
     * @notice Get any asset price by ID
     */
    function getAssetPrice(bytes32 priceId) 
        external 
        view 
        returns (uint256 price, uint256 confidence, uint256 timestamp) 
    {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(priceId, maxPriceAge);
        
        _validatePrice(p);
        
        return (
            uint256(uint64(p.price)),
            uint256(p.conf),
            p.publishTime
        );
    }
    
    /**
     * @notice Update price feeds (pay for updates)
     */
    function updatePrices(bytes[] calldata updateData) external payable {
        pyth.updatePriceFeeds{value: msg.value}(updateData);
    }
    
    /**
     * @notice Calculate game reward in USD terms
     */
    function calculateUsdValue(address token, uint256 amount) 
        external 
        view 
        returns (uint256 usdValue) 
    {
        // This would integrate with multiple price feeds
        // Simplified for demonstration
        (uint256 ethPrice,) = this.getEthPrice();
        
        // Example: token priced in ETH
        uint256 tokenPriceInEth = getTokenPriceInEth(token);
        
        usdValue = (amount * tokenPriceInEth * ethPrice) / 1e26; // Adjust decimals
    }
    
    function _validatePrice(IPyth.Price memory p) internal pure {
        if (p.price <= 0) revert InvalidPrice();
        
        // Check confidence interval
        uint256 priceAbs = uint256(uint64(p.price > 0 ? p.price : -p.price));
        if (uint256(p.conf) * 10 > priceAbs) {
            revert ConfidenceTooLow();
        }
    }
    
    function getTokenPriceInEth(address token) internal pure returns (uint256) {
        // Placeholder - would query DEX or additional price feed
        return 0;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
    error UnsupportedExponent(int32 expo);
    error TokenFeedNotConfigured(address token);
    
    constructor(address _pyth) {
        pyth = IPyth(_pyth);
    }
    
    /**
     * @notice Get ETH price in USD with validation
     */
    function getEthPrice() external view returns (uint256 price, uint256 timestamp) {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(ETH_USD, maxPriceAge);

        _validatePrice(p);

        // Convert to 8 decimal format using the feed's exponent
        return (_scaleTo8Decimals(uint256(uint64(p.price)), p.expo), p.publishTime);
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

        // Normalize both price and confidence to 8 decimals so callers can
        // compare feeds with different exponents directly
        return (
            _scaleTo8Decimals(uint256(uint64(p.price)), p.expo),
            _scaleTo8Decimals(uint256(p.conf), p.expo),
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
     * @dev This contract only wires up the ETH/USD and BTC/USD Pyth feeds --
     *      it has no token -> price-feed registry, so a token/ETH price
     *      cannot be looked up here. Rather than silently returning 0 (the
     *      old behavior, which made every reward appear worthless), it
     *      reverts with a clear error until such a registry is added.
     */
    function calculateUsdValue(address token, uint256 /* amount */)
        external
        view
        returns (uint256)
    {
        revert TokenFeedNotConfigured(token);
    }

    function _validatePrice(IPyth.Price memory p) internal pure {
        if (p.price <= 0) revert InvalidPrice();

        // Check confidence interval
        uint256 priceAbs = uint256(uint64(p.price > 0 ? p.price : -p.price));
        if (uint256(p.conf) * 10 > priceAbs) {
            revert ConfidenceTooLow();
        }
    }

    /**
     * @dev Pyth reports values as `value * 10^expo` (expo is usually
     *      negative, e.g. -8 means 8 decimals). Normalize to 8 decimals:
     *      - expo == -8: already correct
     *      - expo >  -8 (fewer decimals): multiply by 10^(8 + expo)
     *      - expo <  -8 (more decimals):  divide by 10^(-(8 + expo))
     *      Positive exponents are rejected as unsupported (no USD feed
     *      uses them, and accepting one silently would be a footgun).
     */
    function _scaleTo8Decimals(uint256 value, int32 expo) internal pure returns (uint256) {
        if (expo > 0 || expo < -77) revert UnsupportedExponent(expo);

        if (expo >= -8) {
            return value * 10 ** uint256(int256(8 + expo));
        } else {
            return value / 10 ** uint256(-int256(8 + expo));
        }
    }
}
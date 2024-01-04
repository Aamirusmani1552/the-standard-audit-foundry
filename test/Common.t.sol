// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {LiquidationPool} from "src/LiquidationPool.sol";
import {SmartVaultManagerV5} from "src/SmartVaultManagerV5.sol";
import {SmartVaultV3} from "src/SmartVaultV3.sol";
import {LiquidationPoolManager} from "src/LiquidationPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {WETHMock} from "utils/WETHMock.sol";
import {SmartVaultManager} from "utils/SmartVaultManager.sol";
import {ERC20Mock} from "utils/ERC20Mock.sol";
import {ChainlinkMock} from "utils/ChainlinkMock.sol";
import {EUROsMock} from "utils/EUROsMock.sol";
import {SwapRouterMock} from "utils/SwapRouterMock.sol";
import {TokenManagerMock} from "utils/TokenManagerMock.sol";
import {SmartVaultIndex} from "utils/SmartVaultIndex.sol";
import {PriceCalculator} from "utils/PriceCalculator.sol";
// import {NFTMetadataGenerator} from "utils/nfts/NFTMetadataGenerator.sol";
import {SmartVaultDeployerV3} from "utils/SmartVaultDeployerV3.sol";
import {console2} from "forge-std/console2.sol";

contract NFTMetadataGenerator {
    function generateNFTMetadata() external pure returns (string memory) {
        return "test";
    }
}

contract Common is Test {
    // contract variables
    struct ContractInstances {
        LiquidationPool liquidationPool;
        SmartVaultManagerV5 smartVaultManagerV5;
        SmartVaultManager smartVaultManager;
        SmartVaultV3 smartVault;
        LiquidationPoolManager liquidationPoolManager;
        TokenManagerMock tokenManager;
        NFTMetadataGenerator nftMetadataGenerator;
        SmartVaultDeployerV3 smartVaultDeployer;
        SmartVaultIndex smartVaultIndex;
    }

    ContractInstances public contracts;

    // tokens variables
    struct TokensInstances {
        ERC20Mock tstToken; // 18 decimals
        EUROsMock eurosToken; // 18 decimals
        WETHMock wethToken; // 18 decimals
        ERC20Mock wbtcToken; // 8 decimals
        ERC20Mock paxgToken; // 18 decimals
        ERC20Mock linkToken; // 18 decimals
        ERC20Mock arbToken; // 18 decimals
    }

    TokensInstances public tokens;

    // price feeds
    struct PriceFeedsInstances {
        ChainlinkMock eurosUsdPriceFeed;
        ChainlinkMock ethUsdPriceFeed;
        ChainlinkMock arbUsdPriceFeed;
        ChainlinkMock paxgUsdPriceFeed;
        ChainlinkMock wbtcUsdPriceFeed;
        ChainlinkMock linkUsdPriceFeed;
        ChainlinkMock tstUsdPriceFeed;
    }

    PriceFeedsInstances public priceFeeds;

    // proxies and other addresses
    SwapRouterMock public swapRouter2;
    address public liquidator;
    address public protocol;
    ProxyAdmin public proxyAdmin;
    TransparentUpgradeableProxy public proxy;

    // constants
    struct Constants {
        uint32 POOL_FEE_PERCENTAGE; // 50%
        int256 DEFAULT_COLLATERAL_RATE; // 120%
        int256 DEFAULT_ETH_USD_PRICE; // $2327.00000000
        int256 DEFAULT_EUR_USD_PRICE; // $1.10430000
        int256 DEFAULT_WBTC_USD_PRICE; // $43164.60115497
        int256 DEFAULT_USDC_USD_PRICE; // $1.00013800
        int256 DEFAULT_LINK_USD_PRICE; // $15.37949402
        int256 DEFAULT_PAXG_USD_PRICE; // $2030.46588596
        int256 DEFAULT_ARB_USD_PRICE; // $1.71177087
        uint256 PROTOCOL_FEE_RATE; // 0.5%
    }

    Constants public constants =
        Constants(
            50000, // POOL_FEE_PERCENTAGE
            120000, // DEFAULT_COLLATERAL_RATE
            232700000000, // DEFAULT_ETH_USD_PRICE
            110430000, // DEFAULT_EUR_USD_PRICE
            4316400000000, // DEFAULT_WBTC_USD_PRICE
            100013800, // DEFAULT_USDC_USD_PRICE
            1500000000, // DEFAULT_LINK_USD_PRICE
            203000000000, // DEFAULT_PAXG_USD_PRICE
            170000000, // DEFAULT_ARB_USD_PRICE
            500 // PROTOCOL_FEE_RATE
        );

    // users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public virtual {
        //////////////////////////////////
        ///         Protocol           ///
        //////////////////////////////////

        protocol = makeAddr("protocol");

        ///////////////////////////////////
        ///         Liquidator          ///
        ///////////////////////////////////

        liquidator = makeAddr("liquidator");

        ///////////////////////////////////////////////////////////////////
        ///     Moving some time to make block.timestamp bigger        ////
        ///////////////////////////////////////////////////////////////////

        skip(3 days);

        ///////////////////////////////
        ///     SwapRouterMocks     ///
        ///////////////////////////////

        swapRouter2 = new SwapRouterMock();

        ////////////////////////////////
        ///     Tokens              ////
        ////////////////////////////////

        _deploytokens();

        ///////////////////////////////
        ////    Price Feeds         ///
        ///////////////////////////////

        _deployPriceFeeds();

        /////////////////////////////////////////////////
        ////    Deploying Other Protocol Contracts   ////
        /////////////////////////////////////////////////

        _deployProtocolContracts();

        //////////////////////////
        ///     Proxy Admin    ///
        //////////////////////////

        proxyAdmin = new ProxyAdmin();

        ///////////////////////////////////////////////////////
        ///     Setting Up SmartVaultManager With Proxy     ///
        ///////////////////////////////////////////////////////

        contracts.smartVaultManager = new SmartVaultManager();

        contracts.smartVaultDeployer = new SmartVaultDeployerV3(
            bytes32("ETH"),
            address(priceFeeds.eurosUsdPriceFeed)
        );

        // initialize data for smartVaultManager
        bytes memory data = abi.encodeWithSelector(
            contracts.smartVaultManager.initialize.selector,
            constants.DEFAULT_COLLATERAL_RATE,
            constants.PROTOCOL_FEE_RATE,
            address(tokens.eurosToken),
            address(contracts.liquidationPoolManager),
            liquidator,
            address(contracts.tokenManager),
            address(contracts.smartVaultDeployer),
            address(contracts.smartVaultIndex),
            address(contracts.nftMetadataGenerator)
        );

        // add the smartVaultManager to the proxy
        proxy = new TransparentUpgradeableProxy(
            address(contracts.smartVaultManager),
            address(proxyAdmin),
            data
        );

        // deploy version 5 and upgrade to it
        SmartVaultManagerV5 smartVaultManagerV5Impl = new SmartVaultManagerV5();
        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(address(proxy)),
            address(smartVaultManagerV5Impl)
        );

        contracts.smartVaultManagerV5 = SmartVaultManagerV5(address(proxy));

        /////////////////////////////////////////////////////////
        ///     Setting Up LiquidationPoolManager and Pool    ///
        /////////////////////////////////////////////////////////

        _deployLiquidationPoolAndManager();

        // set protocol address as liquidationManager in smartVaultManager
        contracts.smartVaultManagerV5.setProtocolAddress(
            address(contracts.liquidationPoolManager)
        );

        /////////////////////////////////
        ////    Granting  rolez      ////
        /////////////////////////////////

        tokens.eurosToken.grantRole(
            tokens.eurosToken.BURNER_ROLE(),
            address(contracts.liquidationPool)
        );

        tokens.eurosToken.grantRole(
            tokens.eurosToken.DEFAULT_ADMIN_ROLE(),
            address(contracts.smartVaultManagerV5)
        );

        ///////////////////////////////////////////////////////////////
        ////    Setting samrt vault manager in smart vault index    ///
        ///////////////////////////////////////////////////////////////

        contracts.smartVaultIndex.setVaultManager(
            address(contracts.smartVaultManagerV5)
        );

        ///////////////////////////////////////////////////////////
        ///     Adding tokens and pricefeeds to token manager   ///
        ///////////////////////////////////////////////////////////

        _addAcceptedTokensWithFeeds();

        ///////////////////////////////
        ///     Label contracts     ///
        ///////////////////////////////

        _createLabels();
    }

    function _createLabels() internal {
        vm.label(address(contracts.liquidationPool), "LiquidationPool");
        vm.label(address(contracts.smartVaultManager), "SmartVaultManager");
        vm.label(address(contracts.smartVaultManagerV5), "SmartVaultManagerV5");
        vm.label(address(contracts.smartVault), "SmartVault");
        vm.label(
            address(contracts.liquidationPoolManager),
            "LiquidationPoolManager"
        );
        vm.label(address(contracts.tokenManager), "TokenManager");
        vm.label(
            address(contracts.nftMetadataGenerator),
            "NFTMetadataGenerator"
        );
        vm.label(address(contracts.smartVaultDeployer), "SmartVaultDeployer");
        vm.label(address(contracts.smartVaultIndex), "SmartVaultIndex");
        vm.label(address(tokens.tstToken), "TST");
        vm.label(address(tokens.eurosToken), "EUROs");
        vm.label(address(tokens.wethToken), "WETH");
        vm.label(address(tokens.wbtcToken), "WBTC");
        vm.label(address(tokens.paxgToken), "PAXG");
        vm.label(address(tokens.linkToken), "LINK");
        vm.label(address(tokens.arbToken), "ARB");
        vm.label(address(priceFeeds.eurosUsdPriceFeed), "EUROsUSDPriceFeed");
        vm.label(address(priceFeeds.ethUsdPriceFeed), "ETHUSDPriceFeed");
        vm.label(address(priceFeeds.arbUsdPriceFeed), "ARBUSDPriceFeed");
        vm.label(address(priceFeeds.paxgUsdPriceFeed), "PAXGUSDPriceFeed");
        vm.label(address(priceFeeds.wbtcUsdPriceFeed), "WBTCUSDPriceFeed");
        vm.label(address(priceFeeds.linkUsdPriceFeed), "LINKUSDPriceFeed");
        vm.label(address(priceFeeds.tstUsdPriceFeed), "TSTUSDPriceFeed");
        vm.label(address(swapRouter2), "SwapRouter2");
        vm.label(liquidator, "Liquidator");
        vm.label(protocol, "Protocol");
        vm.label(address(proxyAdmin), "ProxyAdmin");
        vm.label(address(proxy), "Proxy");
    }

    function _addAcceptedTokensWithFeeds() internal {
        contracts.tokenManager.addAcceptedToken(
            address(tokens.wbtcToken),
            address(priceFeeds.wbtcUsdPriceFeed)
        );
        contracts.tokenManager.addAcceptedToken(
            address(tokens.arbToken),
            address(priceFeeds.arbUsdPriceFeed)
        );
        contracts.tokenManager.addAcceptedToken(
            address(tokens.linkToken),
            address(priceFeeds.linkUsdPriceFeed)
        );
        contracts.tokenManager.addAcceptedToken(
            address(tokens.paxgToken),
            address(priceFeeds.paxgUsdPriceFeed)
        );
        contracts.tokenManager.addAcceptedToken(
            address(tokens.wethToken),
            address(priceFeeds.ethUsdPriceFeed)
        );
    }

    function _deploytokens() internal {
        tokens.tstToken = new ERC20Mock("The Standard Token", "TST", 18);
        tokens.wbtcToken = new ERC20Mock("Wrapped Bitcoin", "WBTC", 8);
        tokens.linkToken = new ERC20Mock("ChainLink token", "LINK", 18);
        tokens.arbToken = new ERC20Mock("Arbitrum Token", "ARB", 18);
        tokens.paxgToken = new ERC20Mock("Paxos Gold Token", "PAXG", 18);
        tokens.eurosToken = new EUROsMock();
        tokens.wethToken = new WETHMock();
    }

    function _deployPriceFeeds() internal {
        priceFeeds.eurosUsdPriceFeed = new ChainlinkMock("EUR / USD");
        priceFeeds.ethUsdPriceFeed = new ChainlinkMock("ETH / USD");
        priceFeeds.paxgUsdPriceFeed = new ChainlinkMock("PAXG / USD");
        priceFeeds.linkUsdPriceFeed = new ChainlinkMock("LINK / USD");
        priceFeeds.arbUsdPriceFeed = new ChainlinkMock("ARB / USD");
        priceFeeds.wbtcUsdPriceFeed = new ChainlinkMock("WBTC / USD");
        priceFeeds.tstUsdPriceFeed = new ChainlinkMock("TST / USD");

        _setPricesForPriceFeeds();
    }

    function _setPricesForPriceFeeds() internal {
        priceFeeds.eurosUsdPriceFeed.setPrice(constants.DEFAULT_EUR_USD_PRICE);
        priceFeeds.ethUsdPriceFeed.setPrice(constants.DEFAULT_ETH_USD_PRICE);
        priceFeeds.linkUsdPriceFeed.setPrice(constants.DEFAULT_LINK_USD_PRICE);
        priceFeeds.wbtcUsdPriceFeed.setPrice(constants.DEFAULT_WBTC_USD_PRICE);
        priceFeeds.paxgUsdPriceFeed.setPrice(constants.DEFAULT_PAXG_USD_PRICE);
        priceFeeds.arbUsdPriceFeed.setPrice(constants.DEFAULT_ARB_USD_PRICE);
        priceFeeds.tstUsdPriceFeed.setPrice(constants.DEFAULT_ETH_USD_PRICE);
    }

    function _deployProtocolContracts() internal {
        contracts.nftMetadataGenerator = new NFTMetadataGenerator();

        contracts.tokenManager = new TokenManagerMock(
            bytes32("ETH"),
            address(priceFeeds.ethUsdPriceFeed)
        );

        contracts.smartVaultIndex = new SmartVaultIndex();
    }

    function _deployLiquidationPoolAndManager() internal {
        contracts.liquidationPoolManager = new LiquidationPoolManager(
            address(tokens.tstToken),
            address(tokens.eurosToken),
            address(contracts.smartVaultManagerV5),
            address(priceFeeds.eurosUsdPriceFeed),
            payable(protocol),
            constants.POOL_FEE_PERCENTAGE
        );

        contracts.liquidationPool = LiquidationPool(
            contracts.liquidationPoolManager.pool()
        );
    }
}

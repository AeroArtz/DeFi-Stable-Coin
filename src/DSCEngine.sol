//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 *@title DSCEngine
 *@author Abdul Rehman
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1
 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if it had no governance, no fees, and was only backed 
 by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all the collateral
 <= the $ backed value of all the DSC,
 *
 * @notice this contract is the core of the DSC System. It handles all the logic for mining
 and redeeming DCS, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
*/

contract DSCEngine is ReentrancyGuard{
    // Errors
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAdressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealhtFactorNotImproved();
    
    // Types
    using OracleLib for AggregatorV3Interface;

    // State variables

    uint256 private constant ADDITIONAL_FEED_PRECISION= 1e10;
    uint256 private constant PRECISION= 1e18;
    uint256 private constant LIQUIDATION_THRESOLD = 50; // 200% Overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10 ; // This means a 10% bonus 


    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) 
        private s_collateralDeposited;

    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; 
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;


    // Events
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo,address indexed token, uint256 amount);

    // Modifiers
    modifier moreThanZero(uint256 amount){
        if(amount ==0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token){
        if (s_priceFeeds[token] == address(0)){
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }




    // Functions
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {

        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAdressesMustBeSameLength();
        }

        for (uint256 i=0 ; i <tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        
        i_dsc = DecentralizedStableCoin(dscAddress);



    }



    // External Functions



    /**
     * 
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stabelCoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function deposCollateralAndMintDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral,
        uint256 amountDscToMint 
    ) external {
        depositCollateral(tokenCollateralAddress,amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
    */
    function depositCollateral(
        address tokenCollateralAddress, 
        uint256 amountCollateral
    ) 
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender,address(this), amountCollateral);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * 
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor

    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    // DRY: Don't repeat yourself
    // CEI: Check, Effects, Interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant    
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral,msg.sender, msg.sender );
        _revertIfHealthFactorIsBroken(msg.sender);

    }


    /*
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to min
     * @notice they must have more collateral value than the minimum thresold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }

    }

    function burnDsc(uint256 amount) public moreThanZero(amount){
        _burnDsc(amount,msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this line will ever hit... 
    }

    // If we do start nearing undecollateralization, we need someone to liquidate positions

    /**
     * @param collateral The erc20 collateral address to liquidate
     * @param user The user who has broken the health factor. Thier _healthFactor should
     * below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health
     * factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly over 200%
     * overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then
     * we wouldn;t be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be
     * liquidated
     * 
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external
    moreThanZero(debtToCover) nonReentrant{
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take thier collateral
        // Figure out how much ETH is the DSC

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral,debtToCover);
        // And give them a 10% bonus
        // So wa re giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral,totalCollateralToRedeem,user, msg.sender);

        // Burn DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealhtFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}



    // Private & Internal View Functions

    /**
     * @dev Low-level internal function, don't call unless the function calling it is
     * checking for health factors being broken
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom ) private {

        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom,address(this),amountDscToBurn);
        
        // This conditional is 
        if (!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
        }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to) private {
            s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
            emit CollateralRedeemed(from,to, tokenCollateralAddress, amountCollateral);
            bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
            if (!success){
                revert DSCEngine__TransferFailed();
        }
        }

    function _getAccountInformation(address user)
        private
        view 
        returns(uint256 totalDscMinted, uint256 collateralValueInUsd )
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollaralValue(user);

    }

    /**
     * Returns how close to liquidation a user is
     * if a user goes below 1 , then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256){
        // total DSC minted 
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThresold = (collateralValueInUsd * LIQUIDATION_THRESOLD) /
        LIQUIDATION_PRECISION;
        return (collateralAdjustedForThresold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor
    // 2. revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view{
       
        uint256 userHealthFactor = _healthFactor(user);   
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }

    }

    // Public & External View Functions

    function getTokenAmountFromUsd(
        address token, uint256 usdAmountInWei) public view returns(uint256){
        // price of ETH (token)
        // $/ETH ??
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION )/ (uint256(price) * ADDITIONAL_FEED_PRECISION );
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollaralValue(address user) public view returns(uint256 totalCollateralValueInUsd){
        // loop through each collateral token, get the amount they have deposited and map it to
        // the price to get the USD Value

        for (uint256 i= 0 ; i<s_collateralTokens.length ; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // 1ETH = $1000
        // The returned value from CL will be 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted,
     uint256 collateralValueInUsd){
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);

    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

     function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }


}
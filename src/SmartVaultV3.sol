// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "src/interfaces/IEUROs.sol";
import "src/interfaces/IPriceCalculator.sol";
import "src/interfaces/ISmartVault.sol";
import "src/interfaces/ISmartVaultManagerV3.sol";
import "src/interfaces/ISwapRouter.sol";
import "src/interfaces/ITokenManager.sol";
import "src/interfaces/IWETH.sol";

contract SmartVaultV3 is ISmartVault {
    using SafeERC20 for IERC20;

    string private constant INVALID_USER = "err-invalid-user";
    string private constant UNDER_COLL = "err-under-coll";
    // @audit constant naming convention not used
    uint8 private constant version = 2; // new version
    bytes32 private constant vaultType = bytes32("EUROs"); // type of vault. @audit will there be different types of vaults?
    bytes32 private immutable NATIVE; // @audit will that be an address zero?
    address public immutable manager; // will be the smart vault manager
    IEUROs public immutable EUROs; // EUROs token
    IPriceCalculator public immutable calculator; // price calculator used for tokens conversion

    address public owner; // owner of the vault
    uint256 private minted; // total minted EUROs
    bool private liquidated; // vault liquidated or not

    event CollateralRemoved(bytes32 symbol, uint256 amount, address to);
    event AssetRemoved(address token, uint256 amount, address to);
    event EUROsMinted(address to, uint256 amount, uint256 fee);
    event EUROsBurned(uint256 amount, uint256 fee);

    constructor(bytes32 _native, address _manager, address _owner, address _euros, address _priceCalculator) {
        // @audit address zero checks are not done
        NATIVE = _native;
        owner = _owner;
        manager = _manager;
        EUROs = IEUROs(_euros);
        calculator = IPriceCalculator(_priceCalculator);
    }

    modifier onlyVaultManager() {
        require(msg.sender == manager, INVALID_USER);
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, INVALID_USER);
        _;
    }

    modifier ifMinted(uint256 _amount) {
        require(minted >= _amount, "err-insuff-minted");
        _;
    }

    modifier ifNotLiquidated() {
        require(!liquidated, "err-liquidated");
        _;
    }

    // get the token manager for the vault from the vault manager
    function getTokenManager() private view returns (ITokenManager) {
        return ITokenManager(ISmartVaultManagerV3(manager).tokenManager());
    }

    // get the total collateral vaule in euros
    function euroCollateral() private view returns (uint256 euros) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            euros += calculator.tokenToEurAvg(token, getAssetBalance(token.symbol, token.addr));
        }
    }

    function maxMintable() private view returns (uint256) {
        return (euroCollateral() * ISmartVaultManagerV3(manager).HUNDRED_PC())
            / ISmartVaultManagerV3(manager).collateralRate();
    }

    // get asset balance from the symbol and token address
    // if symbol  == NATIVE, return the ETH balance of the vault
    // else return the ERC20 balance of the vault
    function getAssetBalance(bytes32 _symbol, address _tokenAddress) private view returns (uint256 amount) {
        return _symbol == NATIVE ? address(this).balance : IERC20(_tokenAddress).balanceOf(address(this));
    }

    // get the all accepted asset data and balances
    function getAssets() private view returns (Asset[] memory) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        Asset[] memory assets = new Asset[](acceptedTokens.length);
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            uint256 assetBalance = getAssetBalance(token.symbol, token.addr);
            assets[i] = Asset(token, assetBalance, calculator.tokenToEurAvg(token, assetBalance));
        }
        return assets;
    }

    // get the vault status
    function status() external view returns (Status memory) {
        return
            Status(address(this), minted, maxMintable(), euroCollateral(), getAssets(), liquidated, version, vaultType);
    }

    // check if the vault is undercollateralised or not.
    // maxMintable should be less than minted if true
    function undercollateralised() public view returns (bool) {
        return minted > maxMintable();
    }

    // liquidate the vault by transferring all the ETH to the protocol
    function liquidateNative() private {
        if (address(this).balance != 0) {
            (bool sent,) = payable(ISmartVaultManagerV3(manager).protocol()).call{value: address(this).balance}("");
            require(sent, "err-native-liquidate");
        }
    }

    // liquidate the vault by transferring all the ERC20 tokens to the protocol
    function liquidateERC20(IERC20 _token) private {
        if (_token.balanceOf(address(this)) != 0) {
            _token.safeTransfer(ISmartVaultManagerV3(manager).protocol(), _token.balanceOf(address(this)));
        }
    }

    // liquidate the vault by transferring all the assets to the protocol
    // can be called by vault manager only
    function liquidate() external onlyVaultManager {
        require(undercollateralised(), "err-not-liquidatable");
        liquidated = true;
        minted = 0;
        liquidateNative();
        ITokenManager.Token[] memory tokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol != NATIVE) {
                liquidateERC20(IERC20(tokens[i].addr));
            }
        }
    }

    // receive ETH
    receive() external payable {}

    // check if the collateral can be removed or not
    function canRemoveCollateral(ITokenManager.Token memory _token, uint256 _amount) private view returns (bool) {
        if (minted == 0) return true;
        uint256 currentMintable = maxMintable();
        uint256 eurValueToRemove = calculator.tokenToEurAvg(_token, _amount);
        return currentMintable >= eurValueToRemove && minted <= currentMintable - eurValueToRemove;
    }

    // remove collateral from the vault in ETH
    // can be called by owner only
    function removeCollateralNative(uint256 _amount, address payable _to) external onlyOwner {
        // check if the collateral can be removed or not for the given amount
        require(canRemoveCollateral(getTokenManager().getToken(NATIVE), _amount), UNDER_COLL);

        // send the ETH to the mentioned address
        (bool sent,) = _to.call{value: _amount}("");
        require(sent, "err-native-call");
        emit CollateralRemoved(NATIVE, _amount, _to);
    }

    // remove collateral from the vault in ERC20 tokens
    // can be called by owner only
    function removeCollateral(bytes32 _symbol, uint256 _amount, address _to) external onlyOwner {
        // get the token from the symbol
        ITokenManager.Token memory token = getTokenManager().getToken(_symbol);

        // check if the collateral can be removed or not for the given amount
        require(canRemoveCollateral(token, _amount), UNDER_COLL);

        // transfer the ERC20 tokens to the mentioned address
        IERC20(token.addr).safeTransfer(_to, _amount);
        emit CollateralRemoved(_symbol, _amount, _to);
    }

    // remove asset from the vault in ERC20 tokens
    function removeAsset(address _tokenAddr, uint256 _amount, address _to) external onlyOwner {
        ITokenManager.Token memory token = getTokenManager().getTokenIfExists(_tokenAddr);

        // @audit why is it checked that token address should be equal to token.addr
        if (token.addr == _tokenAddr) {
            require(canRemoveCollateral(token, _amount), UNDER_COLL);
        }
        IERC20(_tokenAddr).safeTransfer(_to, _amount);
        emit AssetRemoved(_tokenAddr, _amount, _to);
    }

    function fullyCollateralised(uint256 _amount) private view returns (bool) {
        return minted + _amount <= maxMintable();
    }

    // vault owner will call this to mint EUROs against the collateral
    function mint(address _to, uint256 _amount) external onlyOwner ifNotLiquidated {
        uint256 fee =
            (_amount * ISmartVaultManagerV3(manager).mintFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        require(fullyCollateralised(_amount + fee), UNDER_COLL);
        minted = minted + _amount + fee;
        EUROs.mint(_to, _amount);
        EUROs.mint(ISmartVaultManagerV3(manager).protocol(), fee);
        emit EUROsMinted(_to, _amount, fee);
    }

    function burn(uint256 _amount) external ifMinted(_amount) {
        uint256 fee =
            (_amount * ISmartVaultManagerV3(manager).burnFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        minted = minted - _amount;
        EUROs.burn(msg.sender, _amount);
        IERC20(address(EUROs)).safeTransferFrom(msg.sender, ISmartVaultManagerV3(manager).protocol(), fee);
        emit EUROsBurned(_amount, fee);
    }

    function getToken(bytes32 _symbol) private view returns (ITokenManager.Token memory _token) {
        ITokenManager.Token[] memory tokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol == _symbol) _token = tokens[i];
        }
        require(_token.symbol != bytes32(0), "err-invalid-swap");
    }

    function getSwapAddressFor(bytes32 _symbol) private view returns (address) {
        ITokenManager.Token memory _token = getToken(_symbol);
        return _token.addr == address(0) ? ISmartVaultManagerV3(manager).weth() : _token.addr;
    }

    function executeNativeSwapAndFee(ISwapRouter.ExactInputSingleParams memory _params, uint256 _swapFee) private {
        (bool sent,) = payable(ISmartVaultManagerV3(manager).protocol()).call{value: _swapFee}("");
        require(sent, "err-swap-fee-native");
        ISwapRouter(ISmartVaultManagerV3(manager).swapRouter2()).exactInputSingle{value: _params.amountIn}(_params);
    }

    function executeERC20SwapAndFee(ISwapRouter.ExactInputSingleParams memory _params, uint256 _swapFee) private {
        IERC20(_params.tokenIn).safeTransfer(ISmartVaultManagerV3(manager).protocol(), _swapFee);
        IERC20(_params.tokenIn).safeApprove(ISmartVaultManagerV3(manager).swapRouter2(), _params.amountIn);
        ISwapRouter(ISmartVaultManagerV3(manager).swapRouter2()).exactInputSingle(_params);
        IWETH weth = IWETH(ISmartVaultManagerV3(manager).weth());
        // convert potentially received weth to eth
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) weth.withdraw(wethBalance);
    }

    function calculateMinimumAmountOut(bytes32 _inTokenSymbol, bytes32 _outTokenSymbol, uint256 _amount)
        private
        view
        returns (uint256)
    {
        ISmartVaultManagerV3 _manager = ISmartVaultManagerV3(manager);
        uint256 requiredCollateralValue = (minted * _manager.collateralRate()) / _manager.HUNDRED_PC();
        uint256 collateralValueMinusSwapValue =
            euroCollateral() - calculator.tokenToEur(getToken(_inTokenSymbol), _amount);
        return collateralValueMinusSwapValue >= requiredCollateralValue
            ? 0
            : calculator.eurToToken(getToken(_outTokenSymbol), requiredCollateralValue - collateralValueMinusSwapValue);
    }

    // @audit it will still cause an issue
    function swap(bytes32 _inToken, bytes32 _outToken, uint256 _amount) external onlyOwner {
        uint256 swapFee =
            (_amount * ISmartVaultManagerV3(manager).swapFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        address inToken = getSwapAddressFor(_inToken);
        uint256 minimumAmountOut = calculateMinimumAmountOut(_inToken, _outToken, _amount);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: inToken,
            tokenOut: getSwapAddressFor(_outToken),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _amount - swapFee,
            amountOutMinimum: minimumAmountOut,
            sqrtPriceLimitX96: 0
        });
        inToken == ISmartVaultManagerV3(manager).weth()
            ? executeNativeSwapAndFee(params, swapFee)
            : executeERC20SwapAndFee(params, swapFee);
    }

    function setOwner(address _newOwner) external onlyVaultManager {
        owner = _newOwner;
    }
}

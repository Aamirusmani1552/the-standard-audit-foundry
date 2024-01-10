// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import 'src/interfaces/IEUROs.sol';
import 'src/interfaces/IPriceCalculator.sol';
import 'src/interfaces/ISmartVault.sol';
import 'src/interfaces/ISmartVaultManagerV3.sol';
import 'src/interfaces/ISwapRouter.sol';
import 'src/interfaces/ITokenManager.sol';
import 'src/interfaces/IWETH.sol';

contract SmartVaultV3 is ISmartVault {
    using SafeERC20 for IERC20;

    string private constant INVALID_USER = 'err-invalid-user';
    string private constant UNDER_COLL = 'err-under-coll';
    // @audit constant naming convention not used
    uint8 private constant version = 2; // new version
    bytes32 private constant vaultType = bytes32('EUROs'); // type of vault. @audit-info will there be different types of vaults: yes
    bytes32 private immutable NATIVE;
    address public immutable manager; // will be the smart vault manager: yes
    IEUROs public immutable EUROs; // EUROs token
    IPriceCalculator public immutable calculator; // price calculator used for tokens conversion

    address public owner; // owner of the vault
    uint private minted; // total minted EUROs
    bool private liquidated; // vault liquidated or not

    event CollateralRemoved(bytes32 symbol, uint amount, address to);
    event AssetRemoved(address token, uint amount, address to);
    event EUROsMinted(address to, uint amount, uint fee);
    event EUROsBurned(uint amount, uint fee);

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

    modifier ifMinted(uint _amount) {
        require(minted >= _amount, 'err-insuff-minted');
        _;
    }

    modifier ifNotLiquidated() {
        require(!liquidated, 'err-liquidated');
        _;
    }

    // get the token manager for the vault from the vault manager
    function getTokenManager() private view returns (ITokenManager) {
        return ITokenManager(ISmartVaultManagerV3(manager).tokenManager());
    }

    // get the total collateral vaule in euros
    // @audit wouldn't the vault be unnecessarily liquidated if the average price is less than the actual price?
    function euroCollateral() private view returns (uint euros) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        for (uint i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            euros += calculator.tokenToEurAvg(token, getAssetBalance(token.symbol, token.addr));
        }
    }

    // max amount mintable for the vault in euros
    function maxMintable() private view returns (uint) {
        return (euroCollateral() * ISmartVaultManagerV3(manager).HUNDRED_PC())
            / ISmartVaultManagerV3(manager).collateralRate();
    }

    // get asset balance from the symbol and token address
    // if symbol  == NATIVE, return the ETH balance of the vault
    // else return the ERC20 balance of the vault
    function getAssetBalance(bytes32 _symbol, address _tokenAddress) private view returns (uint amount) {
        return _symbol == NATIVE ? address(this).balance : IERC20(_tokenAddress).balanceOf(address(this));
    }

    // get the all accepted asset data and balances in euros
    function getAssets() private view returns (Asset[] memory) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        Asset[] memory assets = new Asset[](acceptedTokens.length);
        for (uint i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            uint assetBalance = getAssetBalance(token.symbol, token.addr);
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
            (bool sent,) = payable(ISmartVaultManagerV3(manager).protocol()).call{ value: address(this).balance }('');
            require(sent, 'err-native-liquidate');
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
    // @audit-info if accepted token is removed from the token manager, would it not cause an issue? No here. only in liquidation pool
    function liquidate() external onlyVaultManager {
        require(undercollateralised(), 'err-not-liquidatable');
        liquidated = true;
        minted = 0;
        liquidateNative();
        ITokenManager.Token[] memory tokens = getTokenManager().getAcceptedTokens();
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol != NATIVE) {
                liquidateERC20(IERC20(tokens[i].addr));
            }
        }
    }

    // receive ETH
    receive() external payable { }

    // check if the collateral can be removed or not
    function canRemoveCollateral(ITokenManager.Token memory _token, uint _amount) private view returns (bool) {
        if (minted == 0) return true;
        uint currentMintable = maxMintable();
        uint eurValueToRemove = calculator.tokenToEurAvg(_token, _amount);
        return currentMintable >= eurValueToRemove && minted <= currentMintable - eurValueToRemove;
    }

    // remove collateral from the vault in ETH
    // can be called by owner only
    function removeCollateralNative(uint _amount, address payable _to) external onlyOwner {
        // check if the collateral can be removed or not for the given amount
        require(canRemoveCollateral(getTokenManager().getToken(NATIVE), _amount), UNDER_COLL);

        // send the ETH to the mentioned address
        (bool sent,) = _to.call{ value: _amount }('');
        require(sent, 'err-native-call');
        emit CollateralRemoved(NATIVE, _amount, _to);
    }

    // remove collateral from the vault in ERC20 tokens
    // can be called by owner only
    // @audit-info what if accepted token is removed from the token manager? would it be possible to remove that token: handled in removeAsset
    function removeCollateral(bytes32 _symbol, uint _amount, address _to) external onlyOwner {
        // get the token from the symbol
        ITokenManager.Token memory token = getTokenManager().getToken(_symbol);

        // check if the collateral can be removed or not for the given amount
        require(canRemoveCollateral(token, _amount), UNDER_COLL);

        // transfer the ERC20 tokens to the mentioned address
        IERC20(token.addr).safeTransfer(_to, _amount);
        emit CollateralRemoved(_symbol, _amount, _to);
    }

    // remove asset from the vault in ERC20 tokens
    function removeAsset(address _tokenAddr, uint _amount, address _to) external onlyOwner {
        ITokenManager.Token memory token = getTokenManager().getTokenIfExists(_tokenAddr);

        // @audit-info why is it checked that token address should be equal to token.addr: Because this function can be
        // used to withdraw any type of assets. If the token is collateral token then the it should be checked that whether
        // the entered amount can be removed or not
        if (token.addr == _tokenAddr) {
            require(canRemoveCollateral(token, _amount), UNDER_COLL);
        }
        IERC20(_tokenAddr).safeTransfer(_to, _amount);
        emit AssetRemoved(_tokenAddr, _amount, _to);
    }

    // check if the vault is fully collateralised or not after adding the _amount
    function fullyCollateralised(uint _amount) private view returns (bool) {
        return minted + _amount <= maxMintable();
    }

    // vault owner will call this to mint EUROs against the collateral
    // @audit-info how much would the user be able to recover if he decides to clost the vault? Only his amount - withdraw fee
    function mint(address _to, uint _amount) external onlyOwner ifNotLiquidated {
        uint fee = (_amount * ISmartVaultManagerV3(manager).mintFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        require(fullyCollateralised(_amount + fee), UNDER_COLL);
        minted = minted + _amount + fee;
        EUROs.mint(_to, _amount);
        EUROs.mint(ISmartVaultManagerV3(manager).protocol(), fee);
        emit EUROsMinted(_to, _amount, fee);
    }

    // burn EUROs
    function burn(uint _amount) external ifMinted(_amount) {
        // calculate the burn fee
        uint fee = (_amount * ISmartVaultManagerV3(manager).burnFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        // remove the burn amount from the minted
        minted = minted - _amount;
        // burn the EUROs
        EUROs.burn(msg.sender, _amount);
        // transfer the burn fee to the protocol.
        IERC20(address(EUROs)).safeTransferFrom(msg.sender, ISmartVaultManagerV3(manager).protocol(), fee);
        emit EUROsBurned(_amount, fee);
    }

    // get the token data from the symbol of the tokens
    // reverts if the token symbol is bytes 0 or simply means it doesn't exist in tokenManger
    function getToken(bytes32 _symbol) private view returns (ITokenManager.Token memory _token) {
        // get the accepted tokens from the token Manager
        ITokenManager.Token[] memory tokens = getTokenManager().getAcceptedTokens();
        // loop over the each tokens and check if the symbol matches and add it to the _token
        for (uint i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol == _symbol) _token = tokens[i];
        }
        // check if the token is present in the token manager by looking at it's symbol
        require(_token.symbol != bytes32(0), 'err-invalid-swap');
    }

    // helper function for swap to get the address of the token from it's symbol
    // it returns the address only when it is accepted by the token manager
    function getSwapAddressFor(bytes32 _symbol) private view returns (address) {
        // get the token data from the symbol
        ITokenManager.Token memory _token = getToken(_symbol);
        // if address zero is returned then return the weth address other wise return the token address
        return _token.addr == address(0) ? ISmartVaultManagerV3(manager).weth() : _token.addr;
    }

    // helper function to swap the native tokens and pay the swap fee
    function executeNativeSwapAndFee(ISwapRouter.ExactInputSingleParams memory _params, uint _swapFee) private {
        // send the fee to the protocol address
        (bool sent,) = payable(ISmartVaultManagerV3(manager).protocol()).call{ value: _swapFee }('');
        require(sent, 'err-swap-fee-native');
        // approve the swap router to spend the amountIn
        ISwapRouter(ISmartVaultManagerV3(manager).swapRouter2()).exactInputSingle{ value: _params.amountIn }(_params);
    }

    // helper function to swap the ERC20 tokens and pay the swap fee
    function executeERC20SwapAndFee(ISwapRouter.ExactInputSingleParams memory _params, uint _swapFee) private {
        // send the fee to the protocol address
        IERC20(_params.tokenIn).safeTransfer(ISmartVaultManagerV3(manager).protocol(), _swapFee);
        // approve the swap router to spend the amountIn
        IERC20(_params.tokenIn).safeApprove(ISmartVaultManagerV3(manager).swapRouter2(), _params.amountIn);
        // swap the tokens
        ISwapRouter(ISmartVaultManagerV3(manager).swapRouter2()).exactInputSingle(_params);
        // if weth is recieed then convert it to eth
        IWETH weth = IWETH(ISmartVaultManagerV3(manager).weth());
        // convert potentially received weth to eth
        // @audit what if there is weth deposited in the vault? it would be converted to eth. would it be a problem?
        uint wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) weth.withdraw(wethBalance);
    }

    // calculates the minimu amount out for the swap
    function calculateMinimumAmountOut(
        bytes32 _inTokenSymbol,
        bytes32 _outTokenSymbol,
        uint _amount
    )
        private
        view
        returns (uint)
    {
        // get the smart vault manager
        ISmartVaultManagerV3 _manager = ISmartVaultManagerV3(manager);
        // calculate the required collateral value for the minted tokens
        uint requiredCollateralValue = (minted * _manager.collateralRate()) / _manager.HUNDRED_PC();
        uint collateralValueMinusSwapValue = euroCollateral() - calculator.tokenToEur(getToken(_inTokenSymbol), _amount);
        return collateralValueMinusSwapValue >= requiredCollateralValue
            ? 0
            : calculator.eurToToken(getToken(_outTokenSymbol), requiredCollateralValue - collateralValueMinusSwapValue);
    }

    // @audit-info it will still cause an issue: added
    // @audit weth should not be used as a collateral token other wise it will be converted to eth
    function swap(bytes32 _inToken, bytes32 _outToken, uint _amount) external onlyOwner {
        uint swapFee =
            (_amount * ISmartVaultManagerV3(manager).swapFeeRate()) / ISmartVaultManagerV3(manager).HUNDRED_PC();
        address inToken = getSwapAddressFor(_inToken);
        uint minimumAmountOut = calculateMinimumAmountOut(_inToken, _outToken, _amount);
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

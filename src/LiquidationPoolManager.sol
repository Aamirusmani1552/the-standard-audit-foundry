// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "src/LiquidationPool.sol";
import "src/interfaces/ILiquidationPoolManager.sol";
import "src/interfaces/ISmartVaultManager.sol";
import "src/interfaces/ITokenManager.sol";
import {console2} from "forge-std/console2.sol";

// @audit what if the smartVaultManager is updated, how will that be updated in the pool manager?
contract LiquidationPoolManager is Ownable {
    uint32 public constant HUNDRED_PC = 100000;

    address private immutable TST;
    address private immutable EUROs;
    address public immutable smartVaultManager;
    address payable private immutable protocol;
    address public immutable pool;

    uint32 public poolFeePercentage;

    constructor(
        address _TST,
        address _EUROs,
        address _smartVaultManager,
        address _eurUsd,
        address payable _protocol,
        uint32 _poolFeePercentage
    ) {
        pool = address(
            new LiquidationPool(
                _TST,
                _EUROs,
                _eurUsd,
                ISmartVaultManager(_smartVaultManager).tokenManager()
            )
        );
        TST = _TST;
        EUROs = _EUROs;
        smartVaultManager = _smartVaultManager;
        protocol = _protocol;
        poolFeePercentage = _poolFeePercentage;
    }

    receive() external payable {}

    // @audit where will this euro come from in the first place
    function distributeFees() public {
        IERC20 eurosToken = IERC20(EUROs);
        uint256 _feesForPool = (eurosToken.balanceOf(address(this)) *
            poolFeePercentage) / HUNDRED_PC;
        if (_feesForPool > 0) {
            // @audit return values not checked
            eurosToken.approve(pool, _feesForPool);
            LiquidationPool(pool).distributeFees(_feesForPool);
        }
        // @audit return values not checked
        eurosToken.transfer(protocol, eurosToken.balanceOf(address(this)));
    }

    function forwardRemainingRewards(
        ITokenManager.Token[] memory _tokens
    ) private {
        for (uint256 i = 0; i < _tokens.length; i++) {
            ITokenManager.Token memory _token = _tokens[i];
            if (_token.addr == address(0)) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    (bool _sent, ) = protocol.call{value: balance}("");
                    require(_sent);
                }
            } else {
                uint256 balance = IERC20(_token.addr).balanceOf(address(this));
                // @audit return values of transfer function is not used
                if (balance > 0)
                    IERC20(_token.addr).transfer(protocol, balance);
            }
        }
    }

    function runLiquidation(uint256 _tokenId) external {
        // get the manager
        ISmartVaultManager manager = ISmartVaultManager(smartVaultManager);

        // call liquidiate vault for the token Id
        manager.liquidateVault(_tokenId);

        // @audit will the fee be distributed to all of the people who has even reached the consolidate rewards?
        // @audit should this fees be given to the liquidated person. I mean the person is already undercollateralized. So giving him more does not make sense
        // distribute the fees
        distributeFees();

        // get the accepted tokens data from tokens manager
        ITokenManager.Token[] memory tokens = ITokenManager(
            manager.tokenManager()
        ).getAcceptedTokens();

        // create asset array for the payment info
        ILiquidationPoolManager.Asset[]
            memory assets = new ILiquidationPoolManager.Asset[](tokens.length);
        uint256 ethBalance;

        // loop over each token to add the asset to the asset array and approve pool for transfer of the token
        // @audit what if there is only erc20 tokens in the pool
        for (uint256 i = 0; i < tokens.length; i++) {
            ITokenManager.Token memory token = tokens[i];

            if (token.addr == address(0)) {
                ethBalance = address(this).balance;
                if (ethBalance > 0)
                    assets[i] = ILiquidationPoolManager.Asset(
                        token,
                        ethBalance
                    );
            } else {
                IERC20 ierc20 = IERC20(token.addr);
                uint256 erc20balance = ierc20.balanceOf(address(this));
                if (erc20balance > 0) {
                    assets[i] = ILiquidationPoolManager.Asset(
                        token,
                        erc20balance
                    );
                    // @audit return values not checked for the approve
                    ierc20.approve(pool, erc20balance);
                }
            }
        }

        // call distribute Assets in the pool
        LiquidationPool(pool).distributeAssets{value: ethBalance}(
            assets,
            manager.collateralRate(),
            manager.HUNDRED_PC()
        );

        // transfer the remaining rewards to the protocol
        forwardRemainingRewards(tokens);
    }

    // set the new pool fee percentage

    // @audit no event emitted
    // @audit same address can be added again
    function setPoolFeePercentage(
        uint32 _poolFeePercentage
    ) external onlyOwner {
        poolFeePercentage = _poolFeePercentage;
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import 'src/LiquidationPool.sol';
import 'src/interfaces/ILiquidationPoolManager.sol';
import 'src/interfaces/ISmartVaultManager.sol';
import 'src/interfaces/ITokenManager.sol';
import { console2 } from 'forge-std/console2.sol';

// @audit-info what if the smartVaultManager is updated, how will that be updated in the pool manager: it just stores the proxy address.
// only the implementation is updated
contract LiquidationPoolManager is Ownable {
    uint32 public constant HUNDRED_PC = 100_000;

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
        pool =
            address(new LiquidationPool(_TST, _EUROs, _eurUsd, ISmartVaultManager(_smartVaultManager).tokenManager()));
        TST = _TST;
        EUROs = _EUROs;
        smartVaultManager = _smartVaultManager;
        protocol = _protocol;
        poolFeePercentage = _poolFeePercentage;
    }

    receive() external payable { }

    // @audit-info where will this euro come from in the first place: fees generated by mint, burn and swap in the vaults
    function distributeFees() public {
        IERC20 eurosToken = IERC20(EUROs);
        uint _feesForPool = (eurosToken.balanceOf(address(this)) * poolFeePercentage) / HUNDRED_PC;
        if (_feesForPool > 0) {
            // @audit-info return values not checked: know issues
            eurosToken.approve(pool, _feesForPool);
            LiquidationPool(pool).distributeFees(_feesForPool);
        }
        // @audit-info return values not checked: known issue
        eurosToken.transfer(protocol, eurosToken.balanceOf(address(this)));
    }

    function forwardRemainingRewards(ITokenManager.Token[] memory _tokens) private {
        for (uint i = 0; i < _tokens.length; i++) {
            ITokenManager.Token memory _token = _tokens[i];
            if (_token.addr == address(0)) {
                uint balance = address(this).balance;
                if (balance > 0) {
                    (bool _sent,) = protocol.call{ value: balance }('');
                    require(_sent);
                }
            } else {
                uint balance = IERC20(_token.addr).balanceOf(address(this));
                // @audit-info return values of transfer function is not used: known issue
                if (balance > 0) {
                    IERC20(_token.addr).transfer(protocol, balance);
                }
            }
        }
    }

    function runLiquidation(uint _tokenId) external {
        // get the manager
        ISmartVaultManager manager = ISmartVaultManager(smartVaultManager);

        // call liquidiate vault for the token Id
        manager.liquidateVault(_tokenId);

        // @audit-info will the fee be distributed to all of the people who has even reached the consolidate rewards: yes
        distributeFees();

        // get the accepted tokens data from tokens manager
        ITokenManager.Token[] memory tokens = ITokenManager(manager.tokenManager()).getAcceptedTokens();

        // create asset array for the payment info
        ILiquidationPoolManager.Asset[] memory assets = new ILiquidationPoolManager.Asset[](tokens.length);
        uint ethBalance;

        // loop over each token to add the asset to the asset array and approve pool for transfer of the token
        for (uint i = 0; i < tokens.length; i++) {
            ITokenManager.Token memory token = tokens[i];

            if (token.addr == address(0)) {
                ethBalance = address(this).balance;
                if (ethBalance > 0) {
                    assets[i] = ILiquidationPoolManager.Asset(token, ethBalance);
                }
            } else {
                IERC20 ierc20 = IERC20(token.addr);
                uint erc20balance = ierc20.balanceOf(address(this));
                if (erc20balance > 0) {
                    assets[i] = ILiquidationPoolManager.Asset(token, erc20balance);
                    // @audit-info return values not checked for the approve: known issue
                    ierc20.approve(pool, erc20balance);
                }
            }
        }

        // call distribute Assets in the pool
        LiquidationPool(pool).distributeAssets{ value: ethBalance }(
            assets, manager.collateralRate(), manager.HUNDRED_PC()
        );

        // transfer the remaining rewards to the protocol
        forwardRemainingRewards(tokens);
    }

    // set the new pool fee percentage

    // @audit-info no event emitted added
    // @audit-info same address can be added again
    function setPoolFeePercentage(uint32 _poolFeePercentage) external onlyOwner {
        poolFeePercentage = _poolFeePercentage;
    }
}

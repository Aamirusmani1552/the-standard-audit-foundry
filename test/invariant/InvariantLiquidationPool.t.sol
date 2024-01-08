// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import { Handler } from './Handler.t.sol';
import { Test } from 'forge-std/Test.sol';
import { Common } from '../Common.t.sol';

contract InvariantLiquidationPool is Test {
    Handler public handler;
    Common.ContractInstances public contracts;
    Common.TokensInstances public tokens;
    Common.PriceFeedsInstances public priceFeeds;

    function setUp() public {
        handler = new Handler();
        handler.setUp();

        contracts = handler.getProtocolContracts();
        tokens = handler.getTokensContracts();
        priceFeeds = handler.getPriceFeedsContracts();

        targetContract(address(handler));
    }

    function invariant_increasePostion() public {
        // pre conditions
        uint euroBalanceOfLiquidationPool = tokens.eurosToken.balanceOf(address(contracts.liquidationPool));
        uint tstBalanceOfLiquidationPool = tokens.tstToken.balanceOf(address(contracts.liquidationPool));

        tokens.tstToken.mint(address(this), 1000 ether);
        // tokens.eurosToken.mint(address(this), 1000 ether);

        // actions
        (uint _amountEuros, uint _amountTSTs) = handler.increaseLiquidationPoolPosition(1000 ether, 0);

        // post conditions
        uint euroBalanceOfLiquidationPoolAfter = tokens.eurosToken.balanceOf(address(contracts.liquidationPool));
        uint tstBalanceOfLiquidationPoolAfter = tokens.tstToken.balanceOf(address(contracts.liquidationPool));

        assertEq(euroBalanceOfLiquidationPoolAfter, euroBalanceOfLiquidationPool + _amountEuros);
        assertEq(tstBalanceOfLiquidationPoolAfter, tstBalanceOfLiquidationPool + _amountTSTs);
    }
}

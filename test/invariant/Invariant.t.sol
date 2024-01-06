// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import {Handler} from "./Handler.t.sol";
import {Test} from "forge-std/Test.sol";
import {Common} from "../Common.t.sol";

contract Invariant is Test{
    Handler public handler;
    Common.ContractInstances public contracts;
    Common.TokensInstances  public tokens;
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
        uint256 euroBalanceOfLiquidationPool = tokens.eurosToken.balanceOf(address(contracts.liquidationPool));
        uint256 tstBalanceOfLiquidationPool = tokens.tstToken.balanceOf(address(contracts.liquidationPool));

        // actions
        (uint256 _amountEuros, uint256 _amountTSTs) = handler.increaseLiquidationPoolPosition(1000 ether, 1000 ether);

        // post conditions
        uint256 euroBalanceOfLiquidationPoolAfter = tokens.eurosToken.balanceOf(address(contracts.liquidationPool));
        uint256 tstBalanceOfLiquidationPoolAfter = tokens.tstToken.balanceOf(address(contracts.liquidationPool));

        assertEq(euroBalanceOfLiquidationPoolAfter, euroBalanceOfLiquidationPool + _amountEuros);
        assertEq(tstBalanceOfLiquidationPoolAfter, tstBalanceOfLiquidationPool + _amountTSTs);

    }
}
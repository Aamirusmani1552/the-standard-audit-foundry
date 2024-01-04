// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Common, console2, LiquidationPool} from "../Common.t.sol";

contract Fuzz is Common {
    function setUp() public override {
        super.setUp();
    }

    // tested for 100k runs with values between 0 and 10 billion
    function testFuzz_increasePosition(uint256 amount) public {
        vm.assume(amount > 0 && amount < 10_000_000_000 ether);
        // mingting some euros to alice
        tokens.eurosToken.mint(alice, amount);

        // minting some tst to alice
        tokens.tstToken.mint(alice, amount);

        // for now give some tokens to liquidation pool manager
        tokens.eurosToken.mint(
            address(contracts.liquidationPoolManager),
            amount
        );

        // alice increases position
        vm.startPrank(alice);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        contracts.liquidationPool.increasePosition(amount, amount);
        vm.stopPrank();

        // getting position and rewards for alice
        (
            LiquidationPool.Position memory _position,
            LiquidationPool.Reward[] memory _reward
        ) = contracts.liquidationPool.position(alice);

        assertEq(_position.TST, amount);
        assertEq(_position.EUROs, amount);
    }
}

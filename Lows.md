# Summary

| Severity        | Issue                                                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| [[L-0](#low-0)] | `renounceOwnership()` should be overidden in `SmartVaultManagerV5`                                                     |
| [[L-1](#low-1)] | No natspac added to any contract.                                                                                      |
| [[L-2](#low-2)] | Divide before Multiply can cause rounding Errors                                                                       |
| [[L-3](#low-3)] | No events are emitted in the `LiquidationPool` and `LiquidationPoolManager`                                            |
| [[L-4](#low-4)] | Vault Can get unneccessarily liquidated if the avg tokens price is lower than the original price                       |
| [[L-5](#low-5)] | Sensitive Chainlink price feeds with high heartbeat and deviation can cause arbitrage opportunities and losses as well |

---

# Lows

## [L-0] `renounceOwnership()` should be overidden in `SmartVaultManagerV5` <a id="low-0" ></a>

### Relevant Github Links

https://github.com/Cyfrin/2023-12-the-standard/blob/main/contracts/SmartVaultV3.sol

### Summary

A potential vulnerability exists in the `SmartVaultManager::renounceOwnership(...)` function, which, if mistakenly called, could lead to the loss of contract ownership.

### Vulnerability Details

The `SmartVaultManager` inherits from the` OwnableUpgradeable` contract of OpenZeppelin, introducing the function renounceOwnership. If this function is inadvertently triggered by the owner, it would result in the transfer of ownership to the zero address. Consequently, all functions requiring owner privileges would become inoperable. To prevent such issues, it is crucial to override this function in the child contract, considering the significant role played by `SmartVaultManager` in setting important variables across different contracts.

This override ensures that renouncing ownership is explicitly disallowed, preventing the contract from becoming useless.

### Impact

The vulnerability poses a risk of complete loss of ownership for the contract.

### Tools Used

- Manual Review

### Recommendations

It is strongly recommended to override the `renounceOwnership` function in the `SmartVaultManager` contract. The override should either disallow renouncing ownership entirely or include additional checks before transferring ownership to mitigate the associated risks.

```diff
+    function renounceOwnership() public override onlyOwner {
+        revert("Ownership cannot be renounced for SmartVaultManager");
+    }

```

---

## [L-1] No natspac added to any contract.<a id="low-1" ></a>

### Relevant Github Links

https://github.com/Cyfrin/2023-12-the-standard/blob/main/contracts/LiquidationPool.sol

https://github.com/Cyfrin/2023-12-the-standard/blob/main/contracts/LiquidationPoolManager.so

https://github.com/Cyfrin/2023-12-the-standard/blob/main/contracts/SmartVaultManagerV5.sol

https://github.com/Cyfrin/2023-12-the-standard/blob/main/contracts/SmartVaultV3.sol

### Summary

No NatSpec documentation has been added to any contract, including both functions and state variables.

### Vulnerability Details

The absence of NatSpec documentation across all contracts poses a challenge for users seeking to understand the various functionalities provided by the code. Additionally, developers unfamiliar with the codebase may face difficulties comprehending its workings.

### Impact

Insufficient information on code functionality leads to confusion.

### Tools Used

- Manual Review

### Recommendations

It is advisable to incorporate NatSpec documentation, especially for critical functions within the contracts.

---

## [L-2] Divide before Multiply can cause rounding Errors <a id="low-2" ></a>

### Relevant Github Links

https://github.com/Cyfrin/2023-12-the-standard/blob/91132936cb09ef9bf82f38ab1106346e2ad60f91/contracts/LiquidationPool.sol#L220C1-L221C60

### Summary

In `LiquidationPool::distributeAssets(...)` Divide is done before multiply that can cause rounding Errors if amounts are small.

### Vulnerability Details

`LiquidationPool::distributeAssets(...)` is used to distribute liquidated assets to the user. Id uses the below calculation to get the euro value of the asset proportion:

```javascript
File: 2023-12-the-standard/contracts/LiquidationPool.sol#distributeAssets

        uint256 costInEuros = _portion * 10 ** (18 - asset.token.dec) * uint256(assetPriceUsd) / uint256(priceEurUsd)
                            * _hundredPC / _collateralRate;
```

GitHub: [220-221](https://github.com/Cyfrin/2023-12-the-standard/blob/91132936cb09ef9bf82f38ab1106346e2ad60f91/contracts/LiquidationPool.sol#L220C1-L221C60)

As you can see divide is done before the multiply in this calculation. This can lead to rounding issue that could lead loss of asset rewards to the user if the distrbiuted assets amount is small.

### Impact

Can cause loss of distribute rewards to the user.

### Tools Used

- Manual Review

### Recommendations

It is recommended to do the following changes:

```diff
File: 2023-12-the-standard/contracts/LiquidationPool.sol#distributeAssets

-        uint256 costInEuros = _portion * 10 ** (18 - asset.token.dec) * uint256(assetPriceUsd) / uint256(priceEurUsd) * _hundredPC / _collateralRate;
+        uint256 costInEuros = (_portion * 10 ** (18 - asset.token.dec) * uint256(assetPriceUsd) * _hundredPC) / uint256(priceEurUsd) / _collateralRate;

```

---

## [L-3] No events are emitted in the `LiquidationPool` and `LiquidationPoolManager` <a id="low-3" ></a>

### Relevant Github Links

https://github.com/Cyfrin/2023-12-the-standard/blob/91132936cb09ef9bf82f38ab1106346e2ad60f91/contracts/LiquidationPool.sol#L220C1-L221C60

### Summary

Lack of event can cause integration issues.

### Vulnerability Details

Events are very important part of the codebase as these are used by the indexers to return the data to frontend where it can be used to show changed information to the user. But in both `LiqudiationPool` and `LiquidationPoolManager`, not a single event is emitted for state changes. Also there are lack of events in other contract.

### Impact

Can cause integration issue.

### Tools Used

- Manual Review

### Recommendations

It is recommended to add the events for neccessary state updates.

---

## [L-4] Vault Can get unneccessarily liquidated if the avg tokens price is lower than the original price <a id="low-4"></a>

### Relevant Github Links

https://github.com/Cyfrin/2023-12-the-standard/blob/91132936cb09ef9bf82f38ab1106346e2ad60f91/contracts/SmartVaultV3.sol#L67C1-L73C6

### Summary

`SmartVaultV3` depends on the `Calculator` contract to fetch the token price and tokens conversion. But it can return wrong price and cause liquidation of assets.

### Vulnerability Details

`SmartVaultV3::eurosCollateral(...)` is used to get the value of collateral tokens in euros. This function further ensure that the `SmartVaultV3::undercollateralised()` returns true value by giving correct tokens price. To get the values of all the tokens `eurosCollateral(...)` function uses `Calculator::tokenToEurAvg(...)` function to calculate the token's EUROs price. But this `tokenToEurAvg` takes the data of last 4 rounds and gives the average price on the basis of that. If the average price returned is less than the current actual price of the token, then `SmartVaultV3::undercollateralised()` can become true and the vault can get unncessarily undercollateralised.

```javascript
    function euroCollateral() private view returns (uint256 euros) {
        ITokenManager.Token[] memory acceptedTokens = getTokenManager().getAcceptedTokens();
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
@>            euros += calculator.tokenToEurAvg(token, getAssetBalance(token.symbol, token.addr));
        }
    }
```

GitHub: [67-73](https://github.com/Cyfrin/2023-12-the-standard/blob/91132936cb09ef9bf82f38ab1106346e2ad60f91/contracts/SmartVaultV3.sol#L67C1-L73C6)

This is possible if from the four round of price data, first three rounds show decrease in token's EUROs value. but last one show the increase in the value.

### Impact

Can cause liquidation of vault.

### Tools Used

- Manual Review

### Recommendations

It is recommended to use the data of current round instead of the last four average round with proper checks.

---

## [L-5] Sensitive Chainlink price feeds with high heartbeat and deviation can cause arbitrage opportunities and losses as well <a id="low-5"></a>

### Summary

Assets with long heartbeat and high deviation can create arbitrage opportunities as well as losses.

### Vulnerability Details

Every chainlink price feeds has a heartbeat and a deviation rate. Both are responsible for the udpate of price feeds. If one of them is true then the price update will be done. For example:

`WBTC / USD` price feed has following deviation and heartbeat:

Deivation: `0.05`
Heartbeat: `84600s` or `1 day`

This means a price feed price update will be done if the asset price has been changed `0.05 %` or `84600s` seconds are passed since last update. But this could be a problem and can create arbitrage opportunities. Like if we take the current example of `WBTC / USD`, the current price of `WBTC` in usd is for example `~45000`, but the price changed by `0.04%` in negative direction and less than a day is passed for that. Then the new price will be `~44982`. But the price update will not be done and user keeps on getting the liquidated assets at the inflated prices. This can create arbitrage opportunities throughout the protocol as the price feeds are used mostly everywhere.

This is also true in other way. If the price is increase but the deviation and heartbeat hasn't met, the returned prices will be low causing the losses to the user.

### Impact

Can cause liquidation of vault.

### Tools Used

- Manual Review

### Recommendations

Do not add tokens as a collateral token if both `Heartbeat` and `deviation` is very high. As well as do not accept prices if the update of the price is done before a particular amount of time. Also some chains do not support price feeds of initially used collateral token. The protocol should be deployed keeping in mind that as well.

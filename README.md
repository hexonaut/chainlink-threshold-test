## Chainlink Threshold Test

Run `forge test -vv` to see the results of the test. It should be able to update the price with 4 signers (+1 transmission signer). This is 2 above the `threshold` value. So in the example `threshold` is 3 and we can update the oracle with 5 signatures.

## Local testnet scenarios

### [Main](./main.yaml)

This is the "happy flow" scenario. It's best to use it to verify 
that nothing is broken and the ssv network works as expected. 

#### Running 
- 2 geth/lighthouse node pairs, 
  - each has 32 validators
- 4 ssv nodes
  - serve 10 validators 
  - all use the first geth/lighthouse node

### [Majority fork](./majority-fork.yaml)

[Rationale](./MAJORITY_FORK.md)

This scenario simulates the Pectra fork incident on Holesky and Sepolia networks.
Since `ethpandaops/ethereum-package` passes `deposit_contract_address` to all nodes,
this scenario misconfigures the `geth` using an image 
with modified source code instead of misconfiguring it in the params file.

The scenario causes a network fork and triggering ssv nodes' protection, 
so ssv nodes' logs should not process attester/sync committee duties and should contain some of the following logs:
- `unexpected source epoch`
- `unexpected target epoch`
- `unexpected source root`
- `unexpected target root`

#### Running

- 16 geth/lighthouse nodes
  - 6 are configured correctly
  - 10 are misconfigured
  - faulty nodes are majority 
  - faulty nodes don't cause justification (10/16 < 2/3)
- 4 ssv nodes 
  - serve 10 validators
  - ssv nodes 1-3 use geth/lighthouse nodes 1-3, all of them are configured correctly
  - ssv node 4 uses the last geth/lighthouse node, the geth node is misconfigured

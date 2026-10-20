// Command ssv is a hive simulator that brings up a minimal SSV devnet and checks the SSV cluster performs
// its duties end to end:
//
//	geth ── lighthouse BN ── lighthouse VC (validators [0,64))
//	 │            │
//	 └── 4× ssv-node (operators 1-4, validators [64,74) via the static keyshares)
//
// It is the hive counterpart of ssv-mini's Kurtosis package, built for start-up speed:
//   - genesis is rendered in-process from committed templates (no ethereum-package / genesis containers);
//   - the SSV contract deployment and operator/validator registration are replayed as pre-signed raw txs
//     (static/recorded/txs.json, see scripts/record-txs.sh) instead of running hardhat against the live chain,
//     so they all land in the first block;
//   - a throwaway geth --dev mines those txs plus the 8-block SSV follow distance in ~1s blocks, and the
//     beacon chain is shadow-forked on top, one epoch in the past: SSV nodes start immediately and attest in
//     epoch 1, rather than after ~10 real slots of chain plus all of epoch 0.
package main

import (
	"github.com/ethereum/hive/hivesim"
)

func main() {
	suite := hivesim.Suite{
		Name:        "ssv",
		Description: "End-to-end SSV devnet: a 4-operator SSV cluster runs 10 validators alongside a lighthouse VC.",
	}
	suite.Add(hivesim.TestSpec{
		Name:        "cluster-attests",
		Description: "Boots geth + lighthouse + 4 SSV nodes, replays the SSV contract deployment and registrations, and waits until every SSV-managed validator is live (attested) in one epoch.",
		Run:         runClusterAttests,
	})
	hivesim.MustRunSuite(hivesim.New(), suite)
}

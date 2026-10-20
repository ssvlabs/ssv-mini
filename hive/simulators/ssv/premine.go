package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/hive/hivesim"
)

// premine builds the EL history the devnet starts from: the SSV contract deployment and registrations,
// followed by enough blocks to bury their events past the SSV event syncer's follow distance.
//
// SSV nodes learn operators and validators from contract events (which a genesis alloc can't hold), and a
// node exits if its event syncer has nothing to process yet. On a fresh chain that means waiting ~10 slots
// before starting them. A throwaway geth --dev mines the same blocks in ~1s each instead; the real geth then
// imports them and the beacon chain is shadow-forked on top of their head.
//
// This has to happen per run, not once: SSV rejects a history sync whose last block is older than 5 minutes
// (eventsyncer's defaultStalenessThreshold).
//
// It writes chain.rlp and the head block into net.dir and returns the head block's timestamp.
func premine(ctx context.Context, t *hivesim.T, clientType string, net *devnet) (headBlockFile string, headTime time.Time, err error) {
	dev := t.StartClient(clientType, hivesim.WithStaticFiles(map[string]string{"/genesis.json": net.elGenesis}))
	defer t.Sim.StopClient(t.SuiteID, t.TestID, dev.Container)

	hashes, err := replayTxs(ctx, dev.RPC())
	if err != nil {
		return "", time.Time{}, fmt.Errorf("replay txs: %w", err)
	}
	txBlock, err := waitReceipts(ctx, dev.RPC(), hashes)
	if err != nil {
		return "", time.Time{}, err
	}
	// One block past the follow distance, so the history sync covers the registrations.
	head := txBlock + ssvFollowDistance + 1
	if err := waitBlock(ctx, dev.RPC(), head); err != nil {
		return "", time.Time{}, err
	}

	// chain.rlp is just the RLP blocks back to back (what `geth export` writes and `geth import` reads).
	var chain []byte
	for n := uint64(1); n <= head; n++ {
		var raw hexutil.Bytes
		if err := dev.RPC().CallContext(ctx, &raw, "debug_getRawBlock", hexutil.EncodeUint64(n)); err != nil {
			return "", time.Time{}, fmt.Errorf("block %d: %w", n, err)
		}
		chain = append(chain, raw...)
	}
	net.elChain = filepath.Join(net.dir, "chain.rlp")
	if err := os.WriteFile(net.elChain, chain, 0o644); err != nil {
		return "", time.Time{}, err
	}

	var block json.RawMessage
	if err := dev.RPC().CallContext(ctx, &block, "eth_getBlockByNumber", hexutil.EncodeUint64(head), false); err != nil {
		return "", time.Time{}, err
	}
	var fields struct {
		Timestamp hexutil.Uint64 `json:"timestamp"`
	}
	if err := json.Unmarshal(block, &fields); err != nil {
		return "", time.Time{}, err
	}
	// eth-genesis-state-generator --shadow-fork-block wants a full JSON-RPC response.
	headBlockFile = filepath.Join(net.dir, "head-block.json")
	if err := writeJSON(headBlockFile, map[string]any{"jsonrpc": "2.0", "id": 1, "result": block}); err != nil {
		return "", time.Time{}, err
	}
	t.Logf("pre-mined blocks 1..%d (registrations in block %d), %s", head, txBlock, strconv.Itoa(len(chain))+" bytes")
	return headBlockFile, time.Unix(int64(fields.Timestamp), 0), nil
}

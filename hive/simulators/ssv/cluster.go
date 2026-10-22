package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/hive/hivesim"
)

const slotsPerEpoch = 32

// Knobs, set at build time with `hive --sim.buildarg NAME=value` (see the Dockerfile).
var (
	slotDuration = envDuration("SSV_SLOT_SECONDS", 12*time.Second, time.Second)
	genesisDelay = envDuration("SSV_GENESIS_DELAY", 15*time.Second, time.Second)
	testTimeout  = envDuration("SSV_TIMEOUT", 15*time.Minute, time.Second)
	// premined (default): a throwaway geth --dev mines the registrations past the follow distance first (see
	// premine.go), the real geth imports that chain and the beacon chain shadow-forks its head. fresh: replay
	// the registration txs on a new chain and wait out the follow distance, like the Kurtosis package does.
	premined = os.Getenv("SSV_CHAIN") != "fresh"
)

// gethParams configures hive's go-ethereum client for the devnet's chain config (everything through
// Osaka/BPO2 at genesis, matching ethereum-package's Fulu-at-genesis network).
var gethParams = hivesim.Params{
	"HIVE_CHAIN_ID":                  fmt.Sprint(chainID),
	"HIVE_NETWORK_ID":                fmt.Sprint(chainID),
	"HIVE_FORK_HOMESTEAD":            "0",
	"HIVE_FORK_TANGERINE":            "0",
	"HIVE_FORK_SPURIOUS":             "0",
	"HIVE_FORK_BYZANTIUM":            "0",
	"HIVE_FORK_CONSTANTINOPLE":       "0",
	"HIVE_FORK_PETERSBURG":           "0",
	"HIVE_FORK_ISTANBUL":             "0",
	"HIVE_FORK_BERLIN":               "0",
	"HIVE_FORK_LONDON":               "0",
	"HIVE_MERGE_BLOCK_ID":            "0",
	"HIVE_TERMINAL_TOTAL_DIFFICULTY": "0",
	"HIVE_SHANGHAI_TIMESTAMP":        "0",
	"HIVE_CANCUN_TIMESTAMP":          "0",
	"HIVE_PRAGUE_TIMESTAMP":          "0",
	"HIVE_OSAKA_TIMESTAMP":           "0",
	"HIVE_BPO1_TIMESTAMP":            "0",
	"HIVE_BPO2_TIMESTAMP":            "0",
	"HIVE_LOGLEVEL":                  "3",
}

func runClusterAttests(t *hivesim.T) {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()
	step := func(format string, args ...any) {
		t.Logf("[+%6.1fs] %s", time.Since(start).Seconds(), fmt.Sprintf(format, args...))
	}

	types := clientTypes(t)

	dir, err := os.MkdirTemp("", "ssv-devnet")
	if err != nil {
		t.Fatal(err)
	}
	net := newDevnet(dir, slotDuration)
	var shadowFork string
	genesisTime := start.Add(genesisDelay).Truncate(time.Second)
	if premined {
		if err := net.renderEL(start.Add(-time.Minute)); err != nil {
			t.Fatalf("render EL genesis: %v", err)
		}
		var headTime time.Time
		if shadowFork, headTime, err = premine(ctx, t, types["ssv-premine"], net); err != nil {
			t.Fatalf("pre-mine: %v", err)
		}
		step("pre-mined the registrations")
		// The first beacon block builds on the pre-mined head, so its slot must come after the head's
		// timestamp. And an SSV node refuses to attest in epoch 0 (its attestation data has source == target ==
		// genesis: "attestation data source >= target") and panics if started before genesis. So put genesis
		// one epoch before that first slot: the chain opens at the end of epoch 0, mostly skipped slots, and
		// epoch 1 starts as the clients come up.
		firstSlot := time.Now().Add(genesisDelay)
		if !firstSlot.After(headTime) {
			firstSlot = headTime.Add(time.Second)
		}
		genesisTime = firstSlot.Add(-slotsPerEpoch * slotDuration).Truncate(time.Second).Add(time.Second)
	} else if err := net.renderEL(genesisTime); err != nil {
		t.Fatalf("render EL genesis: %v", err)
	}
	if err := net.renderCL(genesisTime, shadowFork); err != nil {
		t.Fatalf("render CL genesis: %v", err)
	}
	step("genesis rendered (genesis at %s, %s slots, premined=%v)", net.genesisTime.Format(time.TimeOnly), slotDuration, premined)

	elFiles := map[string]string{"/genesis.json": net.elGenesis}
	if premined {
		elFiles["/chain.rlp"] = net.elChain
	}
	el := t.StartClient(types["go-ethereum"], gethParams, hivesim.WithStaticFiles(elFiles))
	elHead, _ := blockNumber(ctx, el.RPC())
	step("geth up (%s, head block %d)", el.IP, elHead)

	var hashes []string
	if !premined {
		// Pre-genesis: the txs wait in the pool and land in the first blocks.
		if hashes, err = replayTxs(ctx, el.RPC()); err != nil {
			t.Fatalf("replay txs: %v", err)
		}
		step("submitted %d deployment/registration txs", len(hashes))
	}

	testnetFiles := map[string]string{
		"/hive/input/testnet/config.yaml": net.clConfig,
		"/hive/input/testnet/genesis.ssz": net.clGenesis,
	}
	bn := t.StartClient(types["ssv-lighthouse-bn"],
		hivesim.Params{"HIVE_SSV_EL_IP": el.IP.String(), "HIVE_CHECK_LIVE_PORT": "4000"},
		hivesim.WithStaticFiles(testnetFiles))
	beacon := beaconAPI{base: fmt.Sprintf("http://%s:4000", bn.IP)}
	step("lighthouse BN up (%s)", bn.IP)

	vcFiles, err := net.vcKeystoreFiles()
	if err != nil {
		t.Fatal(err)
	}
	for dst, src := range testnetFiles {
		vcFiles[dst] = src
	}
	t.StartClient(types["ssv-lighthouse-vc"],
		hivesim.Params{"HIVE_SSV_BN_IP": bn.IP.String(), "HIVE_CHECK_LIVE_PORT": "0"},
		hivesim.WithStaticFiles(vcFiles))
	step("lighthouse VC up (%d validators)", vcValidators)

	eth1WS := fmt.Sprintf("ws://%s:8546", el.IP)
	if premined {
		// The registry events are already past the follow distance: start right away.
		startSSVNodes(t, types["ssv-node"], dir, beacon.base, eth1WS)
		step("%d SSV nodes started", operatorCount)
	}

	// Fail fast if the chain doesn't start (e.g. a client crashed on start-up) rather than at the timeout.
	chainStart := net.genesisTime
	if time.Now().After(chainStart) {
		chainStart = time.Now()
	}
	firstBlockCtx, cancelFirst := context.WithDeadline(ctx, chainStart.Add(4*slotDuration))
	for {
		if head, err := beacon.headSlot(firstBlockCtx); err == nil && head > 0 {
			step("chain started (head slot %d)", head)
			break
		}
		select {
		case <-firstBlockCtx.Done():
			t.Fatalf("no beacon block within 4 slots: check the ssv-lighthouse-bn/-vc and go-ethereum client logs")
		case <-time.After(time.Second):
		}
	}
	cancelFirst()

	if !premined {
		lastBlock, err := waitReceipts(ctx, el.RPC(), hashes)
		if err != nil {
			t.Fatalf("deployment/registration: %v", err)
		}
		step("all %d txs mined by block %d", len(hashes), lastBlock)

		// An SSV node's event syncer only reads blocks past an 8-block follow distance, and its health check
		// kills the node if it has processed nothing yet. So hold the nodes back until the registry events
		// are that deep (this is ssv-mini's "wait for block 16").
		if err := waitBlock(ctx, el.RPC(), lastBlock+ssvFollowDistance); err != nil {
			t.Fatalf("waiting for follow distance: %v", err)
		}
		step("EL at block %d: registry events past the follow distance", lastBlock+ssvFollowDistance)
		startSSVNodes(t, types["ssv-node"], dir, beacon.base, eth1WS)
		step("%d SSV nodes started", operatorCount)
	}

	ssvValidators := make([]uint64, 0, genesisValidators-vcValidators)
	for i := uint64(vcValidators); i < genesisValidators; i++ {
		ssvValidators = append(ssvValidators, i)
	}
	waitClusterLive(ctx, t, step, net, beacon, el, ssvValidators)
}

// waitClusterLive polls the beacon node's liveness endpoint until every SSV validator has been live (seen
// attesting or proposing) in some epoch — i.e. the cluster reached consensus and its duties landed for each
// of them. Single misses (a late attestation) are normal, so this doesn't require one perfect epoch.
func waitClusterLive(ctx context.Context, t *hivesim.T, step func(string, ...any), net *devnet, beacon beaconAPI, el *hivesim.Client, validators []uint64) {
	seen := map[uint64]bool{}
	reported := map[uint64]bool{} // epochs whose final count was logged
	lastReport := time.Time{}
	for {
		slot := net.currentSlot()
		epoch := slot / slotsPerEpoch
		for _, e := range []uint64{max(epoch, 1) - 1, epoch} {
			live, err := beacon.liveness(ctx, e, validators)
			if err != nil {
				continue // pre-genesis, or the BN isn't serving the epoch yet
			}
			n := 0
			for _, v := range validators {
				if live[v] {
					n++
					if len(seen) == 0 {
						step("first SSV validator live (validator %d, epoch %d, slot %d)", v, e, slot)
					}
					seen[v] = true
				}
			}
			if e < epoch && !reported[e] {
				reported[e] = true
				step("epoch %d: %d/%d SSV validators live", e, n, len(validators))
			}
		}
		if len(seen) == len(validators) {
			step("every SSV validator live at least once (slot %d, %.0fs after genesis)",
				slot, time.Since(net.genesisTime).Seconds())
			return
		}
		if time.Since(lastReport) > 30*time.Second {
			lastReport = time.Now()
			head, _ := beacon.headSlot(ctx)
			block, _ := blockNumber(ctx, el.RPC())
			step("waiting: slot %d, head %d, EL block %d, %d/%d SSV validators seen live", slot, head, block, len(seen), len(validators))
		}
		select {
		case <-ctx.Done():
			t.Fatalf("only %d/%d SSV validators live before the timeout (%s)", len(seen), len(validators), testTimeout)
		case <-time.After(2 * time.Second):
		}
	}
}

func startSSVNodes(t *hivesim.T, clientType, dir, beaconURL, eth1WS string) {
	var (
		wg   sync.WaitGroup
		mu   sync.Mutex
		errs []string
	)
	for i := 0; i < operatorCount; i++ {
		cfg, err := renderSSVConfig(dir, i, beaconURL, eth1WS)
		if err != nil {
			t.Fatalf("ssv-node-%d config: %v", i, err)
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, _, err := t.Sim.StartClientWithOptions(t.SuiteID, t.TestID, clientType,
				hivesim.Params{"HIVE_CHECK_LIVE_PORT": "0"},
				hivesim.WithStaticFiles(map[string]string{"/hive/input/config.yaml": cfg}))
			if err != nil {
				mu.Lock()
				errs = append(errs, fmt.Sprintf("ssv-node-%d: %v", i, err))
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if len(errs) > 0 {
		t.Fatalf("start SSV nodes: %s", strings.Join(errs, "; "))
	}
}

// clientTypes resolves the client names hive registered (which may carry a nametag, e.g.
// "go-ethereum_v1.17.6") by their base name.
func clientTypes(t *hivesim.T) map[string]string {
	defs, err := t.Sim.ClientTypes()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"go-ethereum", "ssv-premine", "ssv-lighthouse-bn", "ssv-lighthouse-vc", "ssv-node"}
	types := map[string]string{}
	for _, d := range defs {
		for _, w := range want {
			if d.Name == w || strings.HasPrefix(d.Name, w+"_") {
				types[w] = d.Name
			}
		}
	}
	for _, w := range want {
		if types[w] == "" {
			t.Fatalf("client %q not available (run with hive/clients.yaml)", w)
		}
	}
	return types
}

func envDuration(name string, def, unit time.Duration) time.Duration {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil {
		panic(fmt.Sprintf("%s=%q: %v", name, v, err))
	}
	return time.Duration(n * float64(unit))
}

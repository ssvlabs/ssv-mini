package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	fixturesDir = "/fixtures"

	chainID = 3151908

	// Validators [0, vcValidators) run on the lighthouse VC; [vcValidators, genesisValidators) are deposited
	// at genesis but left idle for the SSV cluster (the static keyshares) — the same layout main.star guards.
	vcValidators      = 64
	genesisValidators = 74
)

// devnet holds the rendered genesis: the EL/CL inputs every client gets plus the VC keystores. The EL and CL
// genesis are rendered separately: with a pre-mined chain the CL genesis waits for that chain's head.
type devnet struct {
	dir         string
	slot        time.Duration
	genesisTime time.Time // CL genesis

	elGenesis string // genesis.json
	elChain   string // chain.rlp to import on top of it (pre-mined only)
	clConfig  string // config.yaml
	clGenesis string // genesis.ssz
	vcKeys    string // eth2-val-tools output: keys/<pubkey>/voting-keystore.json, secrets/<pubkey>
}

func newDevnet(dir string, slot time.Duration) *devnet {
	return &devnet{
		dir:       dir,
		slot:      slot,
		elGenesis: filepath.Join(dir, "genesis.json"),
		clConfig:  filepath.Join(dir, "config.yaml"),
		clGenesis: filepath.Join(dir, "genesis.ssz"),
		vcKeys:    filepath.Join(dir, "vc-keys"),
	}
}

// renderEL renders the committed ethereum-package EL genesis template at the given timestamp.
func (d *devnet) renderEL(timestamp time.Time) error {
	var genesis map[string]any
	if err := readJSON(filepath.Join(fixturesDir, "genesis/genesis.json"), &genesis); err != nil {
		return err
	}
	genesis["timestamp"] = fmt.Sprint(timestamp.Unix())
	// The replayed txs were signed against anvil's fee market (maxFee ~1 gwei, tip 1 gwei). A near-zero
	// base fee keeps all of them includable however full the first blocks get.
	genesis["baseFeePerGas"] = "0x7"
	return writeJSON(d.elGenesis, genesis)
}

// renderCL renders the CL config and genesis state for a genesis at genesisTime, plus the VC keystores.
// shadowForkBlock, if set, is the EL block (eth_getBlockByNumber response) the beacon chain starts on;
// otherwise it starts on the EL genesis block.
func (d *devnet) renderCL(genesisTime time.Time, shadowForkBlock string) error {
	d.genesisTime = genesisTime
	ts := genesisTime.Unix()

	config, err := os.ReadFile(filepath.Join(fixturesDir, "genesis/config.yaml"))
	if err != nil {
		return err
	}
	config = setYAML(config, "MIN_GENESIS_TIME", fmt.Sprint(ts))
	config = setYAML(config, "GENESIS_DELAY", "0")
	config = setYAML(config, "SLOT_DURATION_MS", fmt.Sprint(d.slot.Milliseconds()))
	if err := os.WriteFile(d.clConfig, config, 0o644); err != nil {
		return err
	}

	args := []string{"beaconchain",
		"--eth1-config", d.elGenesis,
		"--config", d.clConfig,
		"--mnemonics", filepath.Join(fixturesDir, "genesis/mnemonics.yaml"),
		"--state-output", d.clGenesis,
		"--quiet",
	}
	if shadowForkBlock != "" {
		args = append(args, "--shadow-fork-block", shadowForkBlock)
	}
	if err := run("eth-genesis-state-generator", args...); err != nil {
		return fmt.Errorf("beacon genesis: %w", err)
	}
	// BeaconState.genesis_time is the first field; check the generator honoured our timestamp.
	state, err := os.ReadFile(d.clGenesis)
	if err != nil {
		return err
	}
	if got := binary.LittleEndian.Uint64(state[:8]); got != uint64(ts) {
		return fmt.Errorf("genesis.ssz genesis_time = %d, want %d", got, ts)
	}

	mnemonic, err := genesisMnemonic()
	if err != nil {
		return err
	}
	if err := run("eth2-val-tools", "keystores", "--insecure",
		"--prysm-pass", "unused",
		"--out-loc", d.vcKeys,
		"--source-mnemonic", mnemonic,
		"--source-min", "0",
		"--source-max", fmt.Sprint(vcValidators),
	); err != nil {
		return fmt.Errorf("vc keystores: %w", err)
	}
	return nil
}

// vcKeystoreFiles maps the VC keystores and secrets to their upload paths under /hive/input.
func (d *devnet) vcKeystoreFiles() (map[string]string, error) {
	files := map[string]string{}
	for _, sub := range []string{"keys", "secrets"} {
		root := filepath.Join(d.vcKeys, sub)
		err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() {
				return err
			}
			rel, _ := filepath.Rel(d.vcKeys, path)
			files["/hive/input/"+rel] = path
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return files, nil
}

// currentSlot returns the slot in progress (0 before genesis).
func (d *devnet) currentSlot() uint64 {
	since := time.Since(d.genesisTime)
	if since < 0 {
		return 0
	}
	return uint64(since / d.slot)
}

var mnemonicRe = regexp.MustCompile(`mnemonic:\s*"([^"]+)"`)

func genesisMnemonic() (string, error) {
	b, err := os.ReadFile(filepath.Join(fixturesDir, "genesis/mnemonics.yaml"))
	if err != nil {
		return "", err
	}
	m := mnemonicRe.FindSubmatch(b)
	if m == nil {
		return "", fmt.Errorf("no mnemonic in mnemonics.yaml")
	}
	return string(m[1]), nil
}

// setYAML replaces a top-level `KEY: value` line of the CL config.
func setYAML(config []byte, key, value string) []byte {
	re := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(key) + `:.*$`)
	return re.ReplaceAll(config, []byte(key+": "+value))
}

func run(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func writeJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

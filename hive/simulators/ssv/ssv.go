package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/template"
	"time"

	"github.com/ethereum/go-ethereum/rpc"
)

const (
	operatorCount = 4

	booleDormant   = 1000000000
	ssvAPIPort     = 9232
	ssvMetricsPort = 9240

	// executionclient.DefaultFollowDistance in ssv.
	ssvFollowDistance = 8
)

// ssvConfigData mirrors the data nodes/ssv/node.star feeds config.yml.tmpl, so both harnesses render
// the same node config from the same template.
type ssvConfigData struct {
	LogLevel, LogFormat, DBPath              string
	BeaconNodeAddr, ETH1Addr                 string
	Network, NetworkName                     string
	DomainType, NextDomainType               string
	RegistrySyncOffset, RegistryContractAddr string
	OperatorPrivateKey                       string
	DiscoveryProtocolID, Discovery, ENR      string
	ExporterEnabled                          bool
	ExporterMode                             string
	SSVAPIPort, MetricsAPIPort               int
	EnableTraces                             bool
	BooleEpoch                               int
}

// renderSSVConfig writes the config for SSV node `index` (0-based, like ssv-mini) and returns its path.
// registry is the SSVNetwork proxy the recording deployed.
func renderSSVConfig(dir string, index int, beaconURL, eth1WS, registry string) (string, error) {
	tmpl, err := template.ParseFiles(filepath.Join(fixturesDir, "ssv-config.yml.tmpl"))
	if err != nil {
		return "", err
	}
	key, err := os.ReadFile(filepath.Join(fixturesDir, fmt.Sprintf("keys/operator-%d/unencrypted_private_key.txt", index)))
	if err != nil {
		return "", err
	}
	data := ssvConfigData{
		LogLevel:             "debug",
		LogFormat:            "json",
		DBPath:               fmt.Sprintf("./data/db/%d/", index),
		BeaconNodeAddr:       beaconURL,
		ETH1Addr:             eth1WS,
		Network:              "local-testnet",
		NetworkName:          "testnet",
		DomainType:           "0x00000000",
		NextDomainType:       "0x00000001",
		RegistrySyncOffset:   "1",
		RegistryContractAddr: registry,
		OperatorPrivateKey:   strings.TrimSpace(string(key)),
		DiscoveryProtocolID:  "0x737376647635",
		Discovery:            "mdns",
		ExporterMode:         "standard",
		SSVAPIPort:           ssvAPIPort,
		MetricsAPIPort:       ssvMetricsPort,
		BooleEpoch:           booleDormant,
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", err
	}
	path := filepath.Join(dir, fmt.Sprintf("ssv-config-%d.yaml", index))
	return path, os.WriteFile(path, buf.Bytes(), 0o644)
}

// recording is static/recorded/txs.json (scripts/record-txs.sh), copied into the fixtures by hive/run.sh.
type recording struct {
	ChainID         int    `json:"chainId"`
	SSVNetworkProxy string `json:"ssvNetworkProxy"`
	Txs             []struct {
		Stage string `json:"stage"`
		Hash  string `json:"hash"`
		Raw   string `json:"raw"`
	} `json:"txs"`
}

// loadRecording reads the recorded txs and checks they fit this devnet. The SSV nodes take the registry
// address from the recording itself, so they always watch the contract the replay deploys.
func loadRecording(chainID int) (*recording, error) {
	var rec recording
	if err := readJSON(filepath.Join(fixturesDir, "txs.json"), &rec); err != nil {
		return nil, err
	}
	if rec.ChainID != chainID {
		return nil, fmt.Errorf("txs.json recorded for chain %d, devnet is %d", rec.ChainID, chainID)
	}
	if rec.SSVNetworkProxy == "" {
		return nil, fmt.Errorf("txs.json has no ssvNetworkProxy (recorded by an older record-txs.sh): delete static/recorded/ and re-run")
	}
	// record-txs.sh refuses this too. Batch 2+ of register-validators.cjs passes a cluster snapshot that depends
	// on block numbers, so its replay would revert with IncorrectClusterState.
	n := 0
	for _, tx := range rec.Txs {
		if tx.Stage == "validators" {
			n++
		}
	}
	if n != 1 {
		return nil, fmt.Errorf("txs.json has %d validator registration txs, want 1 (a pool of at most 50): re-run scripts/record-txs.sh", n)
	}
	return &rec, nil
}

// replayTxs submits the recorded deployment + registration txs in nonce order and returns their hashes.
func replayTxs(ctx context.Context, el *rpc.Client, rec *recording) ([]string, error) {
	hashes := make([]string, 0, len(rec.Txs))
	for i, tx := range rec.Txs {
		var hash string
		if err := el.CallContext(ctx, &hash, "eth_sendRawTransaction", tx.Raw); err != nil {
			return nil, fmt.Errorf("tx %d (%s): %w", i, tx.Hash, err)
		}
		hashes = append(hashes, hash)
	}
	return hashes, nil
}

type receipt struct {
	Status      string `json:"status"`
	BlockNumber string `json:"blockNumber"`
}

// waitReceipts waits until every tx is mined and fails on the first revert. It returns the last block.
func waitReceipts(ctx context.Context, el *rpc.Client, hashes []string) (uint64, error) {
	var last uint64
	for i, h := range hashes {
		for {
			var r *receipt
			err := el.CallContext(ctx, &r, "eth_getTransactionReceipt", h)
			// geth answers this until its tx indexer has caught up (right after start), not just for new txs.
			if err != nil && !strings.Contains(err.Error(), "transaction indexing is in progress") {
				return 0, err
			}
			if r != nil {
				if r.Status != "0x1" {
					return 0, fmt.Errorf("tx %d (%s) reverted", i, h)
				}
				var n uint64
				fmt.Sscanf(r.BlockNumber, "0x%x", &n)
				last = max(last, n)
				break
			}
			select {
			case <-ctx.Done():
				return 0, fmt.Errorf("tx %d (%s) not mined: %w", i, h, ctx.Err())
			case <-time.After(500 * time.Millisecond):
			}
		}
	}
	return last, nil
}

func blockNumber(ctx context.Context, el *rpc.Client) (uint64, error) {
	var hex string
	if err := el.CallContext(ctx, &hex, "eth_blockNumber"); err != nil {
		return 0, err
	}
	var n uint64
	_, err := fmt.Sscanf(hex, "0x%x", &n)
	return n, err
}

// waitBlock waits until the EL head reaches block n.
func waitBlock(ctx context.Context, el *rpc.Client, n uint64) error {
	for {
		if head, err := blockNumber(ctx, el); err == nil && head >= n {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

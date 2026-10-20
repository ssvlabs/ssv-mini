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

	ssvNetworkProxy = "0xBFfF570853d97636b78ebf262af953308924D3D8"
	booleDormant    = 1000000000
	ssvAPIPort      = 9232
	ssvMetricsPort  = 9240

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
func renderSSVConfig(dir string, index int, beaconURL, eth1WS string) (string, error) {
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
		RegistryContractAddr: ssvNetworkProxy,
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

type recordedTxs struct {
	ChainID int `json:"chainId"`
	Txs     []struct {
		Hash string `json:"hash"`
		Raw  string `json:"raw"`
	} `json:"txs"`
}

// replayTxs submits the recorded deployment + registration txs in nonce order and returns their hashes.
func replayTxs(ctx context.Context, el *rpc.Client) ([]string, error) {
	var rec recordedTxs
	if err := readJSON(filepath.Join(fixturesDir, "txs.json"), &rec); err != nil {
		return nil, err
	}
	if rec.ChainID != chainID {
		return nil, fmt.Errorf("txs.json recorded for chain %d, devnet is %d", rec.ChainID, chainID)
	}
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

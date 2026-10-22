package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
)

type beaconAPI struct{ base string }

func (b beaconAPI) do(ctx context.Context, method, path string, body any, out any) error {
	var rd io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, b.base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s %s: %s: %s", method, path, resp.Status, raw)
	}
	return json.Unmarshal(raw, out)
}

// headSlot returns the slot of the canonical head block.
func (b beaconAPI) headSlot(ctx context.Context) (uint64, error) {
	var resp struct {
		Data struct {
			Header struct {
				Message struct {
					Slot string `json:"slot"`
				} `json:"message"`
			} `json:"header"`
		} `json:"data"`
	}
	if err := b.do(ctx, http.MethodGet, "/eth/v1/beacon/headers/head", nil, &resp); err != nil {
		return 0, err
	}
	return strconv.ParseUint(resp.Data.Header.Message.Slot, 10, 64)
}

// liveness returns which of the given validators the beacon node saw attest (or propose) in epoch.
func (b beaconAPI) liveness(ctx context.Context, epoch uint64, indices []uint64) (map[uint64]bool, error) {
	body := make([]string, len(indices))
	for i, idx := range indices {
		body[i] = strconv.FormatUint(idx, 10)
	}
	var resp struct {
		Data []struct {
			Index  string `json:"index"`
			IsLive bool   `json:"is_live"`
		} `json:"data"`
	}
	if err := b.do(ctx, http.MethodPost, fmt.Sprintf("/eth/v1/validator/liveness/%d", epoch), body, &resp); err != nil {
		return nil, err
	}
	live := map[uint64]bool{}
	for _, d := range resp.Data {
		idx, err := strconv.ParseUint(d.Index, 10, 64)
		if err != nil {
			return nil, err
		}
		live[idx] = d.IsLive
	}
	return live, nil
}

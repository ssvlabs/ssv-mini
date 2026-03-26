package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/gorilla/websocket"
)

var (
	faultyBlock atomic.Int64 // -1 = disabled
	hitCount    atomic.Int64
	mu          sync.RWMutex
)

func init() {
	faultyBlock.Store(-1)
}

type filterParams struct {
	FromBlock string `json:"fromBlock"`
	ToBlock   string `json:"toBlock"`
}

func hexToUint64(s string) (uint64, error) {
	s = strings.TrimPrefix(s, "0x")
	return strconv.ParseUint(s, 16, 64)
}

// processResponse modifies eth_getLogs results to drop logs from the faulty block.
// On wide queries (multiple blocks in result), it strips the target block's logs.
// On single-block results, it passes through honestly (so bloom retry recovery works).
func processResponse(body []byte) []byte {
	target := faultyBlock.Load()
	if target < 0 {
		return body
	}

	// Try to parse as JSON-RPC response with a log array result
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		return body
	}

	result, ok := raw["result"]
	if !ok {
		return body
	}

	var logs []map[string]any
	if err := json.Unmarshal(result, &logs); err != nil {
		return body
	}
	if len(logs) == 0 {
		return body
	}

	// Count distinct blocks in result
	blockSet := map[uint64]bool{}
	hasTarget := false
	for _, l := range logs {
		bn, ok := l["blockNumber"].(string)
		if !ok {
			continue
		}
		n, err := hexToUint64(bn)
		if err != nil {
			continue
		}
		blockSet[n] = true
		if n == uint64(target) {
			hasTarget = true
		}
	}

	if !hasTarget {
		return body
	}

	// For single-block queries targeting the faulty block:
	// Drop on first hit, pass through on subsequent retries (so bloom recovery works).
	if len(blockSet) <= 1 {
		if hitCount.Load() > 0 {
			log.Printf("PROXY: single-block RETRY for block %d — passing through (recovery)", target)
			return body
		}
		// First single-block hit — drop it
	}

	// Strip logs from target block
	filtered := make([]map[string]any, 0, len(logs))
	dropped := 0
	for _, l := range logs {
		bn, ok := l["blockNumber"].(string)
		if !ok {
			filtered = append(filtered, l)
			continue
		}
		n, err := hexToUint64(bn)
		if err != nil || n != uint64(target) {
			filtered = append(filtered, l)
		} else {
			dropped++
		}
	}

	if dropped > 0 {
		hitCount.Add(1)
		log.Printf("PROXY: FAULT INJECTED — dropped %d logs from block %d (wide query, %d blocks, hit #%d)",
			dropped, target, len(blockSet), hitCount.Load())

		newResult, err := json.Marshal(filtered)
		if err != nil {
			return body
		}
		raw["result"] = newResult
		out, err := json.Marshal(raw)
		if err != nil {
			return body
		}
		return out
	}

	return body
}

var wsUpgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func wsProxy(upstreamWS string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Upgrade client connection
		clientConn, err := wsUpgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("WS upgrade failed: %v", err)
			return
		}
		defer clientConn.Close()

		// Connect to upstream
		upstreamConn, _, err := websocket.DefaultDialer.Dial(upstreamWS, nil)
		if err != nil {
			log.Printf("WS upstream dial failed: %v", err)
			return
		}
		defer upstreamConn.Close()

		done := make(chan struct{}, 2)

		// Client → Upstream (pass through)
		go func() {
			defer func() { done <- struct{}{} }()
			for {
				msgType, msg, err := clientConn.ReadMessage()
				if err != nil {
					return
				}
				if err := upstreamConn.WriteMessage(msgType, msg); err != nil {
					return
				}
			}
		}()

		// Upstream → Client (intercept eth_getLogs responses)
		go func() {
			defer func() { done <- struct{}{} }()
			for {
				msgType, msg, err := upstreamConn.ReadMessage()
				if err != nil {
					return
				}

				// Try to intercept any response that looks like it contains logs
				if faultyBlock.Load() >= 0 && msgType == websocket.TextMessage {
					modified := processResponse(msg)
					if !bytes.Equal(modified, msg) {
						if err := clientConn.WriteMessage(msgType, modified); err != nil {
							return
						}
						continue
					}
				}

				if err := clientConn.WriteMessage(msgType, msg); err != nil {
					return
				}
			}
		}()

		<-done
	}
}

func main() {
	upstreamHTTP := os.Getenv("UPSTREAM_HTTP")
	if upstreamHTTP == "" {
		upstreamHTTP = "http://localhost:8545"
	}
	upstreamWS := os.Getenv("UPSTREAM_WS")
	if upstreamWS == "" {
		upstreamWS = "ws://localhost:8546"
	}
	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8545"
	}

	if v := os.Getenv("FAULTY_BLOCK"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			faultyBlock.Store(n)
			log.Printf("Initial faulty block: %d", n)
		}
	}

	target, _ := url.Parse(upstreamHTTP)
	httpProxy := httputil.NewSingleHostReverseProxy(target)

	httpProxy.ModifyResponse = func(resp *http.Response) error {
		if faultyBlock.Load() < 0 {
			return nil
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return err
		}
		modified := processResponse(body)
		resp.Body = io.NopCloser(bytes.NewReader(modified))
		resp.ContentLength = int64(len(modified))
		resp.Header.Set("Content-Length", strconv.Itoa(len(modified)))
		return nil
	}

	mux := http.NewServeMux()

	// Control API
	mux.HandleFunc("/fault/set", func(w http.ResponseWriter, r *http.Request) {
		block := r.URL.Query().Get("block")
		n, err := strconv.ParseInt(block, 10, 64)
		if err != nil {
			http.Error(w, "bad block number", 400)
			return
		}
		faultyBlock.Store(n)
		hitCount.Store(0)
		log.Printf("CONTROL: fault set for block %d", n)
		fmt.Fprintf(w, `{"faulty_block": %d}`, n)
	})

	mux.HandleFunc("/fault/clear", func(w http.ResponseWriter, r *http.Request) {
		faultyBlock.Store(-1)
		log.Printf("CONTROL: fault cleared")
		fmt.Fprint(w, `{"faulty_block": null}`)
	})

	mux.HandleFunc("/fault/status", func(w http.ResponseWriter, r *http.Request) {
		b := faultyBlock.Load()
		h := hitCount.Load()
		fmt.Fprintf(w, `{"faulty_block": %d, "hit_count": %d, "active": %v}`, b, h, b >= 0)
	})

	// WS upgrade handler — intercepts WebSocket connections
	mux.HandleFunc("/ws", wsProxy(upstreamWS))
	mux.HandleFunc("/ws/", wsProxy(upstreamWS))

	// Default: HTTP RPC proxy or WS upgrade
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if websocket.IsWebSocketUpgrade(r) {
			wsProxy(upstreamWS)(w, r)
			return
		}
		httpProxy.ServeHTTP(w, r)
	})

	log.Printf("Faulty EL Proxy starting on %s", listenAddr)
	log.Printf("  HTTP RPC → %s", upstreamHTTP)
	log.Printf("  WS RPC   → %s", upstreamWS)
	log.Printf("  Control: /fault/set?block=N, /fault/clear, /fault/status")

	log.Fatal(http.ListenAndServe(listenAddr, mux))
}

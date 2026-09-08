package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fakeCL serves a minimal /eth/v1/config/spec plus one unrelated route.
func fakeCL() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/eth/v1/config/spec", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"data":{"GLOAS_FORK_EPOCH":"4","GLOAS_FORK_VERSION":"0x60000000","FULU_FORK_EPOCH":"0"}}`)
	})
	mux.HandleFunc("/eth/v1/beacon/genesis", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"data":{"genesis_time":"1700000000"}}`)
	})
	return httptest.NewServer(mux)
}

func specData(t *testing.T, srv *httptest.Server) map[string]any {
	t.Helper()
	resp, err := http.Get(srv.URL + "/eth/v1/config/spec")
	if err != nil {
		t.Fatalf("get spec: %v", err)
	}
	defer resp.Body.Close()
	var body struct {
		Data map[string]any `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode spec: %v", err)
	}
	return body.Data
}

func TestStripsNamedKeyFromSpec(t *testing.T) {
	up := fakeCL()
	defer up.Close()
	p := httptest.NewServer(newProxy(up.URL, []string{"GLOAS_FORK_EPOCH"}))
	defer p.Close()

	data := specData(t, p)
	if _, ok := data["GLOAS_FORK_EPOCH"]; ok {
		t.Fatal("GLOAS_FORK_EPOCH must be absent - a far-future value is NOT equivalent, it makes the node log the Info line and inverts TRN-04's oracle")
	}
	// Everything else must survive untouched.
	if data["FULU_FORK_EPOCH"] != "0" {
		t.Fatalf("FULU_FORK_EPOCH = %v, want 0", data["FULU_FORK_EPOCH"])
	}
	if data["GLOAS_FORK_VERSION"] != "0x60000000" {
		t.Fatalf("GLOAS_FORK_VERSION = %v, want 0x60000000", data["GLOAS_FORK_VERSION"])
	}
}

func TestOtherRoutesPassThroughUnchanged(t *testing.T) {
	up := fakeCL()
	defer up.Close()
	p := httptest.NewServer(newProxy(up.URL, []string{"GLOAS_FORK_EPOCH"}))
	defer p.Close()

	resp, err := http.Get(p.URL + "/eth/v1/beacon/genesis")
	if err != nil {
		t.Fatalf("get genesis: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), "1700000000") {
		t.Fatalf("genesis body altered: %s", b)
	}
}

func TestPassthroughRestoresTheKey(t *testing.T) {
	up := fakeCL()
	defer up.Close()
	h := newProxy(up.URL, []string{"GLOAS_FORK_EPOCH"})
	p := httptest.NewServer(h)
	defer p.Close()

	if _, ok := specData(t, p)["GLOAS_FORK_EPOCH"]; ok {
		t.Fatal("key present before passthrough")
	}

	// TRN-05: the beacon node "gets the schedule" while the SSV node keeps running and its
	// BN URL never changes.
	resp, err := http.Post(p.URL+"/_qa/passthrough", "text/plain", strings.NewReader("on"))
	if err != nil {
		t.Fatalf("post passthrough: %v", err)
	}
	resp.Body.Close()

	if _, ok := specData(t, p)["GLOAS_FORK_EPOCH"]; !ok {
		t.Fatal("GLOAS_FORK_EPOCH must reappear once passthrough is on")
	}

	resp, err = http.Post(p.URL+"/_qa/passthrough", "text/plain", strings.NewReader("off"))
	if err != nil {
		t.Fatalf("post passthrough off: %v", err)
	}
	resp.Body.Close()
	if _, ok := specData(t, p)["GLOAS_FORK_EPOCH"]; ok {
		t.Fatal("stripping must resume when passthrough is off")
	}
}

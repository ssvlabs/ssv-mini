package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// seen is what the fake beacon node received.
type seen struct {
	Method   string
	Path     string
	RawQuery string
	Body     string
	Version  string // request Eth-Consensus-Version
	CType    string
}

// fakeCL behaves like a POST-only (beacon-APIs#630) beacon node, which is what Lodestar >= v1.49.0 is:
// POST /eth/v4/validator/blocks/{slot} answers; GET on it is 404. A self-build answer includes the
// payload only when include_payload=true, signalled by Eth-Execution-Payload-Included, as Lodestar does.
type fakeCL struct {
	*httptest.Server
	mu   sync.Mutex
	reqs []seen
}

func newFakeCL(t *testing.T) *fakeCL {
	t.Helper()
	f := &fakeCL{}
	mux := http.NewServeMux()
	mux.HandleFunc("/eth/v1/config/spec", func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"data":{"GLOAS_FORK_EPOCH":"4","GLOAS_FORK_VERSION":"0x60000000","FULU_FORK_EPOCH":"0"}}`)
	})
	mux.HandleFunc("/eth/v1/beacon/genesis", func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		w.Header().Set("Eth-Consensus-Version", "fulu")
		io.WriteString(w, `{"data":{"genesis_time":"1700000000"}}`)
	})
	mux.HandleFunc("/eth/v2/beacon/blocks", func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/eth/v4/validator/blocks/", func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		if r.Method != http.MethodPost {
			http.Error(w, `{"code":404,"message":"Route GET not found"}`, http.StatusNotFound)
			return
		}
		// Lodestar v1.49.0 makes include_payload a REQUIRED query property (seen live: 400
		// "must have required property 'include_payload'").
		if !r.URL.Query().Has("include_payload") {
			http.Error(w, `{"code":400,"message":" must have required property 'include_payload'"}`, http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Eth-Consensus-Version", "gloas")
		if r.URL.Query().Get("include_payload") == "true" {
			w.Header().Set("Eth-Execution-Payload-Included", "true")
			io.WriteString(w, "BLOCK+PAYLOAD")
			return
		}
		w.Header().Set("Eth-Execution-Payload-Included", "false")
		io.WriteString(w, "BLOCK")
	})
	mux.HandleFunc("/eth/v1/events", func(w http.ResponseWriter, r *http.Request) {
		f.record(r)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "event: head\ndata: {\"slot\":\"1\"}\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done() // hold the stream open like a real subscription
	})
	f.Server = httptest.NewServer(mux)
	t.Cleanup(f.Close)
	return f
}

func (f *fakeCL) record(r *http.Request) {
	b, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reqs = append(f.reqs, seen{
		Method: r.Method, Path: r.URL.Path, RawQuery: r.URL.RawQuery, Body: string(b),
		Version: r.Header.Get("Eth-Consensus-Version"), CType: r.Header.Get("Content-Type"),
	})
}

func (f *fakeCL) last(t *testing.T) seen {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.reqs) == 0 {
		t.Fatal("upstream received nothing")
	}
	return f.reqs[len(f.reqs)-1]
}

func (f *fakeCL) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.reqs)
}

type harness struct {
	cl    *fakeCL
	p     *proxy
	srv   *httptest.Server
	stdio *syncBuffer
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newHarness(t *testing.T, strip []string) *harness {
	t.Helper()
	cl := newFakeCL(t)
	out := &syncBuffer{}
	p := newProxy(cl.URL, strip, out)
	srv := httptest.NewServer(p)
	t.Cleanup(srv.Close)
	return &harness{cl: cl, p: p, srv: srv, stdio: out}
}

// The SSV node's produce query (beacon/goclient/gloas_proposer.go gloasProduceBlockPath).
const produceQuery = "randao_reveal=0xaa&graffiti=0xbb&include_payload=true"

func (h *harness) produce(t *testing.T, method string, slot string, query string) (*http.Response, string) {
	t.Helper()
	var body io.Reader
	if method == http.MethodPost {
		body = strings.NewReader(`{"min_bid":"0","builder_boost_factor":"100","builders":[]}`)
	}
	req, _ := http.NewRequest(method, h.srv.URL+"/eth/v4/validator/blocks/"+slot+"?"+query, body)
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Eth-Consensus-Version", "gloas")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("produce: %v", err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp, string(b)
}

func (h *harness) control(t *testing.T, method, pathAndQuery string, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, h.srv.URL+pathAndQuery, strings.NewReader(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("control %s: %v", pathAndQuery, err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp.StatusCode, string(b)
}

func (h *harness) arm(t *testing.T, q string) {
	t.Helper()
	if code, body := h.control(t, http.MethodPost, "/_qa/rule?"+q, ""); code != http.StatusOK {
		t.Fatalf("arm %s: %d %s", q, code, body)
	}
}

func (h *harness) accessLog(t *testing.T) []accessEntry {
	t.Helper()
	var out []accessEntry
	for _, line := range strings.Split(h.stdio.String(), "\n") {
		if !strings.HasPrefix(line, accessLogPrefix) {
			continue
		}
		var e accessEntry
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, accessLogPrefix)), &e); err != nil {
			t.Fatalf("access log line is not JSON: %q: %v", line, err)
		}
		out = append(out, e)
	}
	return out
}

// ── no rules: everything passes through unchanged ──

func TestNoRulesProducePassesThroughUnchanged(t *testing.T) {
	h := newHarness(t, nil)
	resp, body := h.produce(t, http.MethodPost, "64", produceQuery)
	if resp.StatusCode != 200 || body != "BLOCK+PAYLOAD" {
		t.Fatalf("got %d %q, want 200 BLOCK+PAYLOAD", resp.StatusCode, body)
	}
	if v := resp.Header.Get("Eth-Consensus-Version"); v != "gloas" {
		t.Fatalf("Eth-Consensus-Version = %q, want gloas", v)
	}
	if v := resp.Header.Get("Eth-Execution-Payload-Included"); v != "true" {
		t.Fatalf("Eth-Execution-Payload-Included = %q, want true", v)
	}
	got := h.cl.last(t)
	if got.Method != "POST" || got.RawQuery != produceQuery || got.Version != "gloas" ||
		got.Body != `{"min_bid":"0","builder_boost_factor":"100","builders":[]}` {
		t.Fatalf("upstream saw %+v, want the request unchanged", got)
	}
}

func TestOtherRoutesPassThroughUnchanged(t *testing.T) {
	h := newHarness(t, []string{"GLOAS_FORK_EPOCH"})
	resp, err := http.Get(h.srv.URL + "/eth/v1/beacon/genesis?x=1&y=2")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(b), "1700000000") || resp.Header.Get("Eth-Consensus-Version") != "fulu" {
		t.Fatalf("genesis altered: %q %v", b, resp.Header)
	}
	if got := h.cl.last(t); got.RawQuery != "x=1&y=2" {
		t.Fatalf("query altered: %q", got.RawQuery)
	}
}

// ── rule (a): post-405 ──

func TestPost405RejectsPostWithoutContactingUpstream(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on")
	before := h.cl.count()
	resp, body := h.produce(t, http.MethodPost, "64", produceQuery)
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("POST produce = %d, want 405 (%s)", resp.StatusCode, body)
	}
	if h.cl.count() != before {
		t.Fatal("a 405'd POST must not reach the beacon node")
	}
}

func TestPost405TranslatesTheFallbackGetToAnUpstreamPost(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on")
	// Exactly the node's fallback: the POST query plus &builder_boost_factor=<n>.
	resp, body := h.produce(t, http.MethodGet, "64", produceQuery+"&builder_boost_factor=90")
	if resp.StatusCode != 200 || body != "BLOCK+PAYLOAD" {
		t.Fatalf("GET produce = %d %q, want 200 BLOCK+PAYLOAD (include_payload=true honoured)", resp.StatusCode, body)
	}
	got := h.cl.last(t)
	if got.Method != "POST" {
		t.Fatalf("upstream method = %s, want POST", got.Method)
	}
	if got.RawQuery != produceQuery {
		t.Fatalf("upstream query = %q, want %q (builder_boost_factor moved into the body)", got.RawQuery, produceQuery)
	}
	if got.Version != "gloas" || got.CType != "application/json" {
		t.Fatalf("upstream headers: version=%q ctype=%q", got.Version, got.CType)
	}
	var cfg map[string]any
	if err := json.Unmarshal([]byte(got.Body), &cfg); err != nil {
		t.Fatalf("upstream body not JSON: %q", got.Body)
	}
	if cfg["builder_boost_factor"] != "90" || cfg["min_bid"] != "0" {
		t.Fatalf("upstream body = %v, want neutral config with builder_boost_factor 90", cfg)
	}
	if b, ok := cfg["builders"].([]any); !ok || len(b) != 0 {
		t.Fatalf("upstream builders = %v, want []", cfg["builders"])
	}
}

func TestPost405WithoutTranslationIsACLThatServesNeitherShape(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on&translate_get=false")
	resp, _ := h.produce(t, http.MethodGet, "64", produceQuery+"&builder_boost_factor=100")
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("untranslated GET on a POST-only CL = %d, want the CL's own 404", resp.StatusCode)
	}
	if got := h.cl.last(t); got.Method != "GET" || got.RawQuery != produceQuery+"&builder_boost_factor=100" {
		t.Fatalf("untranslated GET was altered: %+v", got)
	}
}

func TestPost405LeavesNonProducePostsAlone(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on")
	resp, err := http.Post(h.srv.URL+"/eth/v2/beacon/blocks", "application/octet-stream", strings.NewReader("SIGNED"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("publish = %d, want 200", resp.StatusCode)
	}
	if got := h.cl.last(t); got.Method != "POST" || got.Body != "SIGNED" {
		t.Fatalf("publish altered: %+v", got)
	}
}

// ── rule (b): no-include-payload ──

func TestNoIncludePayloadSendsFalseAndReturnsTheBlockWithoutPayload(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=no-include-payload&state=on")
	resp, body := h.produce(t, http.MethodPost, "64", produceQuery)
	if resp.StatusCode != 200 || body != "BLOCK" || resp.Header.Get("Eth-Execution-Payload-Included") != "false" {
		t.Fatalf("got %d %q included=%q, want the bare block", resp.StatusCode, body, resp.Header.Get("Eth-Execution-Payload-Included"))
	}
	if got := h.cl.last(t); got.RawQuery != "randao_reveal=0xaa&graffiti=0xbb&include_payload=false" {
		t.Fatalf("upstream query = %q, want include_payload=false and the rest byte-identical", got.RawQuery)
	}
}

func TestNoIncludePayloadRemoveModeOmitsTheParameter(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=no-include-payload&state=on&mode=remove")
	resp, _ := h.produce(t, http.MethodPost, "64", produceQuery)
	if got := h.cl.last(t); got.RawQuery != "randao_reveal=0xaa&graffiti=0xbb" {
		t.Fatalf("upstream query = %q, want include_payload removed", got.RawQuery)
	}
	// Against a CL that requires the parameter (as Lodestar does) this is a 400, not a bare block.
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("remove mode on a CL that requires include_payload = %d, want its 400", resp.StatusCode)
	}
}

func TestNoIncludePayloadAlsoAppliesToTheTranslatedGet(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on")
	h.arm(t, "name=no-include-payload&state=on")
	_, body := h.produce(t, http.MethodGet, "64", produceQuery+"&builder_boost_factor=100")
	if body != "BLOCK" {
		t.Fatalf("got %q, want the bare block", body)
	}
	if got := h.cl.last(t); got.Method != "POST" || got.RawQuery != "randao_reveal=0xaa&graffiti=0xbb&include_payload=false" {
		t.Fatalf("upstream saw %+v", got)
	}
}

// ── rule (c): version-header ──

func TestVersionHeaderRewritesOnlyTheProduceResponse(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=version-header&state=on")
	resp, body := h.produce(t, http.MethodPost, "64", produceQuery)
	if v := resp.Header.Get("Eth-Consensus-Version"); v != "fulu" {
		t.Fatalf("Eth-Consensus-Version = %q, want fulu", v)
	}
	if body != "BLOCK+PAYLOAD" || resp.Header.Get("Eth-Execution-Payload-Included") != "true" {
		t.Fatalf("body/headers altered beyond the version: %q %v", body, resp.Header)
	}
	r2, _ := http.Get(h.srv.URL + "/eth/v1/beacon/genesis")
	r2.Body.Close()
	if v := r2.Header.Get("Eth-Consensus-Version"); v != "fulu" {
		t.Fatalf("genesis version = %q, want its own fulu untouched", v)
	}
}

func TestVersionHeaderCustomValue(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=version-header&state=on&value=electra")
	resp, _ := h.produce(t, http.MethodPost, "64", produceQuery)
	if v := resp.Header.Get("Eth-Consensus-Version"); v != "electra" {
		t.Fatalf("Eth-Consensus-Version = %q, want electra", v)
	}
}

// ── slot filter, off, reset ──

func TestSlotFilterLimitsARuleToTheNamedSlots(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=version-header&state=on&slots=65,70")
	for slot, want := range map[string]string{"64": "gloas", "65": "fulu", "70": "fulu", "71": "gloas"} {
		resp, _ := h.produce(t, http.MethodPost, slot, produceQuery)
		if v := resp.Header.Get("Eth-Consensus-Version"); v != want {
			t.Fatalf("slot %s: version = %q, want %q", slot, v, want)
		}
	}
}

func TestStateOffAndResetRestorePassThrough(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on")
	h.arm(t, "name=post-405&state=off")
	if resp, _ := h.produce(t, http.MethodPost, "64", produceQuery); resp.StatusCode != 200 {
		t.Fatalf("after state=off POST = %d, want 200", resp.StatusCode)
	}
	h.arm(t, "name=post-405&state=on")
	h.arm(t, "name=no-include-payload&state=on")
	h.arm(t, "name=version-header&state=on")
	if code, _ := h.control(t, http.MethodPost, "/_qa/reset", ""); code != 200 {
		t.Fatalf("reset = %d", code)
	}
	resp, body := h.produce(t, http.MethodPost, "64", produceQuery)
	if resp.StatusCode != 200 || body != "BLOCK+PAYLOAD" || resp.Header.Get("Eth-Consensus-Version") != "gloas" {
		t.Fatalf("after reset: %d %q %v", resp.StatusCode, body, resp.Header)
	}
}

// ── control API validation ──

func TestControlRejectsBadInput(t *testing.T) {
	h := newHarness(t, nil)
	for _, q := range []string{
		"name=nope&state=on",
		"name=post-405",
		"name=post-405&state=maybe",
		"name=post-405&state=on&slots=1,x",
		"name=post-405&state=on&value=fulu",
		"name=version-header&state=on&value=",
		"name=version-header&state=on&translate_get=true",
		"name=post-405&state=on&translate_get=yes",
		"name=post-405&state=on&mode=false",
		"name=no-include-payload&state=on&mode=drop",
	} {
		if code, _ := h.control(t, http.MethodPost, "/_qa/rule?"+q, ""); code != http.StatusBadRequest {
			t.Errorf("%s: got %d, want 400", q, code)
		}
	}
	if code, _ := h.control(t, http.MethodGet, "/_qa/rule?name=post-405&state=on", ""); code != http.StatusMethodNotAllowed {
		t.Errorf("GET /_qa/rule: got %d, want 405", code)
	}
	// A rejected request must not have changed anything.
	if resp, _ := h.produce(t, http.MethodPost, "64", produceQuery); resp.StatusCode != 200 {
		t.Fatalf("rejected control calls armed a rule: POST = %d", resp.StatusCode)
	}
	if h.cl.count() == 0 {
		t.Fatal("control paths must never be forwarded upstream, but produce must be")
	}
	for _, r := range h.cl.reqs {
		if strings.HasPrefix(r.Path, "/_qa/") {
			t.Fatalf("control path forwarded upstream: %s", r.Path)
		}
	}
}

func TestRulesEndpointReportsStateAndHits(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on&slots=64")
	h.produce(t, http.MethodPost, "64", produceQuery)
	h.produce(t, http.MethodPost, "65", produceQuery)
	_, body := h.control(t, http.MethodGet, "/_qa/rules", "")
	var st struct {
		Rules map[string]rule `json:"rules"`
	}
	if err := json.Unmarshal([]byte(body), &st); err != nil {
		t.Fatalf("rules not JSON: %s", body)
	}
	r := st.Rules["post-405"]
	if !r.On || len(r.Slots) != 1 || r.Slots[0] != 64 || r.Hits != 1 || !r.TranslateGet {
		t.Fatalf("post-405 state = %+v, want on, slots [64], hits 1, translate_get", r)
	}
}

// ── access log ──

func TestAccessLogRecordsTheFallbackSequence(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=post-405&state=on")
	h.produce(t, http.MethodPost, "64", produceQuery)
	h.produce(t, http.MethodGet, "64", produceQuery+"&builder_boost_factor=100")

	entries := h.accessLog(t)
	if len(entries) != 2 {
		t.Fatalf("got %d access entries, want 2: %+v", len(entries), entries)
	}
	post, get := entries[0], entries[1]
	if post.Method != "POST" || post.Path != "/eth/v4/validator/blocks/64" || post.Query != produceQuery ||
		post.Status != 405 || post.ReqBytes == 0 || post.RespBytes == 0 || len(post.Rules) != 1 {
		t.Fatalf("POST entry = %+v", post)
	}
	if get.Method != "GET" || get.Query != produceQuery+"&builder_boost_factor=100" || get.Status != 200 ||
		get.RespBytes != int64(len("BLOCK+PAYLOAD")) || get.UpstreamMethod != "POST" ||
		get.ConsensusVer != "gloas" || get.PayloadIncluded != "true" {
		t.Fatalf("GET entry = %+v", get)
	}

	// /_qa/log serves the same entries; produce=1 filters to the produce route.
	http.Get(h.srv.URL + "/eth/v1/beacon/genesis")
	_, body := h.control(t, http.MethodGet, "/_qa/log?produce=1", "")
	if n := strings.Count(strings.TrimSpace(body), "\n") + 1; n != 2 || strings.Contains(body, "genesis") {
		t.Fatalf("/_qa/log?produce=1 = %q, want the 2 produce entries only", body)
	}
	_, body = h.control(t, http.MethodGet, "/_qa/log?n=1", "")
	if !strings.Contains(body, "genesis") || strings.Count(strings.TrimSpace(body), "\n") != 0 {
		t.Fatalf("/_qa/log?n=1 = %q, want only the newest entry", body)
	}
}

func TestAccessLogShowsTheRewrittenVersionAndDroppedQuery(t *testing.T) {
	h := newHarness(t, nil)
	h.arm(t, "name=version-header&state=on")
	h.arm(t, "name=no-include-payload&state=on")
	h.produce(t, http.MethodPost, "64", produceQuery)
	e := h.accessLog(t)[0]
	if e.ConsensusVer != "fulu" || e.UpstreamQuery == nil || *e.UpstreamQuery != "randao_reveal=0xaa&graffiti=0xbb&include_payload=false" ||
		e.PayloadIncluded != "false" {
		t.Fatalf("entry = %+v", e)
	}
}

// ── streaming: the node's SSE subscription must still flush through the proxy ──

func TestEventStreamIsFlushedThrough(t *testing.T) {
	h := newHarness(t, nil)
	req, _ := http.NewRequest(http.MethodGet, h.srv.URL+"/eth/v1/events?topics=head", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	got := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(resp.Body).ReadString('\n')
		got <- line
	}()
	select {
	case line := <-got:
		if line != "event: head\n" {
			t.Fatalf("first SSE line = %q", line)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("SSE event not flushed while the upstream stream is still open")
	}
}

// ── spec strip (the former blind-spot proxy) ──

func specData(t *testing.T, url string) map[string]any {
	t.Helper()
	resp, err := http.Get(url + "/eth/v1/config/spec")
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
	h := newHarness(t, []string{"GLOAS_FORK_EPOCH"})
	data := specData(t, h.srv.URL)
	if _, ok := data["GLOAS_FORK_EPOCH"]; ok {
		t.Fatal("GLOAS_FORK_EPOCH must be absent - a far-future value is NOT equivalent, it makes the node log the Info line and inverts the check")
	}
	if data["FULU_FORK_EPOCH"] != "0" || data["GLOAS_FORK_VERSION"] != "0x60000000" {
		t.Fatalf("other spec keys altered: %v", data)
	}
}

func TestNoStripLeavesTheSpecAlone(t *testing.T) {
	h := newHarness(t, nil)
	if _, ok := specData(t, h.srv.URL)["GLOAS_FORK_EPOCH"]; !ok {
		t.Fatal("a cl-proxy with no STRIP must not rewrite the spec")
	}
}

func TestPassthroughRestoresTheKey(t *testing.T) {
	h := newHarness(t, []string{"GLOAS_FORK_EPOCH"})
	if _, ok := specData(t, h.srv.URL)["GLOAS_FORK_EPOCH"]; ok {
		t.Fatal("key present before passthrough")
	}
	// Late beacon-node upgrade: the BN "gets the schedule" while the SSV node keeps running.
	h.control(t, http.MethodPost, "/_qa/passthrough", "on")
	if _, ok := specData(t, h.srv.URL)["GLOAS_FORK_EPOCH"]; !ok {
		t.Fatal("GLOAS_FORK_EPOCH must reappear once passthrough is on")
	}
	h.control(t, http.MethodPost, "/_qa/passthrough", "off")
	if _, ok := specData(t, h.srv.URL)["GLOAS_FORK_EPOCH"]; ok {
		t.Fatal("stripping must resume when passthrough is off")
	}
}

func TestRemoveQueryParamKeepsOrder(t *testing.T) {
	for _, tc := range []struct{ in, name, want, val string }{
		{"a=1&include_payload=true&b=2", "include_payload", "a=1&b=2", "true"},
		{"include_payload=true", "include_payload", "", "true"},
		{"a=1&b=2", "include_payload", "a=1&b=2", ""},
		{"a=1&builder_boost_factor=90", "builder_boost_factor", "a=1", "90"},
	} {
		got, val, _ := removeQueryParam(tc.in, tc.name)
		if got != tc.want || val != tc.val {
			t.Errorf("removeQueryParam(%q,%q) = %q,%q want %q,%q", tc.in, tc.name, got, val, tc.want, tc.val)
		}
	}
}

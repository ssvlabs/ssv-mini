// cl-proxy: a rule-driven reverse proxy in front of ONE beacon node. Every request passes through
// unchanged unless a rule matches it, and every request is written to an access log.
//
// It generalises the old blind-spot proxy (blindspot_pairs). That proxy did one thing: delete named
// keys from GET /eth/v1/config/spec. That is now the "spec strip", configured at start-up by STRIP and
// paused at runtime by /_qa/passthrough, exactly as before. On top of it, rules that are armed at
// RUNTIME rewrite the Gloas produce call (produceBlockV4), so a test can switch a version skew on and
// off while the SSV node keeps running and its beacon-node URL never changes.
//
// Produce rules (match /eth/v4/validator/blocks/{slot} only; optional per-rule slot filter):
//
//	post-405              POST -> 405 without contacting the beacon node, so the SSV node falls back to
//	                      GET (beacon-APIs#580). With translate_get=true (the default) the proxy then
//	                      serves that GET by forwarding it upstream as the #630 POST with a neutral
//	                      BuilderConfig body that carries the GET's builder_boost_factor. That emulates a
//	                      GET-only CL on top of a POST-only CL (Lodestar >= v1.49.0 has no GET route).
//	                      translate_get=false forwards the GET untouched: on a POST-only CL that is a CL
//	                      that serves neither shape.
//	no-include-payload    the CL does not get include_payload=true, POST or GET. mode=false (default)
//	                      sends include_payload=false; mode=remove deletes the parameter. Either way a
//	                      self-building CL returns the bare block without its payload. Lodestar v1.49.0
//	                      treats the parameter as REQUIRED and answers mode=remove with 400, so use the
//	                      default there; mode=remove is for a CL that defaults it.
//	version-header        rewrite the Eth-Consensus-Version header of a 2xx produce response to `value`
//	                      (default "fulu"). The body is unchanged.
//
// Control API (on the proxy's own port, never forwarded):
//
//	GET  /_qa/rules                                         current rules, spec strip, passthrough
//	POST /_qa/rule?name=<rule>&state=on|off[&slots=a,b][&value=v][&translate_get=true|false][&mode=false|remove]
//	POST /_qa/reset                                         every produce rule off (spec strip kept)
//	POST /_qa/passthrough  (body "on"|"off")                pause/resume the spec strip
//	GET  /_qa/log[?n=200][&produce=1]                       recent access-log entries, JSONL
//
// Access log: one JSON object per request on stdout, prefixed "cl-proxy-access " so it can be grepped
// out of `docker logs`, and kept in an in-memory ring served by /_qa/log.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	specPath = "/eth/v1/config/spec"

	rulePost405          = "post-405"
	ruleNoIncludePayload = "no-include-payload"
	ruleVersionHeader    = "version-header"

	headerConsensusVersion = "Eth-Consensus-Version"
	headerPayloadIncluded  = "Eth-Execution-Payload-Included"

	accessLogPrefix = "cl-proxy-access "
	ringSize        = 5000
)

var producePath = regexp.MustCompile(`^/eth/v4/validator/blocks/([0-9]+)$`)

var ruleNames = []string{rulePost405, ruleNoIncludePayload, ruleVersionHeader}

// rule is the runtime state of one produce rule. Slots empty means every produce slot.
type rule struct {
	On           bool     `json:"on"`
	Slots        []uint64 `json:"slots,omitempty"`
	Value        string   `json:"value,omitempty"`         // version-header only
	Mode         string   `json:"mode,omitempty"`          // no-include-payload only: false | remove
	TranslateGet bool     `json:"translate_get,omitempty"` // post-405 only
	Hits         uint64   `json:"hits"`
}

func (r *rule) matches(slot uint64) bool {
	if !r.On {
		return false
	}
	if len(r.Slots) == 0 {
		return true
	}
	for _, s := range r.Slots {
		if s == slot {
			return true
		}
	}
	return false
}

// accessEntry is one access-log line. Query is the query the CLIENT sent; UpstreamQuery and
// UpstreamMethod are set only when a rule changed what went to the beacon node.
type accessEntry struct {
	Time            string   `json:"time"`
	Method          string   `json:"method"`
	Path            string   `json:"path"`
	Query           string   `json:"query"`
	Status          int      `json:"status"`
	ReqBytes        int64    `json:"req_bytes"`
	RespBytes       int64    `json:"resp_bytes"`
	DurationMs      int64    `json:"dur_ms"`
	Rules           []string `json:"rules,omitempty"`
	UpstreamMethod  string   `json:"upstream_method,omitempty"`
	UpstreamQuery   *string  `json:"upstream_query,omitempty"`
	ConsensusVer    string   `json:"consensus_version,omitempty"`
	PayloadIncluded string   `json:"payload_included,omitempty"`
}

// reqActions is what the request side decided, read back by ModifyResponse.
type reqActions struct {
	rewriteVersion string
	stripSpec      bool
}

type ctxKey struct{}

type proxy struct {
	rp    *httputil.ReverseProxy
	strip []string
	out   io.Writer

	mu          sync.Mutex
	rules       map[string]*rule
	passthrough bool
	ring        []accessEntry
	ringNext    int
	ringFull    bool
}

func newProxy(upstream string, strip []string, accessOut io.Writer) *proxy {
	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("bad UPSTREAM %q: %v", upstream, err)
	}
	p := &proxy{
		strip: strip,
		out:   accessOut,
		rules: map[string]*rule{},
		ring:  make([]accessEntry, ringSize),
	}
	p.resetRules()

	rp := httputil.NewSingleHostReverseProxy(target)
	inner := rp.Director
	rp.Director = func(req *http.Request) {
		inner(req)
		if a, _ := req.Context().Value(ctxKey{}).(*reqActions); a != nil && a.stripSpec {
			// Identity encoding so ModifyResponse can decode the spec JSON without handling gzip.
			req.Header.Del("Accept-Encoding")
		}
	}
	rp.ModifyResponse = p.modifyResponse
	p.rp = rp
	return p
}

func (p *proxy) resetRules() {
	p.rules[rulePost405] = &rule{TranslateGet: true}
	p.rules[ruleNoIncludePayload] = &rule{Mode: "false"}
	p.rules[ruleVersionHeader] = &rule{Value: "fulu"}
}

func (p *proxy) modifyResponse(resp *http.Response) error {
	a, _ := resp.Request.Context().Value(ctxKey{}).(*reqActions)
	if a == nil {
		return nil
	}
	if a.rewriteVersion != "" && resp.StatusCode/100 == 2 {
		resp.Header.Set(headerConsensusVersion, a.rewriteVersion)
	}
	if a.stripSpec && resp.StatusCode == http.StatusOK {
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return err
		}
		rewritten, err := p.stripKeys(body)
		if err != nil {
			// Never fail the request on a shape we did not expect - pass the original through and
			// say so, so a malformed spec is diagnosable rather than fatal.
			log.Printf("spec rewrite skipped: %v", err)
			rewritten = body
		}
		resp.Body = io.NopCloser(bytes.NewReader(rewritten))
		resp.ContentLength = int64(len(rewritten))
		resp.Header.Set("Content-Length", strconv.Itoa(len(rewritten)))
		resp.Header.Del("Content-Encoding")
	}
	return nil
}

// stripKeys removes the configured keys from the spec's "data" object.
//
// The keys must be DELETED, never rewritten to a far-future value. The SSV node reads
// GLOAS_FORK_EPOCH via getForkEpoch(..., required=false), which returns FarFutureEpoch only when the
// key is missing. A far-future value makes it log the INFO "Gloas (ePBS) fork scheduled" line instead,
// which inverts a blind-spot check that watches for that line to be missing.
func (p *proxy) stripKeys(body []byte) ([]byte, error) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, err
	}
	raw, ok := envelope["data"]
	if !ok {
		return nil, fmt.Errorf("spec response has no \"data\" object")
	}
	var data map[string]json.RawMessage
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, err
	}
	removed := []string{}
	for _, k := range p.strip {
		if _, present := data[k]; present {
			delete(data, k)
			removed = append(removed, k)
		}
	}
	patched, err := json.Marshal(data)
	if err != nil {
		return nil, err
	}
	envelope["data"] = patched
	out, err := json.Marshal(envelope)
	if err != nil {
		return nil, err
	}
	log.Printf("spec rewritten: removed %v", removed)
	return out, nil
}

// removeQueryParam deletes every `name=...` (or bare `name`) from a raw query and keeps the rest
// byte-for-byte in its original order. url.Values would re-encode and re-sort the whole query.
func removeQueryParam(rawQuery, name string) (string, string, bool) {
	if rawQuery == "" {
		return "", "", false
	}
	parts := strings.Split(rawQuery, "&")
	kept := parts[:0:0]
	value, found := "", false
	for _, part := range parts {
		k, v, _ := strings.Cut(part, "=")
		if k == name {
			value, found = v, true
			continue
		}
		kept = append(kept, part)
	}
	return strings.Join(kept, "&"), value, found
}

// neutralBuilderConfig is the beacon-APIs#630 BuilderConfig body the proxy sends upstream when it
// translates a fallback GET: no builders, no min bid, and the GET's builder_boost_factor. This is the
// same shape as the SSV node's own gloas.NeutralProduceBuilderConfig().
func neutralBuilderConfig(boost string) []byte {
	if boost == "" {
		boost = "100"
	}
	b, _ := json.Marshal(map[string]any{
		"min_bid":              "0",
		"builder_boost_factor": boost,
		"builders":             []any{},
	})
	return b
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/_qa/") {
		p.serveControl(w, r)
		return
	}

	start := time.Now()
	entry := accessEntry{
		Time:   start.UTC().Format(time.RFC3339Nano),
		Method: r.Method,
		Path:   r.URL.Path,
		Query:  r.URL.RawQuery,
	}
	// req_bytes is what the client sent: bytes read on the way upstream, or the declared length when a
	// rule answered without reading the body (post-405).
	declaredLen := r.ContentLength
	var reqBody *countingReader
	if r.Body != nil && r.Body != http.NoBody {
		reqBody = &countingReader{r: r.Body}
		r.Body = reqBody
	}
	rec := &recorder{ResponseWriter: w, status: http.StatusOK}

	actions := &reqActions{}
	p.mu.Lock()
	actions.stripSpec = r.URL.Path == specPath && len(p.strip) > 0 && !p.passthrough
	var post405, noInclude, version *rule
	if m := producePath.FindStringSubmatch(r.URL.Path); m != nil {
		slot, _ := strconv.ParseUint(m[1], 10, 64)
		if rl := p.rules[rulePost405]; rl.matches(slot) {
			c := *rl
			post405 = &c
			rl.Hits++
		}
		if rl := p.rules[ruleNoIncludePayload]; rl.matches(slot) {
			c := *rl
			noInclude = &c
			rl.Hits++
		}
		if rl := p.rules[ruleVersionHeader]; rl.matches(slot) {
			c := *rl
			version = &c
			rl.Hits++
		}
	}
	p.mu.Unlock()

	defer func() {
		entry.Status = rec.status
		entry.RespBytes = rec.bytes
		if reqBody != nil {
			entry.ReqBytes = reqBody.n
		}
		if entry.ReqBytes == 0 && declaredLen > 0 {
			entry.ReqBytes = declaredLen
		}
		entry.DurationMs = time.Since(start).Milliseconds()
		entry.ConsensusVer = rec.Header().Get(headerConsensusVersion)
		entry.PayloadIncluded = rec.Header().Get(headerPayloadIncluded)
		p.logAccess(entry)
	}()

	if post405 != nil {
		entry.Rules = append(entry.Rules, rulePost405)
		switch r.Method {
		case http.MethodPost:
			rec.Header().Set("Content-Type", "application/json")
			rec.WriteHeader(http.StatusMethodNotAllowed)
			io.WriteString(rec, `{"code":405,"message":"cl-proxy rule post-405: produceBlockV4 POST disabled; use GET"}`)
			return
		case http.MethodGet:
			if post405.TranslateGet {
				q, boost, _ := removeQueryParam(r.URL.RawQuery, "builder_boost_factor")
				body := neutralBuilderConfig(boost)
				r.Method = http.MethodPost
				r.URL.RawQuery = q
				r.Body = io.NopCloser(bytes.NewReader(body))
				r.ContentLength = int64(len(body))
				r.Header.Set("Content-Type", "application/json")
				r.Header.Set("Content-Length", strconv.Itoa(len(body)))
				// Lodestar requires the request's Eth-Consensus-Version on the POST; v4 produce is Gloas-only.
				r.Header.Set(headerConsensusVersion, "gloas")
				entry.UpstreamMethod = http.MethodPost
				entry.UpstreamQuery = &q
			}
		}
	}
	if noInclude != nil {
		q, _, _ := removeQueryParam(r.URL.RawQuery, "include_payload")
		if noInclude.Mode == "false" {
			if q == "" {
				q = "include_payload=false"
			} else {
				q += "&include_payload=false"
			}
		}
		entry.Rules = append(entry.Rules, ruleNoIncludePayload+"="+noInclude.Mode)
		r.URL.RawQuery = q
		entry.UpstreamQuery = &q
	}
	if version != nil {
		actions.rewriteVersion = version.Value
		entry.Rules = append(entry.Rules, ruleVersionHeader+"="+version.Value)
	}

	p.rp.ServeHTTP(rec, r.WithContext(context.WithValue(r.Context(), ctxKey{}, actions)))
}

func (p *proxy) logAccess(e accessEntry) {
	b, _ := json.Marshal(e)
	p.mu.Lock()
	p.ring[p.ringNext] = e
	p.ringNext = (p.ringNext + 1) % ringSize
	if p.ringNext == 0 {
		p.ringFull = true
	}
	p.mu.Unlock()
	fmt.Fprintf(p.out, "%s%s\n", accessLogPrefix, b)
}

// recent returns up to n entries, oldest first.
func (p *proxy) recent(n int, produceOnly bool) []accessEntry {
	p.mu.Lock()
	defer p.mu.Unlock()
	var all []accessEntry
	if p.ringFull {
		all = append(all, p.ring[p.ringNext:]...)
	}
	all = append(all, p.ring[:p.ringNext]...)
	if produceOnly {
		filtered := all[:0:0]
		for _, e := range all {
			if producePath.MatchString(e.Path) {
				filtered = append(filtered, e)
			}
		}
		all = filtered
	}
	if n > 0 && len(all) > n {
		all = all[len(all)-n:]
	}
	return all
}

func (p *proxy) serveControl(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/_qa/rules":
		p.writeState(w)
	case "/_qa/rule":
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		if err := p.setRule(r.URL.Query()); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		p.writeState(w)
	case "/_qa/reset":
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		p.mu.Lock()
		p.resetRules()
		p.mu.Unlock()
		log.Printf("rules reset: every produce rule off")
		p.writeState(w)
	case "/_qa/passthrough":
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(r.Body)
		on := strings.TrimSpace(string(body)) == "on"
		p.mu.Lock()
		p.passthrough = on
		p.mu.Unlock()
		log.Printf("passthrough set to %v", on)
		if on {
			io.WriteString(w, "passthrough=on\n")
		} else {
			io.WriteString(w, "passthrough=off\n")
		}
	case "/_qa/log":
		n := 200
		if s := r.URL.Query().Get("n"); s != "" {
			v, err := strconv.Atoi(s)
			if err != nil || v < 0 {
				http.Error(w, "n must be a non-negative integer", http.StatusBadRequest)
				return
			}
			n = v
		}
		produceOnly := r.URL.Query().Get("produce") == "1"
		w.Header().Set("Content-Type", "application/x-ndjson")
		enc := json.NewEncoder(w)
		for _, e := range p.recent(n, produceOnly) {
			enc.Encode(e)
		}
	default:
		http.Error(w, "unknown control path; see /_qa/rules, /_qa/rule, /_qa/reset, /_qa/passthrough, /_qa/log", http.StatusNotFound)
	}
}

func (p *proxy) setRule(q url.Values) error {
	name := q.Get("name")
	known := false
	for _, n := range ruleNames {
		if n == name {
			known = true
		}
	}
	if !known {
		return fmt.Errorf("unknown rule %q; known: %s", name, strings.Join(ruleNames, ", "))
	}
	var on bool
	switch q.Get("state") {
	case "on":
		on = true
	case "off":
		on = false
	default:
		return fmt.Errorf("state must be on or off, got %q", q.Get("state"))
	}
	var slots []uint64
	if s := q.Get("slots"); s != "" {
		for _, part := range strings.Split(s, ",") {
			v, err := strconv.ParseUint(strings.TrimSpace(part), 10, 64)
			if err != nil {
				return fmt.Errorf("slots must be comma-separated slot numbers, got %q", s)
			}
			slots = append(slots, v)
		}
		sort.Slice(slots, func(i, j int) bool { return slots[i] < slots[j] })
	}
	value, hasValue := q.Get("value"), q.Has("value")
	if hasValue && name != ruleVersionHeader {
		return fmt.Errorf("value applies to %s only", ruleVersionHeader)
	}
	if hasValue && value == "" {
		return fmt.Errorf("value must not be empty")
	}
	mode, hasMode := q.Get("mode"), q.Has("mode")
	if hasMode && name != ruleNoIncludePayload {
		return fmt.Errorf("mode applies to %s only", ruleNoIncludePayload)
	}
	if hasMode && mode != "false" && mode != "remove" {
		return fmt.Errorf("mode must be false or remove, got %q", mode)
	}
	tg, hasTG := q.Get("translate_get"), q.Has("translate_get")
	if hasTG && name != rulePost405 {
		return fmt.Errorf("translate_get applies to %s only", rulePost405)
	}
	if hasTG && tg != "true" && tg != "false" {
		return fmt.Errorf("translate_get must be true or false, got %q", tg)
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	rl := p.rules[name]
	rl.On = on
	rl.Slots = slots
	if hasValue {
		rl.Value = value
	}
	if hasTG {
		rl.TranslateGet = tg == "true"
	}
	if hasMode {
		rl.Mode = mode
	}
	log.Printf("rule %s set: on=%v slots=%v value=%q translate_get=%v mode=%q", name, rl.On, rl.Slots, rl.Value, rl.TranslateGet, rl.Mode)
	return nil
}

func (p *proxy) writeState(w http.ResponseWriter) {
	p.mu.Lock()
	state := map[string]any{
		"rules":       p.rules,
		"spec_strip":  p.strip,
		"passthrough": p.passthrough,
	}
	b, _ := json.MarshalIndent(state, "", "  ")
	p.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Write(append(b, '\n'))
}

type countingReader struct {
	r io.ReadCloser
	n int64
}

func (c *countingReader) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.n += int64(n)
	return n, err
}

func (c *countingReader) Close() error { return c.r.Close() }

// recorder captures status and body size. It keeps Flush and Unwrap so httputil.ReverseProxy can still
// flush a streaming response (the node's /eth/v1/events SSE subscription).
type recorder struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (r *recorder) WriteHeader(code int) {
	if !r.wroteHeader {
		r.status = code
		r.wroteHeader = true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.wroteHeader = true
	n, err := r.ResponseWriter.Write(b)
	r.bytes += int64(n)
	return n, err
}

func (r *recorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func main() {
	upstream := os.Getenv("UPSTREAM")
	if upstream == "" {
		log.Fatal("UPSTREAM is required, e.g. http://cl-1-lodestar-geth:4000")
	}
	// STRIP names the spec keys to delete. Unset or empty means no spec rewrite (a plain cl-proxy);
	// blindspot_pairs always sets it.
	var strip []string
	if s := os.Getenv("STRIP"); s != "" {
		for _, k := range strings.Split(s, ",") {
			if k = strings.TrimSpace(k); k != "" {
				strip = append(strip, k)
			}
		}
	}
	port := os.Getenv("LISTEN_PORT")
	if port == "" {
		port = "4000"
	}
	log.Printf("cl-proxy: upstream=%s strip=%v listen=:%s", upstream, strip, port)
	if err := http.ListenAndServe(":"+port, newProxy(upstream, strip, os.Stdout)); err != nil {
		log.Fatal(err)
	}
}

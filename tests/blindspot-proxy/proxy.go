// Blind-spot proxy: a transparent reverse proxy in front of a beacon node that removes
// named keys from GET /eth/v1/config/spec.
//
// Why this exists: ethereum-package's gloas_fork_epoch is a single GLOBAL network_params
// field, validated network-wide, so a per-participant fork schedule cannot be expressed.
// The SSV node reads the fork epoch from the beacon node's own /config/spec via
// getForkEpoch("GLOAS_FORK_EPOCH", required=false) (beacon/goclient/spec.go:255), and that
// helper returns FarFutureEpoch ONLY when the key is missing from the map.
//
// So the key must be DELETED, never rewritten to a far-future value. With the key absent the
// node logs Debug "Gloas (ePBS) fork not scheduled by the beacon node" and GloasForkEpoch()
// reports ok=false, which is gap G2 and TRN-04's oracle. With GLOAS_FORK_EPOCH set to, say,
// 1000000000 the node instead logs INFO "Gloas (ePBS) fork scheduled", requires
// GLOAS_FORK_VERSION or errors the whole spec fetch, and populates Forks[DataVersionGloas] -
// a node that believes Gloas exists. That inverts the oracle: the P0.7 alert watches for the
// MISSING Info line, so it would not fire and the card would pass having tested nothing.
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
)

const specPath = "/eth/v1/config/spec"

type proxy struct {
	rp          *httputil.ReverseProxy
	strip       []string
	passthrough atomic.Bool
}

func newProxy(upstream string, strip []string) *proxy {
	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("bad UPSTREAM %q: %v", upstream, err)
	}
	p := &proxy{strip: strip}
	rp := httputil.NewSingleHostReverseProxy(target)

	inner := rp.Director
	rp.Director = func(req *http.Request) {
		inner(req)
		// Ask for identity encoding so ModifyResponse can decode JSON without having to
		// handle gzip. Beacon nodes will happily gzip a spec response otherwise.
		req.Header.Del("Accept-Encoding")
	}

	rp.ModifyResponse = func(resp *http.Response) error {
		if resp.Request.URL.Path != specPath || p.passthrough.Load() {
			return nil
		}
		if resp.StatusCode != http.StatusOK {
			return nil
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return err
		}
		rewritten, err := p.stripKeys(body)
		if err != nil {
			// Never fail the request on a shape we did not expect - pass the original
			// through and say so, so a malformed spec is diagnosable rather than fatal.
			log.Printf("spec rewrite skipped: %v", err)
			rewritten = body
		}
		resp.Body = io.NopCloser(bytes.NewReader(rewritten))
		resp.ContentLength = int64(len(rewritten))
		resp.Header.Set("Content-Length", strconv.Itoa(len(rewritten)))
		resp.Header.Del("Content-Encoding")
		return nil
	}

	p.rp = rp
	return p
}

// stripKeys removes the configured keys from the spec's "data" object, leaving every other
// field byte-for-byte as the upstream sent it apart from JSON re-encoding.
func (p *proxy) stripKeys(body []byte) ([]byte, error) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, err
	}
	raw, ok := envelope["data"]
	if !ok {
		return nil, errNoData
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

type stripError string

func (e stripError) Error() string { return string(e) }

const errNoData = stripError("spec response has no \"data\" object")

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/_qa/passthrough" {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(r.Body)
		on := strings.TrimSpace(string(body)) == "on"
		p.passthrough.Store(on)
		log.Printf("passthrough set to %v", on)
		io.WriteString(w, "passthrough=")
		if on {
			io.WriteString(w, "on\n")
		} else {
			io.WriteString(w, "off\n")
		}
		return
	}
	p.rp.ServeHTTP(w, r)
}

func main() {
	upstream := os.Getenv("UPSTREAM")
	if upstream == "" {
		log.Fatal("UPSTREAM is required, e.g. http://cl-4-lodestar-geth:4000")
	}
	strip := []string{"GLOAS_FORK_EPOCH"}
	if s := os.Getenv("STRIP"); s != "" {
		strip = strings.Split(s, ",")
		for i := range strip {
			strip[i] = strings.TrimSpace(strip[i])
		}
	}
	port := os.Getenv("LISTEN_PORT")
	if port == "" {
		port = "4000"
	}
	log.Printf("blindspot-proxy: upstream=%s strip=%v listen=:%s", upstream, strip, port)
	if err := http.ListenAndServe(":"+port, newProxy(upstream, strip)); err != nil {
		log.Fatal(err)
	}
}

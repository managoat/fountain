// Package api is a thin HTTP client for the Fountain API.
//
// All requests are prefixed with /api and carry a Bearer token resolved
// from FountainCli config (env vars, then ~/.fountain/credentials).
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/managoat/fountain/cli/config"
	"github.com/managoat/fountain/cli/credentials"
)

// HTTPError carries the status code and decoded body for non-2xx responses.
type HTTPError struct {
	Status int
	Body   any // map/array/string depending on parse
}

func (e *HTTPError) Error() string {
	if e.Body == nil {
		return fmt.Sprintf("http %d", e.Status)
	}
	// The server writes genuinely actionable messages ("You have 3 of 3
	// concurrent sandboxes in use. ..."); a raw Go map dump buries them.
	// Prefer message, then error, and flatten nested validation errors.
	if body, ok := e.Body.(map[string]any); ok {
		var b strings.Builder
		fmt.Fprintf(&b, "http %d", e.Status)
		switch {
		case toString(body["message"]) != "":
			fmt.Fprintf(&b, ": %s", toString(body["message"]))
		case toString(body["error"]) != "":
			fmt.Fprintf(&b, ": %s", toString(body["error"]))
		}
		if errs, ok := body["errors"].(map[string]any); ok && len(errs) > 0 {
			fmt.Fprintf(&b, ": %s", flattenErrors(errs))
		}
		if s := b.String(); s != fmt.Sprintf("http %d", e.Status) {
			return s
		}
	}
	return fmt.Sprintf("http %d: %v", e.Status, e.Body)
}

func toString(v any) string {
	s, _ := v.(string)
	return s
}

// flattenErrors renders the nested field → messages shape Ecto's
// traverse_errors produces: {"name": ["can't be blank"]} → `name: can't be
// blank`, recursing into nested maps with dotted paths.
func flattenErrors(errs map[string]any) string {
	keys := make([]string, 0, len(errs))
	for k := range errs {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		switch v := errs[k].(type) {
		case []any:
			msgs := make([]string, 0, len(v))
			for _, m := range v {
				msgs = append(msgs, fmt.Sprintf("%v", m))
			}
			parts = append(parts, fmt.Sprintf("%s: %s", k, strings.Join(msgs, ", ")))
		case map[string]any:
			for _, nested := range strings.Split(flattenErrors(v), "; ") {
				parts = append(parts, fmt.Sprintf("%s.%s", k, nested))
			}
		default:
			parts = append(parts, fmt.Sprintf("%s: %v", k, v))
		}
	}
	return strings.Join(parts, "; ")
}

// Client wraps the HTTP client and credential resolution.
type Client struct {
	HTTP *http.Client
	Opts credentials.Opts
}

// New returns a Client bound to the active profile.
func New(opts credentials.Opts) *Client {
	return &Client{
		HTTP: &http.Client{Timeout: 60 * time.Second},
		Opts: opts,
	}
}

// BaseURL returns the resolved base URL (no trailing slash).
func (c *Client) BaseURL() string { return config.BaseURL(c.Opts) }

// Token returns the API token, or an error if unconfigured.
func (c *Client) Token() (string, error) { return config.APIKey(c.Opts) }

// Get performs GET /api<path> and decodes JSON into out (may be nil to discard).
func (c *Client) Get(path string, out any) error {
	return c.do(http.MethodGet, path, nil, out)
}

// Post performs POST /api<path> with a JSON body.
func (c *Client) Post(path string, body, out any) error {
	return c.do(http.MethodPost, path, body, out)
}

// Put performs PUT /api<path> with a JSON body.
func (c *Client) Put(path string, body, out any) error {
	return c.do(http.MethodPut, path, body, out)
}

// Patch performs PATCH /api<path> with a JSON body.
func (c *Client) Patch(path string, body, out any) error {
	return c.do(http.MethodPatch, path, body, out)
}

// Delete performs DELETE /api<path>.
func (c *Client) Delete(path string, out any) error {
	return c.do(http.MethodDelete, path, nil, out)
}

func (c *Client) do(method, path string, body, out any) error {
	token, err := c.Token()
	if err != nil {
		return err
	}
	url := c.BaseURL() + "/api" + path

	var rdr io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(buf)
	}

	req, err := http.NewRequestWithContext(context.Background(), method, url, rdr)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var decoded any
		if len(respBody) > 0 {
			if json.Unmarshal(respBody, &decoded) != nil {
				decoded = string(respBody)
			}
		}
		return &HTTPError{Status: resp.StatusCode, Body: decoded}
	}

	if out == nil || len(respBody) == 0 {
		return nil
	}
	return json.Unmarshal(respBody, out)
}

// NewStreamRequest returns an *http.Request for an SSE endpoint.
// The caller is responsible for executing it and parsing the body.
func (c *Client) NewStreamRequest(ctx context.Context, path, lastEventID string) (*http.Request, error) {
	token, err := c.Token()
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL()+"/api"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "text/event-stream")
	if lastEventID != "" {
		req.Header.Set("Last-Event-ID", lastEventID)
	}
	return req, nil
}

// StatusCode extracts the status code from an error if it is an HTTPError.
func StatusCode(err error) int {
	if he, ok := err.(*HTTPError); ok {
		return he.Status
	}
	return 0
}

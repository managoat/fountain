// managoat-layer is an internal provisioning helper, not a user-facing CLI.
// One bounded JSON request arrives on stdin, so keys and signed URLs never
// appear in argv or inherited environment variables. Stdout is machine output.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"filippo.io/age"
	"github.com/managoat/managoat/cli/internal/layers"
)

type request struct {
	CleanupFile string         `json:"cleanup_file"`
	Operation   string         `json:"operation"`
	Baseline    string         `json:"baseline"`
	Input       string         `json:"input"`
	Output      string         `json:"output"`
	Recipient   string         `json:"recipient"`
	Identity    string         `json:"identity"`
	SHA256      string         `json:"sha256"`
	URL         string         `json:"url"`
	Origin      string         `json:"origin"`
	Binding     layers.Binding `json:"binding"`
	Limits      *layers.Limits `json:"limits,omitempty"`
}
type response struct {
	OK        bool           `json:"ok"`
	Result    *layers.Result `json:"result,omitempty"`
	Identity  string         `json:"identity,omitempty"`
	Recipient string         `json:"recipient,omitempty"`
	Error     string         `json:"error,omitempty"`
	Dirty     bool           `json:"dirty"`
}

func run(ctx context.Context, input io.Reader, output io.Writer) (exitCode int) {
	// Read at most 64 KiB plus one, including trailing input, before doing work.
	data, err := io.ReadAll(io.LimitReader(input, (64<<10)+1))
	if err != nil || len(data) > 64<<10 {
		return emit(output, response{Error: "invalid_request"})
	}
	if !uniqueJSON(json.NewDecoder(bytes.NewReader(data)), 0) {
		return emit(output, response{Error: "invalid_request"})
	}
	var req request
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&req) != nil {
		return emit(output, response{Error: "invalid_request"})
	}
	if req.CleanupFile != "" {
		if !strings.HasPrefix(req.CleanupFile, "/tmp/managoat-layer-request-") || strings.Contains(strings.TrimPrefix(req.CleanupFile, "/tmp/"), "/") {
			return emit(output, response{Error: "invalid_request"})
		}
		defer func() {
			if err := os.Remove(req.CleanupFile); err != nil && !os.IsNotExist(err) {
				exitCode = 1
			}
		}()
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return emit(output, response{Error: "invalid_request"})
	}
	limits := layers.DefaultLimits()
	if req.Limits != nil {
		limits = *req.Limits
	}
	var result layers.Result
	switch req.Operation {
	case "keygen":
		// Controller-only operation. The private identity is the artifact-specific
		// envelope payload, never a tenant key. Do not log this response.
		id, e := age.GenerateX25519Identity()
		if e != nil {
			return emit(output, response{Error: "key_generation_failed"})
		}
		return emit(output, response{OK: true, Identity: id.String(), Recipient: id.Recipient().String()})
	case "process_snapshot":
		result, err = layers.ProcessSnapshot(req.Output)
	case "quiescent":
		result, err = layers.Quiescent(req.Input, req.SHA256)
	case "snapshot":
		result, err = layers.Snapshot(ctx, req.Input, req.Output, limits)
	case "export":
		result, err = layers.Export(ctx, req.Input, req.Baseline, req.Output, req.SHA256, limits)
	case "upload":
		result, err = layers.Upload(ctx, req.URL, req.Origin, req.Input, req.SHA256, limits)
	case "seal":
		result, err = layers.Seal(ctx, req.Input, req.Output, req.Recipient, req.Binding, limits)
	case "fetch":
		// A fetch request must not carry any decryption material during the wide floor.
		if req.Identity != "" || req.Recipient != "" {
			return emit(output, response{Error: "invalid_request"})
		}
		result, err = layers.Fetch(ctx, req.URL, req.Origin, req.Output, limits)
	case "restore":
		result, err = layers.Restore(ctx, req.Input, req.Output, req.Identity, req.SHA256, req.Binding, limits)
		if err == nil && req.CleanupFile != "" {
			err = os.Remove(req.Input)
		}
	default:
		return emit(output, response{Error: "invalid_request"})
	}
	if err != nil {
		code := "operation_failed"
		for _, known := range []struct {
			err  error
			code string
		}{{layers.ErrInvalid, "invalid_layer"}, {layers.ErrLimit, "limit_exceeded"}, {layers.ErrBinding, "incompatible_layer"}, {layers.ErrAuthentication, "authentication_failed"}, {layers.ErrArchive, "unsafe_archive"}, {layers.ErrTransfer, "transfer_failed"}, {context.Canceled, "canceled"}, {context.DeadlineExceeded, "timeout"}} {
			if errors.Is(err, known.err) {
				code = known.code
				break
			}
		}
		var restore *layers.RestoreError
		dirty := errors.As(err, &restore) && restore.Dirty
		return emit(output, response{Error: code, Dirty: dirty})
	}
	return emit(output, response{OK: true, Result: &result})
}
func emit(w io.Writer, r response) int {
	if json.NewEncoder(w).Encode(r) != nil {
		return 1
	}
	if !r.OK {
		return 1
	}
	return 0
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	os.Exit(run(ctx, os.Stdin, os.Stdout))
}

// encoding/json accepts duplicate object keys by default. The control protocol
// does not: two interpretations of a key-bearing request are never useful.
func uniqueJSON(decoder *json.Decoder, depth int) bool {
	if depth > 16 {
		return false
	}
	token, err := decoder.Token()
	if err != nil {
		return false
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return true
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return false
			}
			name, ok := key.(string)
			if !ok || name != strings.ToLower(name) || seen[name] {
				return false
			}
			seen[name] = true
			if !uniqueJSON(decoder, depth+1) {
				return false
			}
		}
		end, err := decoder.Token()
		return err == nil && end == json.Delim('}')
	case '[':
		for decoder.More() {
			if !uniqueJSON(decoder, depth+1) {
				return false
			}
		}
		end, err := decoder.Token()
		return err == nil && end == json.Delim(']')
	default:
		return false
	}
}

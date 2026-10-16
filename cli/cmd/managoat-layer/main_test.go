package main

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"github.com/managoat/managoat/cli/internal/layers"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"filippo.io/age"
)

func TestKeygenProtocol(t *testing.T) {
	var output bytes.Buffer
	if code := run(context.Background(), strings.NewReader(`{"operation":"keygen"}`), &output); code != 0 {
		t.Fatalf("%d %s", code, output.String())
	}
	var result response
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	id, err := age.ParseX25519Identity(result.Identity)
	if err != nil || id.Recipient().String() != result.Recipient || !result.OK {
		t.Fatalf("invalid key pair: %v", err)
	}
}
func TestMalformedRequestsAndSecretSafeErrors(t *testing.T) {
	cases := []string{
		`{"operation":"fetch","identity":"AGE-SECRET-KEY-1SECRET","url":"https://secret.example/?token=SECRET"}`,
		`{"operation":"restore","identity":"SECRET","input":"/SECRET/path"}`,
		`{"operation":"keygen","unknown":true}`,
		`{"operation":"keygen"} {"operation":"keygen"}`,
		`{"operation":"keygen","operation":"fetch"}`,
		`{"operation":"keygen","Operation":"fetch"}`,
		strings.Repeat(" ", 65537),
	}
	for _, input := range cases {
		var out bytes.Buffer
		if code := run(context.Background(), strings.NewReader(input), &out); code == 0 {
			t.Fatalf("accepted invalid request: %s", input[:min(len(input), 100)])
		}
		if strings.Contains(out.String(), "SECRET") || strings.Contains(out.String(), "secret.example") {
			t.Fatal("leaked request material")
		}
		var response response
		if err := json.Unmarshal(out.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.Dirty {
			t.Fatal("invalid request marked dirty")
		}
	}
}

func TestControlFileCleanup(t *testing.T) {
	for _, op := range []string{"keygen", "unknown"} {
		f, err := os.CreateTemp("/tmp", "managoat-layer-request-")
		if err != nil {
			t.Fatal(err)
		}
		path := f.Name()
		f.Close()
		t.Cleanup(func() { os.Remove(path) })
		input, _ := json.Marshal(request{Operation: op, CleanupFile: path})
		var out bytes.Buffer
		run(context.Background(), bytes.NewReader(input), &out)
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatal("request file retained")
		}
	}
}
func TestControlFileCleanupCannotDeleteOtherPaths(t *testing.T) {
	path := filepath.Join(t.TempDir(), "keep")
	if err := os.WriteFile(path, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	input, _ := json.Marshal(request{Operation: "keygen", CleanupFile: path})
	var out bytes.Buffer
	if run(context.Background(), bytes.NewReader(input), &out) == 0 {
		t.Fatal("accepted arbitrary cleanup path")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
}

func TestRestoreRemovesKeyRequestAndCiphertext(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.tar")
	f, err := os.Create(source)
	if err != nil {
		t.Fatal(err)
	}
	w := tar.NewWriter(f)
	if err = w.WriteHeader(&tar.Header{Name: "workspace/restored", Mode: 0600, Uid: os.Getuid(), Gid: os.Getgid(), Size: 4}); err != nil {
		t.Fatal(err)
	}
	if _, err = w.Write([]byte("data")); err != nil {
		t.Fatal(err)
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	binding := layers.Binding{Version: 1, User: "fixture", Environment: "fixture", Fingerprint: strings.Repeat("a", 64), Provider: "sprites", Architecture: "amd64", Base: "fixture"}
	cipher := filepath.Join(dir, "cipher.age")
	sealed, err := layers.Seal(context.Background(), source, cipher, id.Recipient().String(), binding, layers.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	control, err := os.CreateTemp("/tmp", "managoat-layer-request-")
	if err != nil {
		t.Fatal(err)
	}
	path := control.Name()
	control.Close()
	t.Cleanup(func() { os.Remove(path) })
	input, _ := json.Marshal(request{Operation: "restore", Input: cipher, Output: root, Identity: id.String(), SHA256: sealed.SHA256, Binding: binding, CleanupFile: path})
	if err = os.WriteFile(path, input, 0600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if run(context.Background(), bytes.NewReader(input), &out) != 0 {
		t.Fatalf("restore failed: %s", out.String())
	}
	for _, file := range []string{path, cipher} {
		if _, err = os.Stat(file); !os.IsNotExist(err) {
			t.Fatalf("sensitive staging retained: %s", file)
		}
	}
	data, err := os.ReadFile(filepath.Join(root, "workspace/restored"))
	if err != nil || string(data) != "data" {
		t.Fatalf("restore output: %v", err)
	}
	if strings.Contains(out.String(), id.String()) {
		t.Fatal("key leaked")
	}
	// A cleanup failure follows successful extraction and must be reported dirty.
	blocked, err := os.MkdirTemp("/tmp", "managoat-layer-request-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(blocked) })
	if err = os.WriteFile(filepath.Join(blocked, "retained"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	sealed, err = layers.Seal(context.Background(), source, cipher, id.Recipient().String(), binding, layers.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	input, _ = json.Marshal(request{Operation: "restore", Input: cipher, Output: t.TempDir(), Identity: id.String(), SHA256: sealed.SHA256, Binding: binding, CleanupFile: blocked})
	out.Reset()
	if run(context.Background(), bytes.NewReader(input), &out) == 0 {
		t.Fatal("accepted failed cleanup")
	}
	var failed response
	if err = json.Unmarshal(out.Bytes(), &failed); err != nil {
		t.Fatal(err)
	}
	if failed.OK || !failed.Dirty {
		t.Fatal("post-extraction cleanup failure must require a fresh machine")
	}

}

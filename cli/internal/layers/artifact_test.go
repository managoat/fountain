package layers

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"filippo.io/age"
	"github.com/klauspost/compress/zstd"
)

func binding() Binding {
	return Binding{1, "tenant-a", "environment-a", strings.Repeat("a", 64), "sprites", "amd64", "immutable-base-123"}
}
func limits() Limits { return Limits{8 << 20, 32 << 20, 16 << 20, 100, 10} }
func header(name string, kind byte) *tar.Header {
	return &tar.Header{Name: name, Typeflag: kind, Mode: 0750, Uid: os.Getuid(), Gid: os.Getgid(), ModTime: time.Unix(1700000000, 0)}
}
func tarData(t *testing.T, headers ...*tar.Header) []byte {
	t.Helper()
	var b bytes.Buffer
	w := tar.NewWriter(&b)
	for _, h := range headers {
		if h.Typeflag == tar.TypeReg {
			h.Size = 4
		}
		if err := w.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if h.Size > 0 {
			if _, err := w.Write([]byte("data")); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func identity(t *testing.T) *age.X25519Identity {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	return id
}
func write(t *testing.T, name string, data []byte) {
	t.Helper()
	if err := os.WriteFile(name, data, 0600); err != nil {
		t.Fatal(err)
	}
}
func digest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func fixture(t *testing.T) (string, *age.X25519Identity, Result) {
	t.Helper()
	dir := t.TempDir()
	input := filepath.Join(dir, "input.tar")
	output := filepath.Join(dir, "layer")
	symlink := header("workspace/link", tar.TypeSymlink)
	symlink.Linkname = "/workspace/file"
	hard := header("workspace/hard", tar.TypeLink)
	hard.Linkname = "workspace/file"
	write(t, input, tarData(t, header("workspace", tar.TypeDir), header("workspace/file", tar.TypeReg), symlink, hard))
	id := identity(t)
	result, err := Seal(context.Background(), input, output, id.Recipient().String(), binding(), limits())
	if err != nil {
		t.Fatal(err)
	}
	return output, id, result
}
func TestRoundTrip(t *testing.T) {
	input, id, sealed := fixture(t)
	dest := t.TempDir()
	result, err := Restore(context.Background(), input, dest, id.String(), sealed.SHA256, binding(), limits())
	if err != nil {
		t.Fatal(err)
	}
	if result.Entries != 4 || result.Bytes != sealed.Bytes {
		t.Fatalf("result: %+v", result)
	}
	for _, name := range []string{"file", "link", "hard"} {
		b, err := os.ReadFile(filepath.Join(dest, "workspace", name))
		if err != nil || string(b) != "data" {
			t.Fatalf("%s: %q %v", name, b, err)
		}
	}
	info, err := os.Stat(filepath.Join(dest, "workspace/file"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0750 || info.ModTime().Unix() != 1700000000 {
		t.Fatalf("metadata: %v", info)
	}
	target, err := os.Readlink(filepath.Join(dest, "workspace/link"))
	if err != nil || target != "file" {
		t.Fatalf("link: %q %v", target, err)
	}
	info, err = os.Stat(input)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("artifact mode: %v %v", info, err)
	}
}
func TestWrongBindingAndKeyNeverMutate(t *testing.T) {
	input, id, sealed := fixture(t)
	for _, field := range []string{"tenant", "environment", "fingerprint", "provider", "arch", "base", "key"} {
		t.Run(field, func(t *testing.T) {
			b := binding()
			key := id.String()
			switch field {
			case "tenant":
				b.User = "tenant-b"
			case "environment":
				b.Environment = "env-b"
			case "fingerprint":
				b.Fingerprint = strings.Repeat("b", 64)
			case "provider":
				b.Provider = "e2b"
			case "arch":
				b.Architecture = "arm64"
			case "base":
				b.Base = "other"
			case "key":
				key = identity(t).String()
			}
			dest := t.TempDir()
			_, err := Restore(context.Background(), input, dest, key, sealed.SHA256, b, limits())
			assertCleanFailure(t, dest, err)
		})
	}
}
func assertCleanFailure(t *testing.T, dest string, err error) {
	t.Helper()
	var restore *RestoreError
	if !errors.As(err, &restore) || restore.Dirty {
		t.Fatalf("expected clean failure, got %v", err)
	}
	entries, e := os.ReadDir(dest)
	if e != nil || len(entries) != 0 {
		t.Fatalf("mutated destination: %v %v", entries, e)
	}
}
func TestCorruptionTruncationAndDigest(t *testing.T) {
	input, id, sealed := fixture(t)
	original, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"digest", "tamper", "truncated", "appended"} {
		t.Run(mode, func(t *testing.T) {
			data := bytes.Clone(original)
			expected := sealed.SHA256
			switch mode {
			case "digest":
				expected = strings.Repeat("0", 64)
			case "tamper":
				data[len(data)-1] ^= 1
			case "truncated":
				data = data[:len(data)-1]
			case "appended":
				data = append(data, 1)
			}
			// Even with the modified ciphertext's digest, age must reject corrupt frames.
			if mode != "digest" {
				expected = digest(data)
			}
			file := filepath.Join(t.TempDir(), "layer")
			write(t, file, data)
			dest := t.TempDir()
			_, err := Restore(context.Background(), file, dest, id.String(), expected, binding(), limits())
			assertCleanFailure(t, dest, err)
		})
	}
}
func TestSealRefusesExistingOutput(t *testing.T) {
	input, id, result := fixture(t)
	before, _ := os.ReadFile(input)
	tarfile := filepath.Join(t.TempDir(), "input.tar")
	write(t, tarfile, tarData(t, header("workspace/x", tar.TypeReg)))
	_, err := Seal(context.Background(), tarfile, input, id.Recipient().String(), binding(), limits())
	if err == nil {
		t.Fatal("overwrote output")
	}
	after, _ := os.ReadFile(input)
	if !bytes.Equal(before, after) || digest(after) != result.SHA256 {
		t.Fatal("changed existing output")
	}
}
func rawEncrypted(t *testing.T, raw []byte, id *age.X25519Identity) []byte {
	t.Helper()
	var b bytes.Buffer
	w, err := age.Encrypt(&b, id.Recipient())
	if err != nil {
		t.Fatal(err)
	}
	// Obtain the canonical inner header from a valid stream to avoid a second
	// implementation of the framing in malicious archive fixtures.
	input, validID, _ := fixture(t)
	f, err := os.Open(input)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	plain, err := age.Decrypt(f, validID)
	if err != nil {
		t.Fatal(err)
	}
	all, err := io.ReadAll(plain)
	if err != nil {
		t.Fatal(err)
	}
	offset, err := checkBinding(bytes.NewReader(all), binding())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = w.Write(all[:offset]); err != nil {
		t.Fatal(err)
	}
	z, err := zstd.NewWriter(w, zstd.WithEncoderConcurrency(1))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = z.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err = z.Close(); err != nil {
		t.Fatal(err)
	}
	if err = w.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}
func TestUnsafeArchivesNeverMutate(t *testing.T) {
	tests := map[string][]*tar.Header{}
	for _, name := range []string{"../escape", "/absolute", "workspace/../etc/passwd", ".sprite/api.sock", ".sprite/services/config", "etc/ssl/private/key", "home/sprite/.env", "opt/managoat-layer/helper", "workspace/a\\b", "workspace/.wh.deleted", "workspace/.wh.dir/file"} {
		tests[name] = []*tar.Header{header(name, tar.TypeReg)}
	}
	tests["duplicate"] = []*tar.Header{header("workspace/a", tar.TypeReg), header("workspace/a", tar.TypeReg)}
	tests["device"] = []*tar.Header{header("workspace/device", tar.TypeChar)}
	tests["fifo"] = []*tar.Header{header("workspace/fifo", tar.TypeFifo)}
	mode := header("workspace/suid", tar.TypeReg)
	mode.Mode = 04755
	tests["setuid"] = []*tar.Header{mode}
	symlink := header("workspace/link", tar.TypeSymlink)
	symlink.Linkname = "../../etc/ssl/private/key"
	tests["symlink escape"] = []*tar.Header{symlink}
	parent := header("workspace/parent", tar.TypeSymlink)
	parent.Linkname = "/workspace/other"
	tests["symlink parent"] = []*tar.Header{parent, header("workspace/parent/file", tar.TypeReg)}
	tests["late symlink parent"] = []*tar.Header{header("workspace/parent/file", tar.TypeReg), parent}
	hard := header("workspace/link", tar.TypeLink)
	hard.Linkname = "etc/passwd"
	tests["external hardlink"] = []*tar.Header{hard}
	mismatch := header("workspace/mismatch", tar.TypeLink)
	mismatch.Linkname = "workspace/file"
	mismatch.Mode = 0600
	tests["hardlink metadata mismatch"] = []*tar.Header{header("workspace/file", tar.TypeReg), mismatch}
	pax := header("workspace/file", tar.TypeReg)
	pax.PAXRecords = map[string]string{"SCHILY.xattr.security.capability": "bad"}
	tests["xattr"] = []*tar.Header{pax}
	for name, headers := range tests {
		t.Run(name, func(t *testing.T) {
			id := identity(t)
			data := rawEncrypted(t, tarData(t, headers...), id)
			file := filepath.Join(t.TempDir(), "bad")
			write(t, file, data)
			dest := t.TempDir()
			_, err := Restore(context.Background(), file, dest, id.String(), digest(data), binding(), limits())
			assertCleanFailure(t, dest, err)
		})
	}
}
func TestLimitsAndCancellation(t *testing.T) {
	input, id, sealed := fixture(t)
	for _, which := range []string{"cipher", "tar", "file", "entries", "canceled"} {
		t.Run(which, func(t *testing.T) {
			l := limits()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			switch which {
			case "cipher":
				l.CipherBytes = 10
			case "tar":
				l.TarBytes = 32
				l.FileBytes = 32
			case "file":
				l.FileBytes = 2
			case "entries":
				l.Entries = 1
			case "canceled":
				cancel()
			}
			dest := t.TempDir()
			_, err := Restore(ctx, input, dest, id.String(), sealed.SHA256, binding(), l)
			assertCleanFailure(t, dest, err)
		})
	}
}
func TestExistingSymlinkCannotEscapeDestination(t *testing.T) {
	input, id, sealed := fixture(t)
	dest := t.TempDir()
	outside := t.TempDir()
	sentinel := filepath.Join(outside, "file")
	write(t, sentinel, []byte("untouched"))
	if err := os.Symlink(outside, filepath.Join(dest, "workspace")); err != nil {
		t.Fatal(err)
	}
	_, err := Restore(context.Background(), input, dest, id.String(), sealed.SHA256, binding(), limits())
	var failure *RestoreError
	if !errors.As(err, &failure) || failure.Dirty {
		t.Fatalf("expected clean preflight rejection: %v", err)
	}
	data, _ := os.ReadFile(sentinel)
	if string(data) != "untouched" {
		t.Fatal("escaped target")
	}
}
func TestPartialWriteRequiresFreshMachine(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("requires unprivileged ownership failure")
	}
	h := header("workspace/file", tar.TypeReg)
	h.Uid = os.Getuid() + 1
	id := identity(t)
	data := rawEncrypted(t, tarData(t, h), id)
	file := filepath.Join(t.TempDir(), "layer")
	write(t, file, data)
	dest := t.TempDir()
	_, err := Restore(context.Background(), file, dest, id.String(), digest(data), binding(), limits())
	var failure *RestoreError
	if !errors.As(err, &failure) || !failure.Dirty {
		t.Fatalf("partial restore not marked dirty: %v", err)
	}
	if _, err = os.Stat(filepath.Join(dest, "workspace/file")); err != nil {
		t.Fatal("expected partial file to demonstrate owner cleanup requirement")
	}
}

// More than one age payload chunk must authenticate before any extraction.
func TestLargeArtifactFinalChunkAuthentication(t *testing.T) {
	payload := make([]byte, 2<<20)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	var raw bytes.Buffer
	w := tar.NewWriter(&raw)
	h := header("workspace/large", tar.TypeReg)
	h.Size = int64(len(payload))
	if err := w.WriteHeader(h); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	input, output := filepath.Join(dir, "input"), filepath.Join(dir, "sealed")
	write(t, input, raw.Bytes())
	id := identity(t)
	result, err := Seal(context.Background(), input, output, id.Recipient().String(), binding(), limits())
	if err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if _, err = Restore(context.Background(), output, dest, id.String(), result.SHA256, binding(), limits()); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dest, "workspace/large"))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatal("large payload changed")
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	data[len(data)-1] ^= 1
	write(t, output, data)
	clean := t.TempDir()
	_, err = Restore(context.Background(), output, clean, id.String(), digest(data), binding(), limits())
	assertCleanFailure(t, clean, err)
}

func TestTrailingTarAndBaseHardlink(t *testing.T) {
	id := identity(t)
	raw := tarData(t, header("workspace/file", tar.TypeReg))
	data := rawEncrypted(t, append(raw, []byte("hidden archive")...), id)
	input := filepath.Join(t.TempDir(), "layer")
	write(t, input, data)
	dest := t.TempDir()
	_, err := Restore(context.Background(), input, dest, id.String(), digest(data), binding(), limits())
	assertCleanFailure(t, dest, err)

	input, id, result := fixture(t)
	if err := os.Mkdir(filepath.Join(dest, "workspace"), 0755); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "sentinel")
	write(t, outside, []byte("untouched"))
	if err := os.Link(outside, filepath.Join(dest, "workspace/file")); err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(context.Background(), input, dest, id.String(), result.SHA256, binding(), limits()); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(outside)
	if err != nil || string(got) != "untouched" {
		t.Fatal("modified base hardlink target")
	}
}

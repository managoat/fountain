package layers

// The exporter compares complete content inventories, never ctime heuristics.
// V1 refuses deletions, special files, xattrs and type changes rather than
// silently producing a layer that cannot reproduce the built filesystem.
import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"time"
)

type fileRecord struct {
	Mode        uint32 `json:"mode"`
	UID         uint32 `json:"uid"`
	GID         uint32 `json:"gid"`
	Size        int64  `json:"size"`
	Modified    int64  `json:"modified"`
	Hash        string `json:"hash"`
	Link        string `json:"link"`
	Attributes  string `json:"attributes"`
	Unsupported bool   `json:"unsupported"`
}
type inventory struct {
	Version int                   `json:"version"`
	Files   map[string]fileRecord `json:"files"`
}

// Volatile/provider state is outside the portable filesystem contract. Other
// protected files are inventoried but any change to them refuses publication.
func volatile(name string) bool {
	if strings.HasPrefix(name, ".sprite/") && name != ".sprite/bin" && name != ".sprite/languages" && !strings.HasPrefix(name, ".sprite/bin/") && !strings.HasPrefix(name, ".sprite/languages/") {
		return true
	}
	for _, prefix := range []string{"proc", "sys", "dev", "run", "tmp", "var/tmp", "var/log", "var/run", "var/lock", "opt/managoat-layer", "var/lib/managoat"} {
		if name == prefix || strings.HasPrefix(name, prefix+"/") {
			return true
		}
	}
	return false
}

func scan(ctx context.Context, root string, limits Limits) (inventory, error) {
	result := inventory{Version: 1, Files: map[string]fileRecord{}}
	var total int64
	inventoryBytes, inventoryEntries := limits.InventoryBytes, limits.InventoryEntries
	if inventoryBytes == 0 {
		inventoryBytes = limits.TarBytes
	}
	if inventoryEntries == 0 {
		inventoryEntries = limits.Entries
	}
	err := filepath.WalkDir(root, func(full string, entry os.DirEntry, err error) error {
		if err != nil {
			return ErrArchive
		}
		if err = ctx.Err(); err != nil {
			return err
		}
		name, err := filepath.Rel(root, full)
		if err != nil {
			return ErrArchive
		}
		if name == "." {
			return nil
		}
		if volatile(name) {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if len(result.Files) >= inventoryEntries {
			return ErrLimit
		}
		info, err := entry.Info()
		if err != nil {
			return ErrArchive
		}
		st, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			return ErrArchive
		}
		r := fileRecord{Mode: uint32(info.Mode()), UID: st.Uid, GID: st.Gid, Modified: info.ModTime().UnixNano()}
		// Directory times vary when excluded runtime files appear. Their ownership
		// and mode still participate in compatibility and export.
		if info.IsDir() {
			r.Modified = 0
		}
		if !info.Mode().IsRegular() && !info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
			r.Unsupported = true
		}
		if info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
			r.Unsupported = true
		}
		if info.Mode()&os.ModeSymlink != 0 {
			r.Link, err = os.Readlink(full)
			if err != nil {
				return ErrArchive
			}
		} else {
			keys, e := attributeNames(full, syscall.Listxattr)
			if e != nil {
				return ErrArchive
			}
			r.Unsupported = r.Unsupported || len(keys) > 0
			if len(keys) > 0 {
				sort.Strings(keys)
				attrs := sha256.New()
				for _, key := range keys {
					size, e := syscall.Getxattr(full, key, nil)
					if e != nil || size > 1<<20 {
						return ErrArchive
					}
					value := make([]byte, size)
					actual, e := syscall.Getxattr(full, key, value)
					if e != nil || actual < 0 || actual > len(value) {
						return ErrArchive
					}
					encoded, _ := json.Marshal([]string{hex.EncodeToString([]byte(key)), hex.EncodeToString(value[:actual])})
					attrs.Write(encoded)
				}
				r.Attributes = hex.EncodeToString(attrs.Sum(nil))
			}
		}
		if info.Mode().IsRegular() {
			r.Size = info.Size()
			total += r.Size
			if r.Size > limits.FileBytes || total > inventoryBytes {
				return ErrLimit
			}
			f, e := os.Open(full)
			if e != nil {
				return ErrArchive
			}
			hash := sha256.New()
			n, e := io.Copy(hash, &contextReader{ctx, io.LimitReader(f, r.Size+1)})
			closeErr := f.Close()
			if e != nil || closeErr != nil || n != r.Size {
				return ErrArchive
			}
			r.Hash = hex.EncodeToString(hash.Sum(nil))
		}
		result.Files[name] = r
		return nil
	})
	return result, err
}

// Listxattr's size probe is an upper bound, not the length of the subsequent
// response. Sprites can report room for an ACL name and then return zero names.
// Honor the actual byte count rather than interpreting zero-filled slack as a key.
func attributeNames(path string, list func(string, []byte) (int, error)) ([]string, error) {
	n, err := list(path, nil)
	if err == syscall.ENOTSUP {
		return nil, nil
	}
	if err != nil || n < 0 || n > 1<<20 {
		return nil, ErrArchive
	}
	if n == 0 {
		return nil, nil
	}
	buffer := make([]byte, n)
	actual, err := list(path, buffer)
	if err != nil || actual < 0 || actual > len(buffer) {
		return nil, ErrArchive
	}
	if actual == 0 {
		return nil, nil
	}
	buffer = buffer[:actual]
	if buffer[len(buffer)-1] != 0 {
		return nil, ErrArchive
	}
	names := strings.Split(string(buffer[:len(buffer)-1]), "\x00")
	for _, name := range names {
		if name == "" {
			return nil, ErrArchive
		}
	}
	return names, nil
}

// Snapshot must run on a fresh, credential-free machine before reusable work.
// Its SHA256 is a content-derived base identity, not an operating-system label.
func Snapshot(ctx context.Context, root, output string, limits Limits) (Result, error) {
	if !limits.valid() {
		return Result{}, ErrInvalid
	}
	ctx, cancel := boundedContext(ctx, limits)
	defer cancel()
	state, err := scan(ctx, root, limits)
	if err != nil {
		return Result{}, err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return Result{}, ErrInvalid
	}
	result, err := publish(output, func(w io.Writer) error { _, err := w.Write(data); return err })
	result.Entries = len(state.Files)
	for name := range state.Files {
		if platformPath(name) {
			delete(state.Files, name)
		}
	}
	base, _ := json.Marshal(state)
	hash := sha256.Sum256(base)
	result.Base = "sha256:" + hex.EncodeToString(hash[:])
	return result, err
}

// Export checks the caller's baseline digest, inventories the quiescent tree,
// writes only representable changes, then repeats the inventory to detect drift.
func Export(ctx context.Context, root, baseline, output, expected string, limits Limits) (Result, error) {
	if !limits.valid() {
		return Result{}, ErrInvalid
	}
	ctx, cancel := boundedContext(ctx, limits)
	defer cancel()
	f, err := os.Open(baseline)
	if err != nil {
		return Result{}, ErrInvalid
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 128<<20))
	if err != nil {
		return Result{}, ErrInvalid
	}
	hash := sha256.Sum256(data)
	if hex.EncodeToString(hash[:]) != expected {
		return Result{}, ErrBinding
	}
	var before inventory
	if json.Unmarshal(data, &before) != nil || before.Version != 1 || before.Files == nil {
		return Result{}, ErrInvalid
	}
	after, err := scan(ctx, root, limits)
	if err != nil {
		return Result{}, err
	}
	for name, old := range before.Files {
		next, exists := after.Files[name]
		if !exists || os.FileMode(old.Mode).Type() != os.FileMode(next.Mode).Type() {
			return Result{}, ErrArchive
		}
	}
	names := []string{}
	var archiveBytes int64
	for name, next := range after.Files {
		if old, exists := before.Files[name]; exists && old == next {
			continue
		}
		if !safePath(name) || platformPath(name) || next.Unsupported {
			return Result{}, ErrArchive
		}
		if next.Link != "" {
			if _, err := linkTarget(name, next.Link); err != nil {
				return Result{}, err
			}
		}
		archiveBytes += next.Size
		if len(names) >= limits.Entries || archiveBytes > limits.TarBytes {
			return Result{}, ErrLimit
		}
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) == 0 {
		return Result{}, ErrArchive
	}
	result, err := publish(output, func(w io.Writer) error {
		tw := tar.NewWriter(w)
		for _, name := range names {
			full := filepath.Join(root, name)
			info, err := os.Lstat(full)
			if err != nil {
				return ErrArchive
			}
			record := after.Files[name]
			h, err := tar.FileInfoHeader(info, record.Link)
			if err != nil {
				return ErrArchive
			}
			h.Name = name
			h.Uid = int(record.UID)
			h.Gid = int(record.GID)
			h.Uname = ""
			h.Gname = ""
			if err = tw.WriteHeader(h); err != nil {
				return err
			}
			if info.Mode().IsRegular() {
				source, err := os.Open(full)
				if err != nil {
					return ErrArchive
				}
				_, err = io.Copy(tw, &contextReader{ctx, source})
				closeErr := source.Close()
				if err != nil || closeErr != nil {
					return ErrArchive
				}
			}
		}
		if err := tw.Close(); err != nil {
			return err
		}
		final, err := scan(ctx, root, limits)
		if err != nil || !reflect.DeepEqual(after, final) {
			return ErrArchive
		}
		return nil
	})
	if err == nil {
		result.Entries = len(names)
	}
	return result, err
}

func boundedContext(ctx context.Context, limits Limits) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, time.Duration(limits.TimeoutSeconds)*time.Second)
}

func platformPath(name string) bool {
	for _, prefix := range []string{"etc/machine-id", "etc/hostname", "etc/hosts", "etc/resolv.conf", "etc/ssh", "etc/ssl/private", "etc/ssl/certs", "usr/local/share/ca-certificates/agent-vault.crt", "usr/local/share/ca-certificates/agent-vault.crt.trust-store-ready", "etc/sudoers.d/fountain-broker-proxy", "home/sprite/.gitconfig"} {
		if name == prefix || strings.HasPrefix(name, prefix+"/") {
			return true
		}
	}
	return false
}

package layers

import (
	"archive/tar"
	"context"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

func parentPath(name string) string { return filepath.Dir(name) }

// Interrupted archive reads are not evidence of an unsafe archive. Preserve the
// deadline/cancellation so the controller can distinguish operational failures.
func archiveReadError(err error) error {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	return ErrArchive
}

// V1 is deliberately conservative: no devices, FIFOs, sparse files, capabilities,
// ACLs, set-id bits, or deletions. A builder must refuse publication if any of
// those are required. It must not quietly omit a deletion from its manifest.
func safePath(name string) bool {
	for _, component := range strings.Split(name, "/") {
		if strings.HasPrefix(component, ".wh.") {
			return false
		}
	}
	if name == "" || name == "." || len(name) > 4096 || !utf8.ValidString(name) || strings.ContainsAny(name, "\x00\\\r\n") || strings.HasPrefix(name, "/") || path.Clean(name) != name {
		return false
	}
	for _, prefix := range []string{"proc", "sys", "dev", "run", "tmp", "var/tmp", "var/run", "var/lock", "var/lib/managoat", "opt/managoat-layer", "etc/ssh", "etc/ssl/private", "etc/machine-id", "etc/hostname", "etc/hosts", "home/sprite/.env", "home/sprite/.ssh", "home/sprite/.aws", "home/sprite/.claude", "home/sprite/.codex", "home/sprite/.gemini", "home/sprite/.managoat"} {
		if name == prefix || strings.HasPrefix(name, prefix+"/") {
			return false
		}
	}
	switch strings.Split(name, "/")[0] {
	case "usr", "etc", "var", "opt", "workspace", "bin", "sbin", "lib", "lib64":
		return true
	case "home":
		return name == "home" || name == "home/sprite" || strings.HasPrefix(name, "home/sprite/")
	case ".sprite":
		return name == ".sprite" || name == ".sprite/bin" || strings.HasPrefix(name, ".sprite/bin/") || name == ".sprite/languages" || strings.HasPrefix(name, ".sprite/languages/")
	default:
		return false
	}
}
func linkTarget(name, target string) (string, error) {
	if target == "" || len(target) > 4096 || strings.ContainsAny(target, "\x00\\\r\n") {
		return "", ErrArchive
	}
	var resolved string
	if strings.HasPrefix(target, "/") {
		resolved = path.Clean(strings.TrimPrefix(target, "/"))
	} else {
		resolved = path.Join(path.Dir(name), target)
	}
	if !safePath(resolved) {
		return "", ErrArchive
	}
	return resolved, nil
}
func validateTar(ctx context.Context, r io.Reader, limits Limits) (int, error) {
	reader := tar.NewReader(&contextReader{ctx, r})
	seen := map[string]byte{}
	regular := map[string]*tar.Header{}
	ancestors := map[string]bool{}
	var total int64
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return 0, archiveReadError(err)
		}
		name := strings.TrimSuffix(header.Name, "/")
		if !safePath(name) || len(seen) >= limits.Entries || header.Size < 0 || header.Size > limits.FileBytes {
			return 0, ErrArchive
		}
		if _, exists := seen[name]; exists {
			return 0, ErrArchive
		}
		if header.Mode < 0 || header.Mode & ^int64(0777) != 0 || header.Uid < 0 || header.Gid < 0 || int64(header.Uid) > 1<<31-1 || int64(header.Gid) > 1<<31-1 {
			return 0, ErrArchive
		}
		for key := range header.PAXRecords {
			switch key {
			case "path", "linkpath", "mtime", "atime", "ctime":
			default:
				return 0, ErrArchive
			}
		}
		if len(header.Xattrs) != 0 {
			return 0, ErrArchive
		}
		for parent := path.Dir(name); parent != "."; parent = path.Dir(parent) {
			if kind, ok := seen[parent]; ok && kind != tar.TypeDir {
				return 0, ErrArchive
			}
		}
		// A non-directory may not replace an ancestor of a previously seen entry.
		if header.Typeflag != tar.TypeDir && ancestors[name] {
			return 0, ErrArchive
		}
		for parent := path.Dir(name); parent != "."; parent = path.Dir(parent) {
			ancestors[parent] = true
		}
		switch header.Typeflag {
		case tar.TypeReg, tar.TypeRegA:
			regular[name] = header
			total += header.Size
			if total > limits.TarBytes {
				return 0, ErrLimit
			}
		case tar.TypeDir:
			if header.Size != 0 {
				return 0, ErrArchive
			}
		case tar.TypeSymlink:
			if header.Size != 0 {
				return 0, ErrArchive
			}
			if _, err := linkTarget(name, header.Linkname); err != nil {
				return 0, err
			}
		case tar.TypeLink:
			if header.Size != 0 || !safePath(header.Linkname) {
				return 0, ErrArchive
			}
			kind, ok := seen[header.Linkname]
			if !ok || (kind != tar.TypeReg && kind != tar.TypeRegA) {
				return 0, ErrArchive
			}
			source := regular[header.Linkname]
			if source.Mode != header.Mode || source.Uid != header.Uid || source.Gid != header.Gid || !source.ModTime.Equal(header.ModTime) {
				return 0, ErrArchive
			}
		default:
			return 0, ErrArchive
		}
		seen[name] = header.Typeflag
		if _, err = io.Copy(io.Discard, reader); err != nil {
			return 0, archiveReadError(err)
		}
	}
	// tar EOF is not necessarily stream EOF. Reject hidden concatenated archives
	// and nonzero trailing data; accept only conventional zero block padding.
	buf := make([]byte, 32<<10)
	for {
		n, err := r.Read(buf)
		for _, b := range buf[:n] {
			if b != 0 {
				return 0, ErrArchive
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, archiveReadError(err)
		}
		if err = ctx.Err(); err != nil {
			return 0, err
		}
	}
	if len(seen) == 0 {
		return 0, ErrArchive
	}
	return len(seen), nil
}

func parents(root *os.Root, name string, create bool) error {
	parts := strings.Split(path.Dir(name), "/")
	current := ""
	if parts[0] == "." {
		return nil
	}
	for _, part := range parts {
		current = path.Join(current, part)
		info, err := root.Lstat(current)
		if os.IsNotExist(err) && create {
			if err = root.Mkdir(current, 0755); err != nil {
				return ErrArchive
			}
			continue
		}
		if os.IsNotExist(err) && !create {
			return nil
		}
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return ErrArchive
		}
	}
	return nil
}
func extractTar(ctx context.Context, root *os.Root, file *os.File, dirty *bool) (result error) {
	// Preflight all existing destinations before mutation. The caller must keep
	// the fresh machine quiescent; os.Root confines access even if it is renamed.
	reader := tar.NewReader(&contextReader{ctx, file})
	for {
		h, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return archiveReadError(err)
		}
		name := strings.TrimSuffix(h.Name, "/")
		if err = parents(root, name, false); err != nil {
			return err
		}
		info, err := root.Lstat(name)
		if err == nil && (info.Mode()&os.ModeSymlink != 0 || (h.Typeflag == tar.TypeDir) != info.IsDir() || (!info.IsDir() && !info.Mode().IsRegular())) {
			return ErrArchive
		}
		if err != nil && !os.IsNotExist(err) {
			return ErrArchive
		}
	}
	if _, err := file.Seek(0, 0); err != nil {
		return ErrInvalid
	}
	reader = tar.NewReader(&contextReader{ctx, file})
	syncer := newFileSyncer(ctx)
	defer func() {
		if err := syncer.finish(); result == nil {
			result = err
		}
	}()
	var directories []*tar.Header
	for {
		h, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return archiveReadError(err)
		}
		if err = ctx.Err(); err != nil {
			return err
		}
		name := strings.TrimSuffix(h.Name, "/")
		*dirty = true
		if err = parents(root, name, true); err != nil {
			return err
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if err = root.MkdirAll(name, 0700); err != nil {
				return ErrArchive
			}
			h.Name = name
			directories = append(directories, h)
		case tar.TypeReg, tar.TypeRegA:
			// Unlink first: a base-image hardlink must not let a write alter a different
			// (possibly protected) path. No tenant processes run during restore.
			if err = root.Remove(name); err != nil && !os.IsNotExist(err) {
				return ErrArchive
			}
			f, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err != nil {
				return ErrArchive
			}
			_, copyErr := io.Copy(f, reader)
			if copyErr != nil {
				_ = f.Close()
				return archiveReadError(copyErr)
			}
			ownerErr := f.Chown(h.Uid, h.Gid)
			modeErr := f.Chmod(os.FileMode(h.Mode))
			timeErr := root.Chtimes(name, h.ModTime, h.ModTime)
			if ownerErr != nil || modeErr != nil || timeErr != nil {
				_ = f.Close()
				return ErrArchive
			}
			if err = syncer.enqueue(f); err != nil {
				return err
			}

		case tar.TypeSymlink:
			target, _ := linkTarget(name, h.Linkname)
			relative, err := filepath.Rel(filepath.FromSlash(path.Dir(name)), filepath.FromSlash(target))
			if err != nil {
				return ErrArchive
			}
			if err = root.Remove(name); err != nil && !os.IsNotExist(err) {
				return ErrArchive
			}
			if err = root.Symlink(relative, name); err != nil {
				return ErrArchive
			}
			if err = root.Lchown(name, h.Uid, h.Gid); err != nil {
				return ErrArchive
			}
		case tar.TypeLink:
			if err = root.Remove(name); err != nil && !os.IsNotExist(err) {
				return ErrArchive
			}
			if err = root.Link(h.Linkname, name); err != nil {
				return ErrArchive
			}
		default:
			return ErrArchive
		}
	}
	for i := len(directories) - 1; i >= 0; i-- {
		h := directories[i]
		if err := root.Chown(h.Name, h.Uid, h.Gid); err != nil {
			return ErrArchive
		}
		if err := root.Chmod(h.Name, os.FileMode(h.Mode)); err != nil {
			return ErrArchive
		}
		if err := root.Chtimes(h.Name, h.ModTime, h.ModTime); err != nil {
			return ErrArchive
		}
	}
	return nil
}

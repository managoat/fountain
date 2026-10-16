package layers

import (
	"archive/tar"
	"context"
	"filippo.io/age"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func treeFile(t *testing.T, root, name, value string) {
	t.Helper()
	full := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(full), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(value), 0644); err != nil {
		t.Fatal(err)
	}
}
func TestExportContentDeltaAndDeletionRefusal(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	temp := t.TempDir()
	treeFile(t, root, "usr/lib/base", "base")
	treeFile(t, root, "workspace/source", "before")
	baseline := filepath.Join(temp, "baseline")
	snap, err := Snapshot(ctx, root, baseline, DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	treeFile(t, root, "workspace/source", "after")
	treeFile(t, root, "workspace/new", "new")
	output := filepath.Join(temp, "delta.tar")
	result, err := Export(ctx, root, baseline, output, snap.SHA256, DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if result.Entries < 2 || !strings.HasPrefix(snap.Base, "sha256:") {
		t.Fatal(result, snap)
	}
	f, _ := os.Open(output)
	defer f.Close()
	tr := tar.NewReader(f)
	found := map[string]string{}
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			t.Fatal(e)
		}
		data, _ := io.ReadAll(tr)
		found[h.Name] = string(data)
	}
	if found["workspace/source"] != "after" || found["workspace/new"] != "new" {
		t.Fatal(found)
	}
	if _, exists := found["usr/lib/base"]; exists {
		t.Fatal("unchanged file exported")
	}
	if err := os.Remove(filepath.Join(root, "usr/lib/base")); err != nil {
		t.Fatal(err)
	}
	if _, err := Export(ctx, root, baseline, filepath.Join(temp, "bad.tar"), snap.SHA256, DefaultLimits()); err == nil {
		t.Fatal("deletion silently omitted")
	}
}
func TestExportRejectsProtectedChangesAndBaselineTampering(t *testing.T) {
	for _, name := range []string{"home/sprite/.env", "etc/ssl/certs/ca-certificates.crt", "etc/machine-id"} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			temp := t.TempDir()
			treeFile(t, root, name, "before")
			baseline := filepath.Join(temp, "baseline")
			snap, err := Snapshot(context.Background(), root, baseline, DefaultLimits())
			if err != nil {
				t.Fatal(err)
			}
			treeFile(t, root, name, "after")
			if _, err := Export(context.Background(), root, baseline, filepath.Join(temp, "out"), snap.SHA256, DefaultLimits()); err == nil {
				t.Fatal("protected change accepted")
			}
			if _, err := Export(context.Background(), root, baseline, filepath.Join(temp, "out"), strings.Repeat("0", 64), DefaultLimits()); err != ErrBinding {
				t.Fatal(err)
			}
		})
	}
}
func TestBaseIdentityIgnoresPlatformTrustButTracksContents(t *testing.T) {
	root := t.TempDir()
	temp := t.TempDir()
	treeFile(t, root, "usr/lib/base", "base")
	treeFile(t, root, "etc/ssl/certs/ca-certificates.crt", "ca1")
	first, err := Snapshot(context.Background(), root, filepath.Join(temp, "one"), DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	treeFile(t, root, "etc/ssl/certs/ca-certificates.crt", "ca2")
	second, err := Snapshot(context.Background(), root, filepath.Join(temp, "two"), DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if first.Base != second.Base || first.SHA256 == second.SHA256 {
		t.Fatal("platform trust changed tenant base identity")
	}
	treeFile(t, root, "usr/lib/base", "different")
	third, err := Snapshot(context.Background(), root, filepath.Join(temp, "three"), DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if first.Base == third.Base {
		t.Fatal("base content change missed")
	}
}
func TestExportLimitsAndUnsupportedTypes(t *testing.T) {
	root := t.TempDir()
	temp := t.TempDir()
	treeFile(t, root, "workspace/file", "base")
	baseline := filepath.Join(temp, "base")
	snap, err := Snapshot(context.Background(), root, baseline, DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "workspace/file")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", filepath.Join(root, "workspace/file")); err != nil {
		t.Fatal(err)
	}
	if _, err := Export(context.Background(), root, baseline, filepath.Join(temp, "out"), snap.SHA256, DefaultLimits()); err == nil {
		t.Fatal("type replacement accepted")
	}
	l := DefaultLimits()
	l.InventoryEntries = 1
	if _, err := Snapshot(context.Background(), root, filepath.Join(temp, "limited"), l); err != ErrLimit {
		t.Fatal(err)
	}
}

func TestExportSealRestoreReproducesChangedFiles(t *testing.T) {
	ctx := context.Background()
	source := t.TempDir()
	target := t.TempDir()
	temp := t.TempDir()
	for _, root := range []string{source, target} {
		treeFile(t, root, "workspace/original", "old")
	}
	baseline := filepath.Join(temp, "baseline")
	snapshot, err := Snapshot(ctx, source, baseline, DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	treeFile(t, source, "workspace/original", "rebuilt")
	treeFile(t, source, "workspace/added", "new")
	archive := filepath.Join(temp, "delta")
	if _, err := Export(ctx, source, baseline, archive, snapshot.SHA256, DefaultLimits()); err != nil {
		t.Fatal(err)
	}
	identity, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	sealed := filepath.Join(temp, "encrypted")
	result, err := Seal(ctx, archive, sealed, identity.Recipient().String(), binding(), DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Restore(ctx, sealed, target, identity.String(), result.SHA256, binding(), DefaultLimits()); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"workspace/original": "rebuilt", "workspace/added": "new"} {
		got, err := os.ReadFile(filepath.Join(target, name))
		if err != nil || string(got) != want {
			t.Fatalf("%s %q %v", name, got, err)
		}
	}
}

func TestExportRefusesChangedExtendedAttributes(t *testing.T) {
	root := t.TempDir()
	temp := t.TempDir()
	treeFile(t, root, "workspace/file", "same")
	file := filepath.Join(root, "workspace/file")
	if err := syscall.Setxattr(file, "user.layer-test", []byte{0xff}, 0); err == syscall.ENOTSUP {
		t.Skip("filesystem has no xattrs")
	} else if err != nil {
		t.Fatal(err)
	}
	baseline := filepath.Join(temp, "base")
	snap, err := Snapshot(context.Background(), root, baseline, DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Setxattr(file, "user.layer-test", []byte{0xfe}, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := Export(context.Background(), root, baseline, filepath.Join(temp, "out"), snap.SHA256, DefaultLimits()); err == nil {
		t.Fatal("unsupported attribute change omitted")
	}
}

func TestAttributeListUsesActualLength(t *testing.T) {
	for _, result := range []string{"", "user.present\x00"} {
		names, err := attributeNames("fixture", func(_ string, buffer []byte) (int, error) {
			if buffer == nil {
				return 23, nil
			}
			return copy(buffer, []byte(result)), nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if result == "" && len(names) != 0 {
			t.Fatalf("phantom attributes: %q", names)
		}
		if result != "" && (len(names) != 1 || names[0] != "user.present") {
			t.Fatalf("names: %q", names)
		}
	}
}

func TestInventoryBudgetDoesNotRaiseArtifactBudget(t *testing.T) {
	root, temp := t.TempDir(), t.TempDir()
	treeFile(t, root, "workspace/base1", "12345678")
	treeFile(t, root, "workspace/base2", "12345678")
	l := DefaultLimits()
	l.TarBytes = 8
	l.FileBytes = 8

	snap, err := Snapshot(context.Background(), root, filepath.Join(temp, "base"), l)
	if err != nil {
		t.Fatal(err)
	}
	treeFile(t, root, "workspace/new1", "12345678")
	treeFile(t, root, "workspace/new2", "12345678")
	if _, err = Export(context.Background(), root, filepath.Join(temp, "base"), filepath.Join(temp, "out"), snap.SHA256, l); err != ErrLimit {
		t.Fatalf("artifact limit: %v", err)
	}
}

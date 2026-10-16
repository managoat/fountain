// Package layers implements the opt-in environment artifact primitive (ADR 0090).
// It does not select artifacts, own machines, or change network policy.
package layers

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"time"

	"filippo.io/age"
	"github.com/klauspost/compress/zstd"
)

var (
	ErrInvalid        = errors.New("invalid layer")
	ErrLimit          = errors.New("layer limit exceeded")
	ErrBinding        = errors.New("incompatible layer")
	ErrAuthentication = errors.New("layer authentication failed")
	ErrArchive        = errors.New("unsupported or unsafe layer archive")
	ErrTransfer       = errors.New("layer transfer failed")
)

// Binding is trusted controller metadata, not a claim read from object storage.
// Fingerprint is a tenant-keyed digest. Base must identify an immutable image.
type Binding struct {
	Version      int    `json:"version"`
	User         string `json:"user"`
	Environment  string `json:"environment"`
	Fingerprint  string `json:"fingerprint"`
	Provider     string `json:"provider"`
	Architecture string `json:"architecture"`
	Base         string `json:"base"`
}

func (b Binding) valid() bool {
	if b.Version != 1 {
		return false
	}
	for _, s := range []string{b.User, b.Environment, b.Fingerprint, b.Provider, b.Architecture, b.Base} {
		if len(s) == 0 || len(s) > 256 {
			return false
		}
	}
	digest, err := hex.DecodeString(b.Fingerprint)
	return err == nil && len(digest) == 32
}

type Limits struct {
	CipherBytes    int64 `json:"cipher_bytes"`
	TarBytes       int64 `json:"tar_bytes"`
	FileBytes      int64 `json:"file_bytes"`
	Entries        int   `json:"entries"`
	TimeoutSeconds int   `json:"timeout_seconds"`
}

func DefaultLimits() Limits { return Limits{1 << 30, 4 << 30, 1 << 30, 100_000, 120} }
func (l Limits) valid() bool {
	// Hard ceilings cannot be raised by an artifact or an accidental request.
	return l.CipherBytes > 0 && l.CipherBytes <= 8<<30 && l.TarBytes > 0 && l.TarBytes <= 32<<30 &&
		l.FileBytes > 0 && l.FileBytes <= l.TarBytes && l.Entries > 0 && l.Entries <= 200_000 && l.TimeoutSeconds > 0 && l.TimeoutSeconds <= 900
}

type Result struct {
	Base    string `json:"base,omitempty"`
	SHA256  string `json:"sha256"`
	Bytes   int64  `json:"bytes"`
	Entries int    `json:"entries"`
}

// RestoreError requires a fresh machine for fallback when Dirty is true.
// A killed helper or missing/unparseable response is also potentially dirty;
// only an explicit Dirty=false error proves extraction never began.
type RestoreError struct {
	Dirty bool
	Err   error
}

func (e *RestoreError) Error() string { return e.Err.Error() }
func (e *RestoreError) Unwrap() error { return e.Err }

const magic = "MGLAYER1"

// Seal consumes a quiescent, explicitly prepared tar, validates it and publishes
// a new age-encrypted zstd artifact. It never overwrites an existing output.
// The caller generates a fresh X25519 identity per artifact, keeps its private
// identity wrapped under the tenant envelope key, and passes only its recipient.
func Seal(ctx context.Context, input, output, recipient string, binding Binding, limits Limits) (Result, error) {
	if !limits.valid() || !binding.valid() {
		return Result{}, ErrInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(limits.TimeoutSeconds)*time.Second)
	defer cancel()
	rec, err := age.ParseX25519Recipient(recipient)
	if err != nil {
		return Result{}, ErrInvalid
	}
	dir, err := os.MkdirTemp("", "managoat-layer-")
	if err != nil {
		return Result{}, ErrInvalid
	}
	defer os.RemoveAll(dir)
	// Copy once into private staging. The validation and encryption see exactly
	// the same bytes even if the caller replaces/mutates the input afterward.
	source, err := os.Open(input)
	if err != nil {
		return Result{}, ErrInvalid
	}
	defer source.Close()
	staged, err := os.CreateTemp(dir, "tar-")
	if err != nil {
		return Result{}, ErrInvalid
	}
	defer staged.Close()
	if _, err = copyBounded(ctx, staged, source, limits.TarBytes); err != nil {
		return Result{}, err
	}
	if _, err = staged.Seek(0, 0); err != nil {
		return Result{}, ErrInvalid
	}
	entries, err := validateTar(ctx, staged, limits)
	if err != nil {
		return Result{}, err
	}
	if _, err = staged.Seek(0, 0); err != nil {
		return Result{}, ErrInvalid
	}
	result, err := publish(output, func(dst io.Writer) error {
		bounded := &limitWriter{w: dst, left: limits.CipherBytes}
		encrypted, err := age.Encrypt(bounded, rec)
		if err != nil {
			return ErrInvalid
		}
		header, _ := json.Marshal(binding)
		var size [4]byte
		binary.BigEndian.PutUint32(size[:], uint32(len(header)))
		for _, part := range [][]byte{[]byte(magic), size[:], header} {
			if _, err = encrypted.Write(part); err != nil {
				return err
			}
		}
		compressed, err := zstd.NewWriter(encrypted, zstd.WithEncoderConcurrency(1), zstd.WithEncoderLevel(zstd.SpeedDefault))
		if err != nil {
			return ErrInvalid
		}
		_, copyErr := copyBounded(ctx, compressed, staged, limits.TarBytes)
		closeErr := compressed.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		return encrypted.Close()
	})
	result.Entries = entries
	return result, err
}

// Restore verifies the trusted ciphertext digest and reads age to authenticated
// EOF before parsing anything inside it. It validates the entire decompressed
// tar before writing the exclusively-owned destination. No tenant process may
// run concurrently there. Unsupported metadata fails closed, not silently lost.
func Restore(ctx context.Context, input, destination, identity, digest string, binding Binding, limits Limits) (Result, error) {
	dirty := false
	fail := func(err error) (Result, error) { return Result{}, &RestoreError{dirty, err} }
	if !limits.valid() || !binding.valid() {
		return fail(ErrInvalid)
	}
	expected, err := hex.DecodeString(digest)
	if err != nil || len(expected) != 32 {
		return fail(ErrInvalid)
	}
	id, err := age.ParseX25519Identity(identity)
	if err != nil {
		return fail(ErrInvalid)
	}
	ctx, cancel := context.WithTimeout(ctx, time.Duration(limits.TimeoutSeconds)*time.Second)
	defer cancel()
	dir, err := os.MkdirTemp("", "managoat-layer-")
	if err != nil {
		return fail(ErrInvalid)
	}
	defer os.RemoveAll(dir)
	source, err := os.Open(input)
	if err != nil {
		return fail(ErrInvalid)
	}
	defer source.Close()
	ciphertext, err := os.CreateTemp(dir, "cipher-")
	if err != nil {
		return fail(ErrInvalid)
	}
	defer ciphertext.Close()
	hash := sha256.New()
	size, err := copyBounded(ctx, io.MultiWriter(ciphertext, hash), source, limits.CipherBytes)
	if err != nil {
		return fail(err)
	}
	if !bytes.Equal(hash.Sum(nil), expected) {
		return fail(ErrAuthentication)
	}
	if _, err = ciphertext.Seek(0, 0); err != nil {
		return fail(ErrInvalid)
	}
	decrypted, err := age.Decrypt(ciphertext, id)
	if err != nil {
		return fail(ErrAuthentication)
	}
	plain, err := os.CreateTemp(dir, "plain-")
	if err != nil {
		return fail(ErrInvalid)
	}
	defer plain.Close()
	if _, err = copyBounded(ctx, plain, decrypted, limits.CipherBytes); err != nil {
		if errors.Is(err, ErrLimit) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return fail(err)
		}
		return fail(ErrAuthentication)
	}
	if _, err = plain.Seek(0, 0); err != nil {
		return fail(ErrInvalid)
	}
	_, err = checkBinding(plain, binding)
	if err != nil {
		return fail(err)
	}
	tarFile, err := os.CreateTemp(dir, "validated-")
	if err != nil {
		return fail(ErrInvalid)
	}
	defer tarFile.Close()
	decoder, err := zstd.NewReader(plain, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxMemory(64<<20))
	if err != nil {
		return fail(ErrArchive)
	}
	_, err = copyBounded(ctx, tarFile, decoder, limits.TarBytes)
	decoder.Close()
	if err != nil {
		return fail(err)
	}
	if _, err = tarFile.Seek(0, 0); err != nil {
		return fail(ErrInvalid)
	}
	entries, err := validateTar(ctx, tarFile, limits)
	if err != nil {
		return fail(err)
	}
	if _, err = tarFile.Seek(0, 0); err != nil {
		return fail(ErrInvalid)
	}
	root, err := os.OpenRoot(destination)
	if err != nil {
		return fail(ErrInvalid)
	}
	defer root.Close()
	if err = extractTar(ctx, root, tarFile, &dirty); err != nil {
		return fail(err)
	}
	return Result{SHA256: digest, Bytes: size, Entries: entries}, nil
}

func checkBinding(r io.Reader, expected Binding) (int64, error) {
	var head [12]byte
	if _, err := io.ReadFull(r, head[:]); err != nil || string(head[:8]) != magic {
		return 0, ErrInvalid
	}
	n := binary.BigEndian.Uint32(head[8:])
	if n == 0 || n > 16<<10 {
		return 0, ErrLimit
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return 0, ErrInvalid
	}
	// Exact canonical bytes exclude duplicate/unknown JSON fields and alternate
	// encodings as well as mismatched tenant/base/fingerprint metadata.
	canonical, _ := json.Marshal(expected)
	if !bytes.Equal(buf, canonical) {
		return 0, ErrBinding
	}
	return int64(12 + n), nil
}

func copyBounded(ctx context.Context, dst io.Writer, src io.Reader, max int64) (int64, error) {
	reader := &contextReader{ctx, io.LimitReader(src, max+1)}
	n, err := io.CopyBuffer(dst, reader, make([]byte, 64<<10))
	if n > max {
		return n, ErrLimit
	}
	return n, err
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.r.Read(p)
}

type limitWriter struct {
	w    io.Writer
	left int64
}

func (w *limitWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.left {
		return 0, ErrLimit
	}
	n, e := w.w.Write(p)
	w.left -= int64(n)
	return n, e
}

// Publish a complete file without an overwrite race; failed writes leave no
// destination. The temporary file and final artifact are owner-readable only.
func publish(destination string, write func(io.Writer) error) (Result, error) {
	parent := parentPath(destination)
	f, err := os.CreateTemp(parent, ".managoat-layer-")
	if err != nil {
		return Result{}, ErrInvalid
	}
	defer os.Remove(f.Name())
	defer f.Close()
	h := sha256.New()
	if err = write(io.MultiWriter(f, h)); err != nil {
		return Result{}, err
	}
	if err = f.Sync(); err != nil {
		return Result{}, ErrInvalid
	}
	info, err := f.Stat()
	if err != nil {
		return Result{}, ErrInvalid
	}
	if err = f.Close(); err != nil {
		return Result{}, ErrInvalid
	}
	if err = os.Link(f.Name(), destination); err != nil {
		return Result{}, ErrInvalid
	}
	return Result{SHA256: hex.EncodeToString(h.Sum(nil)), Bytes: info.Size()}, nil
}

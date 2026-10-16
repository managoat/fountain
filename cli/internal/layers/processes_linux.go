package layers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// A build script must stop its services before returning. New surviving
// processes refuse export; the trusted exec helper's ancestry is exempt.
func processes() (map[string]string, map[string]string, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, nil, ErrInvalid
	}
	starts, parents := map[string]string{}, map[string]string{}
	for _, entry := range entries {
		if _, err := strconv.Atoi(entry.Name()); err != nil {
			continue
		}
		data, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "stat"))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, nil, ErrInvalid
		}
		end := strings.LastIndex(string(data), ")")
		if end < 0 {
			return nil, nil, ErrInvalid
		}
		fields := strings.Fields(string(data[end+1:]))
		if len(fields) < 20 {
			return nil, nil, ErrInvalid
		}
		if fields[0] == "Z" {
			continue
		}
		starts[entry.Name()] = fields[19]
		parents[entry.Name()] = fields[1]
	}
	return starts, parents, nil
}
func ProcessSnapshot(output string) (Result, error) {
	starts, _, err := processes()
	if err != nil {
		return Result{}, err
	}
	return publish(output, func(w io.Writer) error { return json.NewEncoder(w).Encode(starts) })
}
func Quiescent(input, expected string) (Result, error) {
	file, err := os.Open(input)
	if err != nil {
		return Result{}, ErrInvalid
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
	if err != nil || len(data) > 1<<20 {
		return Result{}, ErrInvalid
	}
	hash := sha256.Sum256(data)
	if hex.EncodeToString(hash[:]) != expected {
		return Result{}, ErrBinding
	}
	var baseline map[string]string
	if json.Unmarshal(data, &baseline) != nil || len(baseline) == 0 {
		return Result{}, ErrInvalid
	}
	starts, parents, err := processes()
	if err != nil {
		return Result{}, err
	}
	for pid := strconv.Itoa(os.Getpid()); pid != "" && pid != "0"; pid = parents[pid] {
		delete(starts, pid)
	}
	for pid, start := range starts {
		if baseline[pid] != start {
			return Result{}, ErrArchive
		}
	}
	return Result{}, nil
}

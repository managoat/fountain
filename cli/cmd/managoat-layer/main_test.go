package main

import (
	"bytes"
	"context"
	"encoding/json"
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

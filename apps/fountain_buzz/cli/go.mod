// The Buzz remote-agents provider, owned by the extension rather than by
// Fountain core (ADR 0043 decision 6, #1508).
//
// A module of its own, and that is the point: Go's `internal/` rule is scoped
// to a module path, so this cannot reach into `cli/internal/...` even by
// accident. That is the same boundary `Fountain.ExtensionGuardTest` enforces on
// the Elixir side, enforced here by the compiler. What it may use is the
// public client the core CLI publishes — `cli/api`, `cli/credentials`.
//
// Apache-2.0, like `cli/` and unlike `apps/fountain_buzz`'s Elixir: ADR 0027
// licenses by artifact kind, not by repository, and an integrator writing
// against the Buzz API should carry no obligation.
//
// The `replace` below is what makes this buildable in-repo before graduation
// (#1510). On the day this directory moves to managoat/fountain_buzz it
// becomes a version pin and nothing else about the module changes.
module github.com/managoat/fountain/apps/fountain_buzz/cli

go 1.26.0

require (
	github.com/managoat/fountain/cli v0.0.0
	github.com/nbd-wtf/go-nostr v0.52.3
)

require (
	github.com/ImVexed/fasturl v0.0.0-20230304231329-4e41488060f3 // indirect
	github.com/btcsuite/btcd/btcec/v2 v2.3.4 // indirect
	github.com/btcsuite/btcd/btcutil v1.1.5 // indirect
	github.com/btcsuite/btcd/chaincfg/chainhash v1.1.0 // indirect
	github.com/bytedance/sonic v1.13.1 // indirect
	github.com/bytedance/sonic/loader v0.2.4 // indirect
	github.com/cloudwego/base64x v0.1.5 // indirect
	github.com/coder/websocket v1.8.15 // indirect
	github.com/decred/dcrd/crypto/blake256 v1.1.0 // indirect
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.4.0 // indirect
	github.com/josharian/intern v1.0.0 // indirect
	github.com/json-iterator/go v1.1.12 // indirect
	github.com/klauspost/cpuid/v2 v2.2.10 // indirect
	github.com/mailru/easyjson v0.9.0 // indirect
	github.com/modern-go/concurrent v0.0.0-20180306012644-bacd9c7ef1dd // indirect
	github.com/modern-go/reflect2 v1.0.2 // indirect
	github.com/puzpuzpuz/xsync/v3 v3.5.1 // indirect
	github.com/tidwall/gjson v1.18.0 // indirect
	github.com/tidwall/match v1.1.1 // indirect
	github.com/tidwall/pretty v1.2.1 // indirect
	github.com/twitchyliquid64/golang-asm v0.15.1 // indirect
	golang.org/x/arch v0.15.0 // indirect
	golang.org/x/exp v0.0.0-20250305212735-054e65f0b394 // indirect
	golang.org/x/sys v0.49.0 // indirect
)

replace github.com/managoat/fountain/cli => ../../../cli

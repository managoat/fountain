"""A small Fountain API client — stdlib only, so the plugin has no pip dependencies.

Credential resolution mirrors the `fountain` CLI (cli/internal/config):

  api_key:  plugin setting → FOUNTAIN_API_KEY → FOUNTAIN_TOKEN → ~/.fountain/credentials
  base_url: plugin setting → FOUNTAIN_BASE_URL → ~/.fountain/credentials → hosted default

`FOUNTAIN_TOKEN` is what a Fountain sandbox exports for the agent inside it, so a
Hermes running *in* a Fountain sandbox delegates with the conversation-scoped
token it already has, and the spawned conversations are attributed as children
of it via `X-Fountain-Parent-Conversation-Id` (`FOUNTAIN_CONVERSATION_ID`).
"""

from __future__ import annotations

import configparser
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_BASE_URL = "https://managoat.com"
USER_AGENT = "hermes-fountain-plugin/0.1.0"


class FountainError(Exception):
    """An API call failed. `status` is the HTTP status (0 for transport errors)."""

    def __init__(self, message: str, status: int = 0, body: Any = None):
        super().__init__(message)
        self.status = status
        self.body = body


def _credentials_path() -> Path:
    override = os.environ.get("FOUNTAIN_CREDENTIALS_FILE", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".fountain" / "credentials"


def _read_credentials(profile: str) -> dict[str, str]:
    path = _credentials_path()
    if not path.is_file():
        return {}
    parser = configparser.ConfigParser()
    try:
        parser.read(path)
    except configparser.Error:
        return {}
    if not parser.has_section(profile):
        return {}
    # `fountain auth login` writes values quoted (`api_key = "fk_…"`); tolerate both.
    return {k: _unquote(v) for k, v in parser.items(profile)}


def _unquote(value: str) -> str:
    v = (value or "").strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v.strip()


def resolve_settings(
    *,
    base_url: str = "",
    api_key: str = "",
    profile: str = "",
) -> tuple[str, str]:
    """Return `(base_url, api_key)`; `api_key` is "" when nothing is configured."""
    profile = profile or os.environ.get("FOUNTAIN_PROFILE", "").strip() or "default"
    creds: dict[str, str] | None = None

    key = (api_key or "").strip() or os.environ.get("FOUNTAIN_API_KEY", "").strip() or os.environ.get(
        "FOUNTAIN_TOKEN", ""
    ).strip()
    if not key:
        creds = _read_credentials(profile)
        key = creds.get("api_key", "")

    url = (base_url or "").strip() or os.environ.get("FOUNTAIN_BASE_URL", "").strip()
    if not url:
        if creds is None:
            creds = _read_credentials(profile)
        url = creds.get("base_url", "") or DEFAULT_BASE_URL

    return url.rstrip("/"), key


class FountainClient:
    def __init__(self, base_url: str, api_key: str, *, timeout: float = 30.0):
        if not api_key:
            raise FountainError(
                "No Fountain API key. Set FOUNTAIN_API_KEY, run `fountain auth login`, "
                "or set plugins.entries.fountain.settings.api_key in Hermes config."
            )
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout
        self.parent_conversation_id = os.environ.get("FOUNTAIN_CONVERSATION_ID", "").strip()

    # ── transport ──────────────────────────────────────────────────────────

    def request(self, method: str, path: str, *, params: dict | None = None, body: dict | None = None) -> Any:
        url = self.base_url + path
        if params:
            clean = {k: v for k, v in params.items() if v is not None and v != ""}
            if clean:
                url += "?" + urllib.parse.urlencode(clean)
        data = None
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self.parent_conversation_id:
            headers["X-Fountain-Parent-Conversation-Id"] = self.parent_conversation_id
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            parsed = _maybe_json(raw)
            raise FountainError(_describe_http_error(exc.code, parsed, url), status=exc.code, body=parsed) from None
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            raise FountainError(f"{method} {url} failed: {exc}") from None
        return _maybe_json(raw) if raw else None

    # ── agents ─────────────────────────────────────────────────────────────

    def list_agents(self, search: str | None = None) -> list[dict]:
        out = self.request("GET", "/api/agents", params={"search": search})
        return list((out or {}).get("data") or [])

    def resolve_agent(self, name_or_id: str) -> dict:
        """Find an agent by id, then by exact name (case-insensitive), then unique prefix."""
        wanted = (name_or_id or "").strip()
        if not wanted:
            raise FountainError("agent is required (a Fountain agent name or id)")
        agents = self.list_agents()
        for a in agents:
            if a.get("id") == wanted:
                return a
        exact = [a for a in agents if (a.get("name") or "").lower() == wanted.lower()]
        if len(exact) == 1:
            return exact[0]
        prefix = [a for a in agents if (a.get("name") or "").lower().startswith(wanted.lower())]
        if len(prefix) == 1:
            return prefix[0]
        names = ", ".join(sorted(a.get("name") or "?" for a in agents)) or "(none)"
        raise FountainError(f"No agent named {wanted!r}. Agents on this account: {names}")

    # ── conversations ──────────────────────────────────────────────────────

    def create_conversation(self, request: dict[str, Any]) -> dict:
        """Send an API-shaped body; tool argument/name translation belongs to the caller."""
        body = dict(request)
        out = self.request("POST", "/api/conversations", body=body)
        return (out or {}).get("data") or {}

    def get_conversation(self, conversation_id: str) -> dict:
        out = self.request("GET", f"/api/conversations/{conversation_id}")
        return (out or {}).get("data") or {}

    def list_conversations(self, roots_only: bool = True) -> list[dict]:
        out = self.request(
            "GET", "/api/conversations", params={"roots_only": "true" if roots_only else None}
        )
        return list((out or {}).get("data") or [])

    def list_turns(self, conversation_id: str) -> list[dict]:
        out = self.request("GET", f"/api/conversations/{conversation_id}/turns")
        return list((out or {}).get("data") or [])

    def send_prompt(self, conversation_id: str, prompt: str) -> dict:
        return self.request("POST", f"/api/conversations/{conversation_id}/prompts", body={"prompt": prompt}) or {}

    def interrupt(self, conversation_id: str) -> Any:
        return self.request("POST", f"/api/conversations/{conversation_id}/interrupt")

    def terminate(self, conversation_id: str) -> Any:
        return self.request("POST", f"/api/conversations/{conversation_id}/terminate")

    def events(self, conversation_id: str, *, after: int = 0, limit: int = 1000) -> tuple[list[dict], int | None, bool]:
        """One page of log events after `after`, with blocks. Returns (events, next_cursor, has_more)."""
        out = self.request(
            "GET",
            f"/api/conversations/{conversation_id}/events",
            params={"after": after, "limit": limit, "blocks": "true"},
        )
        out = out or {}
        meta = out.get("meta") or {}
        return list(out.get("data") or []), meta.get("next_cursor"), bool(meta.get("has_more"))

    def resolve_vault(self, name_or_id: str | None) -> str | None:
        return self._resolve_named("/api/vaults", "vault", name_or_id)

    def resolve_environment(self, name_or_id: str | None) -> str | None:
        return self._resolve_named("/api/environments", "environment", name_or_id)

    def _resolve_named(self, path: str, what: str, name_or_id: str | None) -> str | None:
        wanted = (name_or_id or "").strip()
        if not wanted:
            return None
        items = list((self.request("GET", path) or {}).get("data") or [])
        for it in items:
            if it.get("id") == wanted:
                return wanted
        exact = [it for it in items if (it.get("name") or "").lower() == wanted.lower()]
        if len(exact) == 1:
            return exact[0]["id"]
        names = ", ".join(sorted(it.get("name") or "?" for it in items)) or "(none)"
        raise FountainError(f"No {what} named {wanted!r}. Available: {names}")


def _maybe_json(raw: bytes) -> Any:
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return raw.decode("utf-8", "replace")


def _describe_http_error(status: int, parsed: Any, url: str) -> str:
    detail = ""
    if isinstance(parsed, dict):
        err = parsed.get("errors") or parsed.get("error") or parsed.get("message")
        if err:
            detail = err if isinstance(err, str) else json.dumps(err)
    elif isinstance(parsed, str) and parsed.strip():
        detail = parsed.strip()[:300]
    hints = {
        401: "unauthorized — check the API key",
        402: "payment required — the account has no active subscription",
        404: "not found — wrong id, or it belongs to another account",
        409: "conflict",
        422: "rejected",
        429: "rate limited — retry shortly",
    }
    hint = hints.get(status, "")
    parts = [f"HTTP {status}", hint, detail, f"({url})"]
    return " ".join(p for p in parts if p)

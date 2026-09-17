"""A resumable conversation handle."""

from typing import Any, Dict, Iterator, List, Optional, Union
from urllib.parse import quote

from .config import conversation_url
from .http import HttpClient
from .run import Run
from .sse import stream_events

# Distinguishes "not given" from an explicit None, which the reapply body
# needs: the first keeps a binding and the second clears it.
_UNSET = object()


class Conversation:
    def __init__(self, http: HttpClient, conversation_id: str, cursor: int = 0) -> None:
        self._http = http
        self.id = conversation_id
        self._cursor = cursor

    @property
    def url(self) -> str:
        return conversation_url(self.id, self._http.config)

    def get(self) -> Dict[str, Any]:
        return self._http.data("GET", "/api/conversations/%s" % self.id)

    def status(self) -> Optional[str]:
        value = self.get().get("status")
        return value if isinstance(value, str) else None

    def turns(self) -> List[Dict[str, Any]]:
        return self._http.list("/api/conversations/%s/turns" % self.id)

    def send(
        self,
        prompt: str,
        *,
        images: Optional[List[Dict[str, Any]]] = None,
        client_request_id: Optional[str] = None,
        timeout: Optional[float] = None,
        collect_events: bool = False,
    ) -> Run:
        """Send the next turn.

        ``client_request_id`` is your own name for this submission. It is
        carried to the turn the prompt opens and onto that turn's ``started``
        event (#1406), so a caller reads back which turn was its own rather
        than guessing from turn order. It is not an idempotency key: sending
        the same value twice opens two turns.
        """
        body: Dict[str, Any] = {"prompt": prompt}
        if images:
            body["images"] = images
        # Presence, not truthiness: an explicitly empty id is a 422 the caller
        # has to see, not a prompt that quietly runs uncorrelated.
        if client_request_id is not None:
            body["client_request_id"] = client_request_id

        def plan() -> Any:
            after = self.cursor()
            turn_number = self.last_turn_number() + 1
            self._http.request(
                "POST", "/api/conversations/%s/prompts" % self.id, body=body
            )
            return self.get(), turn_number, after

        run = Run(self._http, plan, timeout=timeout, collect_events=collect_events)

        def keep_cursor(finished: Run) -> None:
            self._cursor = max(self._cursor, finished.cursor)

        run._after_finish(keep_cursor)
        return run

    def answer(self, request_id: str, option_id: str) -> None:
        self._http.request(
            "POST",
            "/api/conversations/%s/requests/%s" % (self.id, quote(request_id, safe="")),
            body={"option_id": option_id},
        )

    def mark_read(self) -> None:
        self._http.request("POST", "/api/conversations/%s/read" % self.id)

    def history(
        self,
        *,
        streams: Optional[Union[List[str], str]] = None,
        after: int = 0,
        limit: int = 1000,
    ) -> List[Dict[str, Any]]:
        selected = ",".join(streams) if isinstance(streams, list) else streams
        output: List[Dict[str, Any]] = []
        cursor = after
        while True:
            page = self._http.request(
                "GET",
                "/api/conversations/%s/events" % self.id,
                query={
                    "after": cursor,
                    "limit": limit,
                    "blocks": "true",
                    "streams": selected,
                },
            )
            events = page.get("data", []) if isinstance(page, dict) else []
            output.extend(events)
            meta = page.get("meta", {}) if isinstance(page, dict) else {}
            next_cursor = meta.get("next_cursor")
            if not meta.get("has_more") or not isinstance(next_cursor, int):
                break
            cursor = next_cursor
        if output and isinstance(output[-1].get("id"), int):
            self._cursor = max(self._cursor, output[-1]["id"])
        return output

    def tree(self) -> Any:
        return self._http.data("GET", "/api/conversations/%s/tree" % self.id)

    def reapply(
        self,
        *,
        agent_id: Optional[str] = None,
        environment_id: Any = _UNSET,
        vault_id: Any = _UNSET,
    ) -> Dict[str, Any]:
        """Reapply this conversation's agent, environment and vault in place.

        The machine, the transcript and the files on disk all stay. An omitted
        value keeps its current selection; pass ``None`` for the environment or
        the vault to clear it. Calling with no arguments reapplies what is
        already selected.
        """
        body: Dict[str, Any] = {}
        if agent_id is not None:
            body["agent_id"] = agent_id
        if environment_id is not _UNSET:
            body["environment_id"] = environment_id
        if vault_id is not _UNSET:
            body["vault_id"] = vault_id
        return self._http.data(
            "POST", "/api/conversations/%s/reapply" % self.id, body=body
        )

    def interrupt(self) -> None:
        self._http.request("POST", "/api/conversations/%s/interrupt" % self.id)

    def terminate(self) -> None:
        self._http.request("POST", "/api/conversations/%s/terminate" % self.id)

    def delete(self) -> None:
        self._http.request("DELETE", "/api/conversations/%s" % self.id)

    def events(self, **options: Any) -> Iterator[Dict[str, Any]]:
        return stream_events(self._http, self.id, **options)

    def event_page(self, after: int = 0, limit: int = 1000) -> Dict[str, Any]:
        output = self._http.request(
            "GET",
            "/api/conversations/%s/events" % self.id,
            query={"after": after, "limit": limit, "blocks": "true"},
        )
        meta = output.get("meta", {}) if isinstance(output, dict) else {}
        return {
            "events": output.get("data", []) if isinstance(output, dict) else [],
            "next_cursor": meta.get("next_cursor")
            if isinstance(meta.get("next_cursor"), int)
            else after,
            "has_more": bool(meta.get("has_more")),
        }

    def last_turn_number(self) -> int:
        return max(
            (int(turn.get("turn_number") or 0) for turn in self.turns()), default=0
        )

    def cursor(self) -> int:
        if self._cursor > 0:
            return self._cursor
        last = 0
        try:
            for event in stream_events(
                self._http, self.id, streams="stage", wait=False, max_retries=0
            ):
                event_id = event.get("id")
                if isinstance(event_id, int):
                    last = max(last, event_id)
        except Exception:
            return 0
        self._cursor = last
        return last

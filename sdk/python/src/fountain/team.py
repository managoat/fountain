"""Durable teammates, their conversations, and their schedules."""

from typing import Any, Dict, Iterator, List, Optional, Union

from .conversation import Conversation
from .http import HttpClient
from .resolve import Resolver
from .run import Run
from .sse import stream_path


class Team:
    def __init__(self, http: HttpClient, resolver: Resolver) -> None:
        self._http = http
        self._resolver = resolver
        self.schedules = TeamSchedules(http, resolver)

    def list(self) -> List[Dict[str, Any]]:
        return self._http.list("/api/team")

    def get(self, agent: str) -> Dict[str, Any]:
        return self._http.data("GET", "/api/team/%s" % self._agent_id(agent))

    def add(self, agent: str, **options: Any) -> Dict[str, Any]:
        return self._http.data(
            "POST", "/api/team", body=dict(options, agent_id=self._agent_id(agent))
        )

    def remove(self, agent: str) -> None:
        self._http.request("DELETE", "/api/team/%s" % self._agent_id(agent))

    def rename(self, agent: str, name: Optional[str]) -> Dict[str, Any]:
        return self._http.data(
            "PATCH", "/api/team/%s" % self._agent_id(agent), body={"name": name}
        )

    def message(
        self,
        agent: str,
        prompt: str,
        *,
        images: Optional[List[Dict[str, Any]]] = None,
        timeout: Optional[float] = None,
        collect_events: bool = False,
    ) -> Run:
        body: Dict[str, Any] = {"prompt": prompt}
        if images:
            body["images"] = images

        def plan() -> Any:
            agent_id = self._agent_id(agent)
            try:
                before = self._http.data("GET", "/api/team/%s" % agent_id)
            except Exception:
                before = None
            existing = None
            if isinstance(before, dict) and isinstance(
                before.get("conversation"), dict
            ):
                existing = before["conversation"].get("id")
            after, turn_number = 0, 1
            if existing:
                handle = Conversation(self._http, str(existing))
                after = handle.cursor()
                turn_number = handle.last_turn_number() + 1
            sent = self._http.request(
                "POST", "/api/team/%s/messages" % agent_id, body=body
            )
            conversation_id = (
                sent.get("conversation_id") if isinstance(sent, dict) else None
            )
            conversation_id = conversation_id or existing
            if not conversation_id:
                raise RuntimeError(
                    "POST /api/team/%s/messages returned no conversation id" % agent_id
                )
            if conversation_id != existing:
                after, turn_number = 0, 1
            record = self._http.data("GET", "/api/conversations/%s" % conversation_id)
            return record, turn_number, after

        return Run(self._http, plan, timeout=timeout, collect_events=collect_events)

    def conversation(self, agent: str) -> Conversation:
        teammate = self.get(agent)
        value = teammate.get("conversation")
        conversation_id = value.get("id") if isinstance(value, dict) else None
        if not conversation_id:
            raise RuntimeError(
                "%s has no conversation yet — send it a message first" % agent
            )
        return Conversation(self._http, str(conversation_id))

    def history(self, agent: str) -> List[Dict[str, Any]]:
        return self._http.list("/api/team/%s/conversations" % self._agent_id(agent))

    def fresh_conversation(self, agent: str) -> Dict[str, Any]:
        return self._http.data(
            "POST", "/api/team/%s/conversations" % self._agent_id(agent)
        )

    def stream(
        self,
        *,
        streams: Optional[Union[List[str], str]] = None,
        **options: Any,
    ) -> Iterator[Dict[str, Any]]:
        selected = ",".join(streams) if isinstance(streams, list) else streams
        options.setdefault("blocks", True)
        return stream_path(self._http, "/api/team/stream", streams=selected, **options)

    def _agent_id(self, agent: str) -> str:
        return str(self._resolver.resolve("/api/agents", "agent", agent)["id"])


class TeamSchedules:
    def __init__(self, http: HttpClient, resolver: Resolver) -> None:
        self._http = http
        self._resolver = resolver

    def list(self, agent: Optional[str] = None) -> List[Dict[str, Any]]:
        path = (
            "/api/team/schedules"
            if not agent
            else "/api/team/%s/schedules" % self._agent_id(agent)
        )
        return self._http.list(path)

    def get(self, agent: str, schedule_id: str) -> Dict[str, Any]:
        return self._http.data("GET", self._path(agent, schedule_id))

    def create(self, agent: str, input: Dict[str, Any]) -> Dict[str, Any]:
        return self._http.data("POST", self._path(agent), body=input)

    def update(
        self, agent: str, schedule_id: str, patch: Dict[str, Any]
    ) -> Dict[str, Any]:
        return self._http.data("PATCH", self._path(agent, schedule_id), body=patch)

    def delete(self, agent: str, schedule_id: str) -> None:
        self._http.request("DELETE", self._path(agent, schedule_id))

    def run(self, agent: str, schedule_id: str) -> Any:
        return self._http.request("POST", self._path(agent, schedule_id) + "/run")

    def _path(self, agent: str, schedule_id: Optional[str] = None) -> str:
        base = "/api/team/%s/schedules" % self._agent_id(agent)
        return "%s/%s" % (base, schedule_id) if schedule_id else base

    def _agent_id(self, agent: str) -> str:
        return str(self._resolver.resolve("/api/agents", "agent", agent)["id"])

"""The public Fountain client."""

from typing import Any, Dict, Iterator, List, Mapping, Optional, Union, cast

from .config import ResolvedConfig, resolve_config
from .conversation import Conversation
from .http import HttpClient, Transport
from .resolve import Resolver
from .resources import Agents, Connections, Environments, Vaults
from .run import Run
from .sse import stream_path
from .team import Team


class Fountain:
    def __init__(
        self,
        *,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        profile: Optional[str] = None,
        app_url: Optional[str] = None,
        timeout: Optional[float] = 30.0,
        transport: Optional[Transport] = None,
    ) -> None:
        self.config: ResolvedConfig = resolve_config(
            api_key=api_key, base_url=base_url, profile=profile, app_url=app_url
        )
        self.api = HttpClient(self.config, timeout=timeout, transport=transport)
        self._resolver = Resolver(self.api)
        self.agents = Agents(self.api, self._resolver)
        self.environments = Environments(self.api, self._resolver)
        self.vaults = Vaults(self.api, self._resolver)
        self.team = Team(self.api, self._resolver)
        self.connections = Connections(self.api)

    def run(
        self,
        prompt: str,
        *,
        agent: str,
        vault: Optional[str] = None,
        environment: Optional[str] = None,
        title: Optional[str] = None,
        images: Optional[List[Dict[str, Any]]] = None,
        client_request_id: Optional[str] = None,
        channel_id: Optional[str] = None,
        fresh: bool = False,
        sprite_name: Optional[str] = None,
        sandbox: Optional[str] = None,
        sandbox_mode: Optional[str] = None,
        sandbox_api_access: Optional[str] = None,
        timeout: Optional[float] = None,
        collect_events: bool = False,
    ) -> Run:
        def plan() -> Any:
            selected_agent = self._resolver.resolve("/api/agents", "agent", agent)
            vault_id = self._resolver.resolve_id("/api/vaults", "vault", vault)
            environment_id = self._resolver.resolve_id(
                "/api/environments", "environment", environment
            )
            body: Dict[str, Any] = {"agent_id": selected_agent["id"]}
            optional = {
                "prompt": prompt or None,
                "vault_id": vault_id,
                "environment_id": environment_id,
                "title": title,
                "images": images or None,
                "client_request_id": client_request_id,
                "channel_id": channel_id,
                "fresh": True if fresh else None,
                "sprite_name": sprite_name,
                "sandbox_id": sandbox,
                "sandbox_mode": sandbox_mode,
                "sandbox_api_access": sandbox_api_access,
            }
            body.update(
                {key: value for key, value in optional.items() if value is not None}
            )
            return self._start_conversation(body)

        return Run(self.api, plan, timeout=timeout, collect_events=collect_events)

    def run_request(
        self,
        request: Mapping[str, Any],
        *,
        timeout: Optional[float] = None,
        collect_events: bool = False,
    ) -> Run:
        """Run an API-shaped launch using IDs and separate local options.

        Values pass through unchanged. Use ``request`` for promptless or
        queued creation, which cannot be followed by an immediate Run.
        """
        body = dict(request)
        prompt = body.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("run_request requires a non-empty prompt; use request for promptless creation")
        if body.get("queue") is not None and body["queue"] is not False:
            raise ValueError("run_request does not support queued creation; use request")

        return Run(
            self.api, lambda: self._start_conversation(body),
            timeout=timeout, collect_events=collect_events,
        )

    def _start_conversation(self, body: Dict[str, Any]) -> Any:
        response = self.api.request("POST", "/api/conversations", body=body)
        conversation = response["data"]
        if response.get("meta", {}).get("resumed") is True:
            # Resume binds the channel without submitting its prompt. Read
            # history before sending so a fast next turn cannot be skipped.
            conversation_id = str(conversation["id"])
            has_prompt = isinstance(body.get("prompt"), str) and bool(body["prompt"])
            after = self.resume(conversation_id).cursor() if has_prompt else 0
            turn_number = self._next_turn_number(conversation_id)
            # Every create field that belongs *with* the prompt has to be
            # repeated here: this second request is what opens the turn.
            prompt_body = {
                key: body[key]
                for key in ("prompt", "images", "client_request_id")
                if key in body
            }
            if has_prompt:
                self.api.request(
                    "POST", "/api/conversations/%s/prompts" % conversation_id,
                    body=prompt_body,
                )
            return conversation, turn_number, after
        return conversation, 1, 0

    def resume(self, conversation_id: str) -> Conversation:
        return Conversation(self.api, conversation_id)

    def conversations(self, *, roots_only: bool = True) -> List[Dict[str, Any]]:
        return self.api.list(
            "/api/conversations", query={"roots_only": "true" if roots_only else None}
        )

    def me(self) -> Dict[str, Any]:
        return cast(Dict[str, Any], self.api.request("GET", "/api/auth/me"))

    def catalog(self) -> Dict[str, Any]:
        return self.api.data("GET", "/api/catalog")

    def sandboxes(self, *, status: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        return self.api.list(
            "/api/sandboxes", query={"status": ",".join(status) if status else None}
        )

    def sandbox(self, sandbox_id: str) -> Dict[str, Any]:
        return self.api.data("GET", "/api/sandboxes/%s" % sandbox_id)

    def reset_sandbox(self, sandbox_id: str) -> None:
        self.api.request("DELETE", "/api/sandboxes/%s" % sandbox_id)

    def search(
        self, query: str, *, limit: Optional[int] = None
    ) -> List[Dict[str, Any]]:
        return self.api.list("/api/search", query={"q": query, "limit": limit})

    def events(
        self,
        *,
        streams: Optional[Union[List[str], str]] = None,
        **options: Any,
    ) -> Iterator[Dict[str, Any]]:
        selected = ",".join(streams) if isinstance(streams, list) else streams
        options.setdefault("blocks", True)
        return stream_path(self.api, "/api/events/stream", streams=selected, **options)

    def refresh(self) -> None:
        self._resolver.clear()

    def request(self, method: str, path: str, **options: Any) -> Any:
        return self.api.request(method, path, **options)

    def _next_turn_number(self, conversation_id: str) -> int:
        turns = self.api.list("/api/conversations/%s/turns" % conversation_id)
        return max((int(turn.get("turn_number") or 0) for turn in turns), default=0) + 1

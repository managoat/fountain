"""Bearer-authenticated JSON HTTP, with binary and streaming escape hatches."""

import json
import socket
from typing import Any, Callable, Dict, Mapping, Optional, Protocol, Union, cast
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin
from urllib.request import Request, urlopen

from .config import ResolvedConfig
from .errors import AuthError, ConnectionError, error_for_status

USER_AGENT = "fountain-sdk-python/0.2.1"


class Response(Protocol):
    headers: Mapping[str, str]
    status: int

    def read(self, amt: Optional[int] = None) -> bytes: ...
    def readline(self, limit: int = -1) -> bytes: ...
    def close(self) -> None: ...


Transport = Callable[[Request, Optional[float]], Response]
QueryValue = Union[str, int, float, bool, None]
_DEFAULT_TIMEOUT = object()


def _default_transport(request: Request, timeout: Optional[float]) -> Response:
    return cast(Response, urlopen(request, timeout=timeout))


class HttpClient:
    def __init__(
        self,
        config: ResolvedConfig,
        *,
        timeout: Optional[float] = 30.0,
        transport: Optional[Transport] = None,
    ) -> None:
        self.config = config
        self.default_timeout = timeout
        self._transport = transport or _default_transport

    @property
    def base_url(self) -> str:
        return self.config.base_url

    def url(self, path: str, query: Optional[Mapping[str, QueryValue]] = None) -> str:
        base = (
            path
            if path.startswith(("http://", "https://"))
            else urljoin(self.config.base_url + "/", path.lstrip("/"))
        )
        values = {
            key: str(value).lower() if isinstance(value, bool) else str(value)
            for key, value in (query or {}).items()
            if value not in (None, "")
        }
        return base + (
            ("&" if "?" in base else "?") + urlencode(values) if values else ""
        )

    def headers(self, extra: Optional[Mapping[str, str]] = None) -> Dict[str, str]:
        if not self.config.api_key:
            raise AuthError(
                "No Fountain API key. Pass api_key, set FOUNTAIN_API_KEY, or run `fountain auth login`."
            )
        headers = {
            "Authorization": "Bearer %s" % self.config.api_key,
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }
        if self.config.parent_conversation_id:
            headers["X-Fountain-Parent-Conversation-Id"] = (
                self.config.parent_conversation_id
            )
        if extra:
            headers.update(extra)
        return headers

    def raw(
        self,
        method: str,
        path: str,
        *,
        query: Optional[Mapping[str, QueryValue]] = None,
        body: Any = None,
        headers: Optional[Mapping[str, str]] = None,
        accept: Optional[str] = None,
        timeout: Any = _DEFAULT_TIMEOUT,
    ) -> Response:
        url = self.url(path, query)
        request_headers = self.headers(headers)
        if accept:
            request_headers["Accept"] = accept
        payload = None
        if body is not None:
            payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        request = Request(
            url, data=payload, headers=request_headers, method=method.upper()
        )
        request_timeout = (
            self.default_timeout if timeout is _DEFAULT_TIMEOUT else timeout
        )
        try:
            return self._transport(request, request_timeout)
        except HTTPError as error:
            raw = error.read()
            parsed = _decode_body(raw)
            raise error_for_status(
                error.code, parsed, method.upper(), url, dict(error.headers.items())
            ) from error
        except (URLError, OSError, socket.timeout) as error:
            raise ConnectionError(
                "%s %s failed: %s" % (method.upper(), url, error)
            ) from error

    def request(
        self,
        method: str,
        path: str,
        *,
        query: Optional[Mapping[str, QueryValue]] = None,
        body: Any = None,
        headers: Optional[Mapping[str, str]] = None,
        accept: Optional[str] = None,
        timeout: Any = _DEFAULT_TIMEOUT,
    ) -> Any:
        response = self.raw(
            method,
            path,
            query=query,
            body=body,
            headers=headers,
            accept=accept,
            timeout=timeout,
        )
        try:
            try:
                return _decode_body(response.read())
            except (OSError, ValueError) as error:
                raise ConnectionError(
                    "%s %s failed while reading the response: %s"
                    % (method.upper(), self.url(path, query), error)
                ) from error
        finally:
            response.close()

    def data(self, method: str, path: str, **kwargs: Any) -> Dict[str, Any]:
        output = self.request(method, path, **kwargs)
        value = output.get("data") if isinstance(output, dict) else None
        return value if isinstance(value, dict) else {}

    def list(self, path: str, **kwargs: Any) -> list[Any]:
        output = self.request("GET", path, **kwargs)
        value = output.get("data") if isinstance(output, dict) else None
        return value if isinstance(value, list) else []


def _decode_body(raw: bytes) -> Any:
    if not raw:
        return None
    text = raw.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text

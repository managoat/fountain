"""Failures, keyed the way callers branch on them."""

import json
from typing import Any, Dict, Mapping, Optional, Type

_RETRYABLE_CODES = {
    "conversation_busy",
    "provisioning",
    "sprite_probe_failed",
    "sandbox_quota_exceeded",
    "sandbox_at_capacity",
    "rate_limited",
}


class FountainError(Exception):
    def __init__(
        self,
        message: str,
        *,
        status: int = 0,
        code: Optional[str] = None,
        body: Any = None,
        retry_after: Optional[float] = None,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.body = body
        self.retry_after = retry_after

    @property
    def retryable(self) -> bool:
        return (
            self.code in _RETRYABLE_CODES
            or self.status == 429
            or 500 <= self.status < 600
        )

    @property
    def field_errors(self) -> Dict[str, list[str]]:
        if not isinstance(self.body, dict) or not isinstance(
            self.body.get("errors"), dict
        ):
            return {}
        output: Dict[str, list[str]] = {}
        for field, value in self.body["errors"].items():
            if isinstance(value, str):
                output[str(field)] = [value]
            elif isinstance(value, list):
                output[str(field)] = [item for item in value if isinstance(item, str)]
        return output


class AuthError(FountainError):
    pass


class SubscriptionRequiredError(FountainError):
    @property
    def upgrade_url(self) -> Optional[str]:
        value = self.body.get("upgrade_url") if isinstance(self.body, dict) else None
        return value if isinstance(value, str) else None


class NotFoundError(FountainError):
    pass


class ValidationError(FountainError):
    pass


class RateLimitError(FountainError):
    pass


class ConversationBusyError(FountainError):
    pass


class NotReadyError(FountainError):
    pass


class QuotaExceededError(FountainError):
    @property
    def active_sandboxes(self) -> Optional[int]:
        value = (
            self.body.get("active_sandboxes") if isinstance(self.body, dict) else None
        )
        return value if isinstance(value, int) else None

    @property
    def limit(self) -> Optional[int]:
        value = self.body.get("limit") if isinstance(self.body, dict) else None
        return value if isinstance(value, int) else None


class ConnectionError(FountainError):
    pass


class ResolutionError(FountainError):
    pass


class TimeoutError(FountainError):
    def __init__(self, message: str, conversation_id: str, partial_text: str) -> None:
        super().__init__(message)
        self.conversation_id = conversation_id
        self.partial_text = partial_text


_HINTS = {
    400: "bad request",
    401: "unauthorized — check the API key",
    402: "payment required — the account is out of credit",
    403: "forbidden — the key may lack the scope for this call",
    404: "not found — wrong id, or it belongs to another account",
    409: "conflict",
    422: "rejected",
    429: "rate limited",
    503: "temporarily unavailable",
}


def error_for_status(
    status: int,
    body: Any,
    method: str,
    url: str,
    headers: Optional[Mapping[str, str]] = None,
) -> FountainError:
    code = (
        body.get("error")
        if isinstance(body, dict) and isinstance(body.get("error"), str)
        else None
    )
    detail = ""
    if isinstance(body, dict):
        value = body.get("message", body.get("error", body.get("errors")))
        if isinstance(value, str):
            detail = value
        elif value is not None:
            detail = json.dumps(value, separators=(",", ":"))
    elif isinstance(body, str):
        detail = body.strip()[:300]

    retry_after: Optional[float] = None
    if headers:
        raw_retry = headers.get("Retry-After") or headers.get("retry-after")
        try:
            retry_after = float(raw_retry) if raw_retry else None
        except ValueError:
            pass

    message = " ".join(
        part
        for part in [
            "HTTP %s" % status,
            _HINTS.get(status, ""),
            detail,
            "(%s %s)" % (method, url),
        ]
        if part
    )
    by_code: Dict[str, Type[FountainError]] = {
        "conversation_busy": ConversationBusyError,
        "provisioning": NotReadyError,
        "sprite_probe_failed": NotReadyError,
        "sandbox_unavailable": NotReadyError,
        "fleet_full": NotReadyError,
        "sandbox_quota_exceeded": QuotaExceededError,
        "subscription_required": SubscriptionRequiredError,
        "insufficient_credits": SubscriptionRequiredError,
    }
    by_status: Dict[int, Type[FountainError]] = {
        401: AuthError,
        402: SubscriptionRequiredError,
        404: NotFoundError,
        422: ValidationError,
        429: RateLimitError,
    }
    error_type = by_code.get(code or "", by_status.get(status, FountainError))
    return error_type(
        message, status=status, code=code, body=body, retry_after=retry_after
    )

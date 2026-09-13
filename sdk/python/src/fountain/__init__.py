"""The Fountain Python SDK."""

from .client import Fountain
from .config import (
    DEFAULT_APP_URL,
    DEFAULT_BASE_URL,
    ResolvedConfig,
    conversation_url,
    parse_credentials,
    resolve_config,
)
from .conversation import Conversation
from .errors import (
    AuthError,
    ConnectionError,
    ConversationBusyError,
    FountainError,
    NotFoundError,
    NotReadyError,
    QuotaExceededError,
    RateLimitError,
    ResolutionError,
    SubscriptionRequiredError,
    TimeoutError,
    ValidationError,
    error_for_status,
)
from .http import USER_AGENT, HttpClient
from .resources import Agents, ConnectionProviders, Connections, Environments, Vaults
from .run import Run
from .sse import parse_sse, stream_events, stream_path
from .team import Team, TeamSchedules
from .turn import TurnFollower
from .types import RunResult

__all__ = [
    "AuthError",
    "Agents",
    "ConnectionProviders",
    "Connections",
    "ConnectionError",
    "Conversation",
    "ConversationBusyError",
    "DEFAULT_APP_URL",
    "DEFAULT_BASE_URL",
    "Fountain",
    "FountainError",
    "HttpClient",
    "Environments",
    "NotFoundError",
    "NotReadyError",
    "QuotaExceededError",
    "RateLimitError",
    "ResolvedConfig",
    "ResolutionError",
    "Run",
    "RunResult",
    "SubscriptionRequiredError",
    "TimeoutError",
    "Team",
    "TeamSchedules",
    "TurnFollower",
    "USER_AGENT",
    "ValidationError",
    "Vaults",
    "conversation_url",
    "error_for_status",
    "parse_credentials",
    "parse_sse",
    "resolve_config",
    "stream_events",
    "stream_path",
]

__version__ = "0.2.1"

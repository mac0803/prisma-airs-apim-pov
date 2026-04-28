from collections.abc import AsyncGenerator, Awaitable
from dataclasses import asdict
from typing import Any, Optional, cast

from openai import AsyncOpenAI, AsyncStream, PermissionDeniedError
from openai.types.responses import (
    EasyInputMessageParam,
    Response,
    ResponseCompletedEvent,
    ResponseStreamEvent,
    ResponseTextDeltaEvent,
)

from approaches.approach import Approach, DataPoints, ExtraInfo
from approaches.promptmanager import PromptManager


class AIRSBlockedError(Exception):
    """Raised when Prisma AIRS blocks a request."""

    def __init__(self, category: str, details: dict):
        self.category = category
        self.details = details
        super().__init__(f"PRISMA AIRS SECURITY ALERT — blocked: {category}")


def _raise_if_apim_airs_block(error: Exception) -> None:
    """Re-raise a PermissionDeniedError from APIM as AIRSBlockedError if it's an AIRS block.

    The OpenAI SDK sets body to the string value of the 'error' key, so we check body directly.
    The full response dict (including 'details') lives in error.message as a repr'd Python literal.
    """
    if not (isinstance(error, PermissionDeniedError) and isinstance(error.body, str) and "PRISMA AIRS" in error.body):
        return
    details: dict = {}
    category = "policy violation"
    try:
        import ast
        msg = getattr(error, "message", "")
        # message format: "Error code: 403 - {'error': '...', 'details': {...}}"
        if " - " in msg:
            parsed = ast.literal_eval(msg.split(" - ", 1)[1])
            if isinstance(parsed, dict):
                details = parsed.get("details", {})
                category = next(iter(details), "policy violation")
    except Exception:
        pass
    raise AIRSBlockedError(category=category, details=details) from error


class DirectChatApproach(Approach):
    """Direct GPT chat through APIM + Prisma AIRS gateway — used when Azure AI Search is not configured."""

    def __init__(
        self,
        openai_client: AsyncOpenAI,
        chatgpt_model: str,
        chatgpt_deployment: Optional[str],
        prompt_manager: PromptManager,
        reasoning_effort: Optional[str] = None,
    ):
        self.openai_client = openai_client
        self.chatgpt_model = chatgpt_model
        self.chatgpt_deployment = chatgpt_deployment
        self.prompt_manager = prompt_manager
        self.reasoning_effort = reasoning_effort
        self.include_token_usage = True

    async def run(
        self,
        messages: list[EasyInputMessageParam],
        session_state: Any = None,
        context: dict[str, Any] = {},
    ) -> dict[str, Any]:
        overrides = context.get("overrides", {})
        try:
            response: Response = await cast(
                Awaitable[Response],
                self.create_response(
                    self.chatgpt_deployment,
                    self.chatgpt_model,
                    messages,
                    overrides,
                    self.get_response_token_limit(self.chatgpt_model, self.RESPONSE_DEFAULT_TOKEN_LIMIT),
                    should_stream=False,
                ),
            )
        except Exception as e:
            _raise_if_apim_airs_block(e)
            raise
        extra_info = ExtraInfo(data_points=DataPoints())
        return {
            "output_text": response.output_text,
            "context": {
                "thoughts": extra_info.thoughts,
                "data_points": {k: v for k, v in asdict(extra_info.data_points).items() if v is not None},
                "followup_questions": extra_info.followup_questions,
            },
            "session_state": session_state,
        }

    async def run_stream(
        self,
        messages: list[EasyInputMessageParam],
        session_state: Any = None,
        context: dict[str, Any] = {},
    ) -> AsyncGenerator[dict[str, Any], None]:
        overrides = context.get("overrides", {})
        return self.run_with_streaming(messages, overrides, session_state)

    async def run_with_streaming(
        self,
        messages: list[EasyInputMessageParam],
        overrides: dict[str, Any],
        session_state: Any = None,
    ) -> AsyncGenerator[dict[str, Any], None]:
        extra_info = ExtraInfo(data_points=DataPoints())
        yield {"type": "response.context", "context": extra_info, "session_state": session_state}

        try:
            result = await cast(
                Awaitable[AsyncStream[ResponseStreamEvent]],
                self.create_response(
                    self.chatgpt_deployment,
                    self.chatgpt_model,
                    messages,
                    overrides,
                    self.get_response_token_limit(self.chatgpt_model, self.RESPONSE_DEFAULT_TOKEN_LIMIT),
                    should_stream=True,
                ),
            )
        except Exception as e:
            _raise_if_apim_airs_block(e)
            raise

        async for event in result:
            if isinstance(event, ResponseTextDeltaEvent):
                yield {"type": "response.output_text.delta", "delta": event.delta or ""}
            elif isinstance(event, ResponseCompletedEvent):
                if event.response.usage and self.include_token_usage and extra_info.thoughts:
                    extra_info.thoughts[-1].update_token_usage(event.response.usage)
                yield {"type": "response.context", "context": extra_info, "session_state": session_state}

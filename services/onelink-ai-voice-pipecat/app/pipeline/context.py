"""Validated OneLink voice context used to build a Pipecat session."""

from __future__ import annotations

from copy import deepcopy
from typing import Any, Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.clients.onelink import Correlation


class ContextModel(BaseModel):
    model_config = ConfigDict(extra="allow")


class AiSettings(ContextModel):
    provider: Literal["gemini-live", "openai-realtime", "elevenlabs", "cartesia"] = (
        "gemini-live"
    )
    model: str = Field(min_length=1, max_length=200)
    voice: str = Field(min_length=1, max_length=100)
    language: str = Field(default="ru-KZ", min_length=2, max_length=20)
    system_prompt: str = Field(min_length=1, max_length=100_000)
    first_message: str | None = Field(default=None, max_length=2_000)
    closing_message: str | None = Field(default=None, max_length=2_000)
    max_duration_sec: int = Field(default=900, ge=1, le=14_400)
    temperature: float = Field(default=0.3, ge=0, le=2)
    max_output_tokens: int = Field(default=1_024, ge=1, le=65_536)
    interruptions_enabled: bool = True
    clear_audio_on_interrupt: bool = True
    speech_start_sensitivity: str = "START_SENSITIVITY_HIGH"
    speech_end_sensitivity: str = "END_SENSITIVITY_HIGH"
    prefix_padding_ms: int = Field(default=120, ge=0, le=5_000)
    silence_duration_ms: int = Field(default=300, ge=0, le=10_000)
    silence_prompt_enabled: bool = True
    silence_prompt_after_ms: int = Field(default=2_500, ge=100, le=3_600_000)
    second_silence_prompt_after_ms: int = Field(default=6_500, ge=100, le=3_600_000)
    max_silence_ms: int = Field(default=18_000, ge=100, le=3_600_000)
    end_call_on_silence_enabled: bool = True
    silence_prompt: str = "Вы ещё на линии?"
    second_silence_prompt: str = "Подскажите, вы ещё на линии?"
    final_silence_message: str = "Похоже, сейчас неудобно говорить. Я завершу звонок."
    tool_foreground_wait_ms: int = Field(default=900, ge=0, le=120_000)
    tool_start_phrases: list[str] = Field(default_factory=lambda: ["Секунду, проверю."])
    tool_start_after_ms: int = Field(default=1_800, ge=0, le=120_000)
    tool_delay_phrases: list[str] = Field(default_factory=lambda: ["Ещё смотрю, почти готово."])
    tool_delay_after_ms: int = Field(default=1_800, ge=0, le=120_000)
    tool_failure_phrases: list[str] = Field(
        default_factory=lambda: [
            "Не получилось проверить автоматически. Могу соединить со специалистом."
        ]
    )
    post_tool_continuation_ms: int = Field(default=4_000, ge=100, le=120_000)


class ToolDefinition(ContextModel):
    name: str = Field(min_length=1, max_length=120)
    description: str = Field(default="", max_length=4_000)
    timeout_ms: int = Field(default=1_000, ge=100, le=120_000)
    foreground_wait_ms: int | None = Field(default=None, ge=100, le=120_000)
    enabled: Literal[True] = True
    parameters: dict[str, Any] = Field(default_factory=lambda: {"type": "object", "properties": {}})


class RecordingSettings(ContextModel):
    enabled: bool = True
    source: str = "onelink_runtime"
    storage_provider: str = "onelink_storage"


class VoiceContext(ContextModel):
    call_ref: str = Field(min_length=1, max_length=200)
    account_id: str | int
    conversation_id: str | int | None = None
    call_session_id: str | int | None = None
    contact_id: str | int | None = None
    inbox_id: str | int | None = None
    provider: str | None = None
    direction: str | None = None
    ai: AiSettings
    tools: list[ToolDefinition] = Field(default_factory=list)
    recording: RecordingSettings = Field(default_factory=RecordingSettings)
    runtime_engine: Literal["pipecat"] = "pipecat"
    runtime_session_id: str = Field(default_factory=lambda: str(uuid4()))
    raw: dict[str, Any] = Field(default_factory=dict, exclude=True)

    @model_validator(mode="before")
    @classmethod
    def preserve_raw_contract(cls, value: Any) -> Any:
        if not isinstance(value, dict):
            return value
        normalized = deepcopy(value)
        normalized["raw"] = deepcopy(value)
        return normalized

    @property
    def correlation(self) -> Correlation:
        return Correlation(
            call_ref=self.call_ref,
            runtime_session_id=self.runtime_session_id,
            account_id=self.account_id,
            conversation_id=self.conversation_id,
            call_session_id=self.call_session_id,
            inbox_id=self.inbox_id,
        )

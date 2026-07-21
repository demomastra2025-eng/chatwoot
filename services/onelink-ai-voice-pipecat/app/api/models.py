"""Validated forms of the existing OneLink attach contracts."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import (
    AnyHttpUrl,
    AnyWebsocketUrl,
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    model_validator,
)


class ContractModel(BaseModel):
    """Preserve forward-compatible legacy keys while validating runtime-critical fields."""

    model_config = ConfigDict(extra="allow")


class RuntimeStream(ContractModel):
    runtime_session_id: str = Field(min_length=1, max_length=200)
    stream_url: AnyWebsocketUrl
    stream_token: SecretStr | None = None
    codec: Literal["pcm_s16le"] = "pcm_s16le"
    input_sample_rate: Literal[16_000] = 16_000
    output_sample_rate: Literal[8_000] = 8_000

    @model_validator(mode="after")
    def validate_capability_transport(self) -> RuntimeStream:
        if self.stream_url.query:
            raise ValueError("runtime stream_url must not contain query parameters")
        if self.stream_token is None or not self.stream_token.get_secret_value().strip():
            raise ValueError("runtime stream_token is required")
        return self


class RuntimeControl(ContractModel):
    control_url: AnyHttpUrl
    token: SecretStr = Field(min_length=20, max_length=500, repr=False)


class Routing(ContractModel):
    action: str = Field(min_length=1, max_length=80)
    reason: str | None = Field(default=None, max_length=200)


class SipProfile(ContractModel):
    id: str | int | None = None
    profile_kind: str | None = None
    voice_agent: bool = False


class JanusAttachRequest(ContractModel):
    call_ref: str | None = Field(default=None, max_length=200)
    account_id: str | int | None = None
    inbox_id: str | int | None = None
    conversation_id: str | int | None = None
    call_session_id: str | int | None = None
    provider: str | None = Field(default=None, max_length=80)
    transport: str = "janus_sip"
    sip_profile: SipProfile
    runtime_stream: RuntimeStream
    runtime_control: RuntimeControl | None = Field(default=None, repr=False)
    routing: Routing
    janus: dict[str, Any] = Field(default_factory=dict)


class JanusPreflightRequest(ContractModel):
    call_ref: str | None = Field(default=None, max_length=200)
    account_id: str | int | None = None
    inbox_id: str | int | None = None
    conversation_id: str | int | None = None
    call_session_id: str | int | None = None
    provider: str | None = Field(default=None, max_length=80)
    transport: str = "janus_sip"
    sip_profile: SipProfile
    routing: Routing
    janus: dict[str, Any] = Field(default_factory=dict)


class WhatsappAttachRequest(ContractModel):
    call_ref: str | None = Field(default=None, max_length=200)
    account_id: str | int | None = None
    inbox_id: str | int | None = None
    conversation_id: str | int | None = None
    whatsapp_call_id: str | int | None = None
    call_session_id: str | int | None = None
    provider_call_id: str | None = Field(default=None, max_length=200)
    media_session_id: str | None = Field(default=None, max_length=200)
    runtime_stream: RuntimeStream
    runtime_control: RuntimeControl | None = Field(default=None, repr=False)
    routing: Routing

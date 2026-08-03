"""Build the selected Pipecat voice worker from validated OneLink context."""

from __future__ import annotations

import logging
from dataclasses import dataclass

from google.genai.types import ProactivityConfig, ThinkingConfig
from pipecat.adapters.schemas.function_schema import FunctionSchema
from pipecat.adapters.schemas.tools_schema import ToolsSchema
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import (
    InputAudioRawFrame,
    InputTextRawFrame,
    LLMMessagesAppendFrame,
    TTSAudioRawFrame,
    TTSSpeakFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    AssistantTurnStoppedMessage,
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
    UserTurnMessageAddedMessage,
)
from pipecat.services.cartesia.stt import CartesiaSTTService
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.elevenlabs.stt import CommitStrategy, ElevenLabsRealtimeSTTService
from pipecat.services.elevenlabs.tts import ElevenLabsTTSService
from pipecat.services.google.gemini_live.llm import (
    ContextWindowCompressionParams,
    GeminiVADParams,
    HttpOptions,
)
from pipecat.services.llm_service import FunctionCallParams
from pipecat.services.openai.realtime.events import (
    AudioConfiguration,
    AudioInput,
    AudioOutput,
    InputAudioNoiseReduction,
    InputAudioTranscription,
    ResponseCreateEvent,
    ResponseProperties,
    SessionProperties,
)
from pipecat.services.openai.realtime.llm import OpenAIRealtimeLLMService
from pipecat.services.openrouter.llm import OpenRouterLLMService
from pipecat.services.tts_service import TextAggregationMode
from pipecat.transcriptions.language import Language
from pipecat.transports.base_transport import BaseTransport
from pipecat.turns.user_stop.speech_timeout_user_turn_stop_strategy import (
    SpeechTimeoutUserTurnStopStrategy,
)
from pipecat.turns.user_turn_strategies import UserTurnStrategies

from app.api.models import RuntimeStream
from app.config import Settings
from app.media.transport import create_media_transport
from app.pipeline.context import AiSettings, ToolDefinition, VoiceContext
from app.pipeline.processors import (
    AssistantLifecycleProcessor,
    AudioResampleProcessor,
    CallerCommandProcessor,
    ConversationActivity,
    InputRecordingProcessor,
    TurnLifecycleProcessor,
)
from app.pipeline.tool_dialogue import ToolDialogueCoordinator
from app.pipeline.turn_strategies import ConfirmedUserTurnStartStrategy
from app.recordings.writer import DualChannelRecorder
from app.services.fish_asr import FishAudioASRService
from app.services.fish_tts import OneLinkFishAudioTTSService
from app.services.gemini_live import OneLinkGeminiLiveLLMService, OneLinkInternalTextFrame
from app.sessions.state import SessionState

logger = logging.getLogger(__name__)

GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION = (
    "Вызывай нужный инструмент сразу, без обещаний и задержки. Если результат инструмента "
    "имеет status=pending, ничего не произноси и не вызывай инструмент повторно: runtime сам "
    "озвучит ход выполнения. После фактического результата сразу дай клиенту один короткий "
    "содержательный ответ или понятное сообщение об ошибке."
)
CRM_MUTATION_TOOL_NAMES = frozenset(
    {"add_contact_note", "create_contact", "create_deal", "create_note", "update_deal"}
)
CRM_DATA_INTEGRITY_INSTRUCTION = (
    "Правила записи данных в CRM для текущего голосового звонка: не вызывай инструменты "
    "изменения контакта, заметки или сделки, пока клиент не закончил диктовать данные. "
    "Телефон считай полным только с кодом страны; повтори весь номер клиенту и дождись "
    "явного подтверждения. Не угадывай цифры и не смешивай продиктованный номер с caller ID. "
    "В title, description и заметках указывай фактический источник, приведённый ниже; не "
    "подставляй Telegram, WhatsApp или другой канал по шаблону. Не сообщай об успешной записи "
    "до успешного результата инструмента. Фактический источник: {source}."
)
GEMINI_AFFECTIVE_DIALOG_MODELS = frozenset(
    {"gemini-2.5-flash-native-audio-preview-12-2025"}
)
GEMINI_AUTO_LANGUAGE_MODELS = frozenset(
    {
        "gemini-3.1-flash-live-preview",
        "gemini-2.5-flash-native-audio-preview-12-2025",
    }
)
GEMINI_THINKING_LEVEL_MODELS = frozenset({"gemini-3.1-flash-live-preview"})
GEMINI_PROACTIVE_AUDIO_MODELS = frozenset(
    {"gemini-2.5-flash-native-audio-preview-12-2025"}
)
@dataclass(slots=True)
class PipelineAssembly:
    worker: PipelineWorker
    transport: BaseTransport
    llm: object
    provider: str
    activity: ConversationActivity
    vad: SileroVADAnalyzer
    tool_dialogue: ToolDialogueCoordinator
    start_on_connect: bool = False
    stt: object | None = None
    tts: object | None = None
    input_resampler: AudioResampleProcessor | None = None
    output_resampler: AudioResampleProcessor | None = None

    async def speak_exact(self, message: str) -> bool:
        instruction = (
            "Произнеси сейчас только следующую фразу естественно, без пояснений и "
            f"добавлений: {message}"
        )
        async with self.activity.speech_lock:
            started_sequence = self.activity.turns_started
            completed_sequence = self.activity.turns_completed
            if self.provider in {"elevenlabs", "cartesia", "fish"} and isinstance(
                self.tts,
                (ElevenLabsTTSService, CartesiaTTSService, OneLinkFishAudioTTSService),
            ):
                await self.tts.queue_frame(TTSSpeakFrame(message, append_to_context=False))
            elif self.provider == "openai-realtime" and isinstance(
                self.llm, OpenAIRealtimeLLMService
            ):
                await self.llm.send_client_event(
                    ResponseCreateEvent(
                        response=ResponseProperties(
                            output_modalities=["audio"],
                            instructions=instruction,
                            tools=[],
                            tool_choice="none",
                        )
                    )
                )
            else:
                frame_type = (
                    OneLinkInternalTextFrame
                    if self.provider == "gemini-live"
                    else InputTextRawFrame
                )
                await self.worker.queue_frame(frame_type(text=instruction))
            started = await self.activity.wait_for_turn_started_after(started_sequence, 1.5)
            if not started:
                return False
            completion_timeout = min(300.0, max(8.0, len(message) / 7.0 + 5.0))
            return await self.activity.wait_for_turn_completed_after(
                completed_sequence, completion_timeout
            )

    async def run_instruction(self, instruction: str) -> None:
        if self.provider == "openai-realtime" and isinstance(self.llm, OpenAIRealtimeLLMService):
            await self.llm.send_client_event(
                ResponseCreateEvent(
                    response=ResponseProperties(
                        output_modalities=["audio"],
                        instructions=instruction,
                    )
                )
            )
        elif self.provider == "gemini-live":
            await self.worker.queue_frame(OneLinkInternalTextFrame(text=instruction))
        else:
            await self.worker.queue_frame(
                LLMMessagesAppendFrame(
                    messages=[{"role": "user", "content": instruction}],
                    run_llm=True,
                )
            )


def build_pipeline(
    *,
    context: VoiceContext,
    state: SessionState,
    recorder: DualChannelRecorder | None,
    runtime_stream: RuntimeStream | None,
    settings: Settings,
    transport_override: BaseTransport | None = None,
) -> PipelineAssembly:
    activity = ConversationActivity()
    tool_dialogue = ToolDialogueCoordinator(ai=context.ai, state=state, activity=activity)
    tools = _build_tools(context, tool_dialogue)
    end_call_definition = next((tool for tool in context.tools if tool.name == "end_call"), None)
    initial_messages = [{"role": "user", "content": _initial_turn(context)}]
    vad = SileroVADAnalyzer(
        sample_rate=16_000,
        params=VADParams(
            confidence=context.ai.vad_confidence,
            start_secs=max(0.05, context.ai.prefix_padding_ms / 1_000),
            stop_secs=max(0.1, context.ai.silence_duration_ms / 1_000),
            min_volume=context.ai.vad_min_volume,
        ),
    )
    if transport_override is not None:
        transport = transport_override
    else:
        if runtime_stream is None:
            raise ValueError("runtime_stream or transport_override is required")
        transport = create_media_transport(
            runtime_stream,
            clear_audio_on_interrupt=context.ai.clear_audio_on_interrupt,
        )
    credentials = settings.provider_credentials(
        context.ai.provider, stt_provider=context.ai.stt_provider
    )
    stt = None
    tts = None
    input_resampler = None
    output_resampler = None
    caller_command: CallerCommandProcessor | None = None

    if context.ai.provider == "gemini-live":
        affective_dialog_enabled = (
            context.ai.affective_dialog_enabled
            and context.ai.model in GEMINI_AFFECTIVE_DIALOG_MODELS
        )
        proactive_audio_enabled = (
            context.ai.proactive_audio_enabled
            and context.ai.model in GEMINI_PROACTIVE_AUDIO_MODELS
        )
        llm_context = LLMContext(messages=initial_messages)
        aggregators = _aggregators(
            llm_context,
            state,
            activity,
            vad,
            ai=context.ai,
        )
        llm = OneLinkGeminiLiveLLMService(
            api_key=credentials["gemini_api_key"],
            tools=tools,
            input_language_priorities=context.ai.input_language_priorities,
            http_options=HttpOptions(
                api_version="v1alpha"
                if proactive_audio_enabled or affective_dialog_enabled
                else "v1beta"
            ),
            settings=OneLinkGeminiLiveLLMService.Settings(
                model=context.ai.model,
                system_instruction=_provider_system_prompt(context),
                voice=context.ai.voice,
                language=_gemini_language(context),
                temperature=context.ai.temperature,
                max_tokens=context.ai.max_output_tokens,
                vad=_gemini_vad_params(context),
                context_window_compression=ContextWindowCompressionParams(
                    enabled=context.ai.context_window_compression_enabled
                ),
                thinking=(
                    ThinkingConfig(thinking_level=context.ai.thinking_level)
                    if context.ai.model in GEMINI_THINKING_LEVEL_MODELS
                    else None
                ),
                enable_affective_dialog=affective_dialog_enabled,
                proactivity=(
                    ProactivityConfig(proactive_audio=True)
                    if proactive_audio_enabled
                    else None
                ),
            ),
            inference_on_context_initialization=True,
        )
        processors = [
            transport.input(),
            InputRecordingProcessor(recorder),
            aggregators.user(),
            TurnLifecycleProcessor(state, activity),
        ]
        if end_call_definition is not None:
            caller_command = CallerCommandProcessor(
                state,
                end_call_timeout_ms=end_call_definition.timeout_ms,
            )
            processors.append(caller_command)
        processors.extend(
            [
                llm,
                AssistantLifecycleProcessor(state, activity, recorder),
                transport.output(),
                aggregators.assistant(),
            ]
        )
        start_on_connect = True
    elif context.ai.provider == "openai-realtime":
        llm_context = LLMContext(messages=initial_messages, tools=tools)
        aggregators = _aggregators(
            llm_context,
            state,
            activity,
            vad,
            ai=context.ai,
        )
        llm = OpenAIRealtimeLLMService(
            api_key=credentials["openai_api_key"],
            settings=OpenAIRealtimeLLMService.Settings(
                model=context.ai.model,
                system_instruction=context.ai.system_prompt,
                temperature=context.ai.temperature,
                max_tokens=context.ai.max_output_tokens,
                session_properties=SessionProperties(
                    output_modalities=["audio"],
                    max_output_tokens=context.ai.max_output_tokens,
                    audio=AudioConfiguration(
                        input=AudioInput(
                            transcription=InputAudioTranscription(
                                language=context.ai.language.split("-", 1)[0].lower()
                            ),
                            turn_detection=False,
                            noise_reduction=InputAudioNoiseReduction(type="near_field"),
                        ),
                        output=AudioOutput(voice=context.ai.voice),
                    ),
                ),
            ),
        )
        input_resampler = AudioResampleProcessor(InputAudioRawFrame, 24_000)
        output_resampler = AudioResampleProcessor(TTSAudioRawFrame, 8_000)
        processors = [
            transport.input(),
            InputRecordingProcessor(recorder),
            aggregators.user(),
            TurnLifecycleProcessor(state, activity),
            input_resampler,
            llm,
            output_resampler,
            AssistantLifecycleProcessor(state, activity, recorder),
            transport.output(),
            aggregators.assistant(),
        ]
        start_on_connect = True
    else:
        llm_context = LLMContext(messages=initial_messages, tools=tools)
        aggregators = _aggregators(
            llm_context,
            state,
            activity,
            vad,
            ai=context.ai,
            realtime_service_mode=False,
        )
        language = _provider_language(context.ai.language)
        if context.ai.provider == "cartesia":
            stt = CartesiaSTTService(
                api_key=credentials["cartesia_api_key"],
                sample_rate=16_000,
                settings=CartesiaSTTService.Settings(
                    model=settings.cartesia_stt_model,
                    language=language,
                ),
            )
        elif context.ai.provider == "fish" and context.ai.stt_provider == "fish":
            stt = FishAudioASRService(
                api_key=credentials["fish_api_key"],
                sample_rate=16_000,
                request_timeout_seconds=settings.fish_asr_timeout_seconds,
                max_segment_seconds=settings.fish_asr_max_segment_seconds,
                settings=FishAudioASRService.Settings(
                    language=language,
                    ignore_timestamps=True,
                ),
            )
        else:
            stt = ElevenLabsRealtimeSTTService(
                api_key=credentials["elevenlabs_api_key"],
                sample_rate=16_000,
                commit_strategy=(
                    CommitStrategy.MANUAL
                    if context.ai.provider == "fish"
                    else CommitStrategy.VAD
                ),
                settings=ElevenLabsRealtimeSTTService.Settings(
                    model=settings.elevenlabs_stt_model,
                    language=language,
                ),
            )
        openrouter_settings = {
            "model": context.ai.model,
            "system_instruction": context.ai.system_prompt,
            "max_tokens": context.ai.max_output_tokens,
            "extra": {
                "extra_body": {
                    "provider": {
                        "sort": "latency",
                        "allow_fallbacks": True,
                        "require_parameters": True,
                        "data_collection": "deny",
                    }
                }
            },
        }
        if not context.ai.model.startswith("openai/gpt-5"):
            openrouter_settings["temperature"] = context.ai.temperature
        llm = OpenRouterLLMService(
            api_key=credentials["openrouter_api_key"],
            settings=OpenRouterLLMService.Settings(**openrouter_settings),
        )
        if context.ai.provider == "cartesia":
            tts = CartesiaTTSService(
                api_key=credentials["cartesia_api_key"],
                sample_rate=8_000,
                settings=CartesiaTTSService.Settings(
                    model=settings.cartesia_tts_model,
                    voice=context.ai.voice,
                    language=language,
                ),
            )
        elif context.ai.provider == "fish":
            tts = OneLinkFishAudioTTSService(
                api_key=credentials["fish_api_key"],
                sample_rate=8_000,
                text_aggregation_mode=TextAggregationMode.SENTENCE,
                settings=OneLinkFishAudioTTSService.Settings(
                    model=settings.fish_tts_model,
                    voice=context.ai.voice,
                    language=language,
                    latency=settings.fish_tts_latency,
                ),
            )
        else:
            tts = ElevenLabsTTSService(
                api_key=credentials["elevenlabs_api_key"],
                sample_rate=8_000,
                settings=ElevenLabsTTSService.Settings(
                    model=settings.elevenlabs_tts_model,
                    voice=context.ai.voice,
                    language=language,
                ),
            )
        processors = [
            transport.input(),
            InputRecordingProcessor(recorder),
            stt,
            aggregators.user(),
            TurnLifecycleProcessor(state, activity),
            llm,
            tts,
            AssistantLifecycleProcessor(state, activity, recorder),
            transport.output(),
            aggregators.assistant(),
        ]
        start_on_connect = True

    pipeline = Pipeline(processors)
    worker = PipelineWorker(
        pipeline,
        conversation_id=str(context.conversation_id or context.call_ref),
        enable_rtvi=False,
        idle_timeout_secs=None,
        params=PipelineParams(
            audio_in_sample_rate=16_000,
            audio_out_sample_rate=8_000,
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
    )
    assembly = PipelineAssembly(
        worker=worker,
        transport=transport,
        llm=llm,
        provider=context.ai.provider,
        activity=activity,
        vad=vad,
        tool_dialogue=tool_dialogue,
        start_on_connect=start_on_connect,
        stt=stt,
        tts=tts,
        input_resampler=input_resampler,
        output_resampler=output_resampler,
    )
    tool_dialogue.bind(
        speak_exact=assembly.speak_exact,
        run_instruction=assembly.run_instruction,
    )
    if caller_command is not None:
        caller_command.bind_end_call(tool_dialogue.execute_end_call)
    return assembly


def _aggregators(
    llm_context: LLMContext,
    state: SessionState,
    activity: ConversationActivity,
    vad: SileroVADAnalyzer,
    *,
    ai: AiSettings,
    realtime_service_mode: bool = True,
) -> LLMContextAggregatorPair:
    aggregators = LLMContextAggregatorPair(
        llm_context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=vad,
            user_turn_stop_timeout=ai.user_turn_stop_timeout_ms / 1_000,
            user_turn_strategies=_user_turn_strategies(ai),
        ),
        realtime_service_mode=realtime_service_mode,
    )
    _register_transcript_handlers(aggregators, state, activity)
    return aggregators


def _user_turn_strategies(ai: AiSettings) -> UserTurnStrategies:
    return UserTurnStrategies(
        start=[
            ConfirmedUserTurnStartStrategy(
                mode=ai.interruption_mode,
                min_words=ai.min_interrupt_words,
                confirmation_window_seconds=ai.interruption_confirmation_window_ms / 1_000,
                enable_interruptions=ai.interruptions_enabled,
            )
        ],
        stop=[
            SpeechTimeoutUserTurnStopStrategy(
                user_speech_timeout=ai.turn_aggregation_delay_ms / 1_000,
            )
        ],
    )


_JSON_SCHEMA_TYPES = {"array", "boolean", "integer", "number", "object", "string"}


def _property_schema_error(schema: object, path: str) -> str | None:
    if not isinstance(schema, dict):
        return f"{path} must be an object"

    schema_type = schema.get("type")
    if schema_type not in _JSON_SCHEMA_TYPES:
        return f"{path}.type is invalid"

    if schema_type == "array":
        if "items" not in schema:
            return f"{path}.items is missing"
        return _property_schema_error(schema["items"], f"{path}.items")

    if schema_type != "object":
        return None

    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        return f"{path}.properties must be an object"
    for name, property_schema in properties.items():
        if not isinstance(name, str) or not name:
            return f"{path}.properties contains an invalid name"
        error = _property_schema_error(property_schema, f"{path}.properties.{name}")
        if error:
            return error

    required = schema.get("required", [])
    if not isinstance(required, list) or not all(isinstance(name, str) for name in required):
        return f"{path}.required must be an array of strings"
    if set(required) - set(properties):
        return f"{path}.required references unknown properties"
    return None


def _tool_schema_error(tool: ToolDefinition) -> str | None:
    parameters = tool.parameters
    if parameters.get("type", "object") != "object":
        return "parameters.type must be object"
    return _property_schema_error(
        {
            "type": "object",
            "properties": parameters.get("properties", {}),
            "required": parameters.get("required", []),
        },
        "parameters",
    )


def _build_tools(
    context: VoiceContext,
    tool_dialogue: ToolDialogueCoordinator,
) -> ToolsSchema:
    schemas: list[FunctionSchema] = []
    for tool in context.tools:
        schema_error = _tool_schema_error(tool)
        if schema_error:
            logger.error(
                "realtime_tool_schema_dropped tool=%s reason=%s", tool.name, schema_error
            )
            continue
        parameters = tool.parameters if isinstance(tool.parameters, dict) else {}
        properties = parameters.get("properties")
        required = parameters.get("required")
        schemas.append(
            FunctionSchema(
                name=tool.name,
                description=tool.description,
                properties=properties if isinstance(properties, dict) else {},
                required=[str(name) for name in required] if isinstance(required, list) else [],
                handler=_tool_handler(tool_dialogue, tool),
            )
        )
    return ToolsSchema(standard_tools=schemas)


def _register_transcript_handlers(
    aggregators: LLMContextAggregatorPair,
    state: SessionState,
    activity: ConversationActivity,
) -> None:
    @aggregators.user().event_handler("on_user_turn_message_added")
    async def on_user_turn_message_added(
        _aggregator: object,
        message: UserTurnMessageAddedMessage,
    ) -> None:
        text = _message_text(message.content)
        if text:
            await state.add_transcript("caller", text, final=True)
            state.spawn(state.flush_transcript())

    @aggregators.assistant().event_handler("on_assistant_turn_stopped")
    async def on_assistant_turn_stopped(
        _aggregator: object,
        message: AssistantTurnStoppedMessage,
    ) -> None:
        text = _message_text(message.content)
        if text and message.interrupted:
            state.spawn(
                state.safe_event(
                    "assistant_transcript_suppressed",
                    {
                        "reason": "interrupted",
                        "content_chars": len(text),
                    },
                )
            )
            return
        if text:
            await state.add_transcript("ai", text, final=True)
            state.spawn(state.flush_transcript())


def _tool_handler(tool_dialogue: ToolDialogueCoordinator, definition: ToolDefinition):
    async def handler(params: FunctionCallParams) -> None:
        await tool_dialogue.execute(definition, params)

    handler.__name__ = f"onelink_tool_{definition.name}"
    return handler


def _initial_turn(context: VoiceContext) -> str:
    if context.ai.first_message:
        return (
            "Начни разговор сейчас. Скажи это приветствие естественно, без пояснений и "
            f"без добавления нового содержания: {context.ai.first_message}"
        )
    return "Начни разговор с абонентом сейчас согласно системным инструкциям."


def _provider_system_prompt(context: VoiceContext) -> str:
    instructions = [context.ai.system_prompt]
    tool_names = {tool.name.strip().lower() for tool in context.tools}
    if tool_names & CRM_MUTATION_TOOL_NAMES:
        instructions.append(
            CRM_DATA_INTEGRITY_INSTRUCTION.format(source=_voice_crm_source(context))
        )
    if context.ai.provider == "gemini-live" and context.tools:
        instructions.append(GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION)
    return "\n\n".join(instructions)


def _voice_crm_source(context: VoiceContext) -> str:
    provider = str(context.provider or "").strip().lower()
    call_ref = context.call_ref.strip().lower()
    if "whatsapp" in provider or call_ref.startswith("whatsapp:"):
        return "голосовой звонок WhatsApp"
    if "telegram" in provider or call_ref.startswith("telegram:"):
        return "голосовой звонок Telegram"
    return "телефонный звонок"


def _gemini_language(context: VoiceContext) -> str | None:
    if context.ai.language != "auto":
        return context.ai.language
    if context.ai.model in GEMINI_AUTO_LANGUAGE_MODELS:
        return None
    return "ru-KZ"


def _gemini_vad_params(context: VoiceContext) -> GeminiVADParams:
    # The local Silero analyzer already owns turn detection and interruptions.
    # Enabling Gemini's server VAD as well makes analog echo/noise cancel the
    # assistant before Silero has confirmed a caller turn.
    return GeminiVADParams(disabled=True)


def _provider_language(value: str) -> Language | None:
    try:
        return Language(value.split("-", 1)[0].lower())
    except ValueError:
        return None


def _message_text(content: object) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict) and isinstance(item.get("text"), str):
            parts.append(item["text"])
    return " ".join(part.strip() for part in parts if part.strip())

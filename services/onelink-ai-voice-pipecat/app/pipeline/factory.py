"""Build the selected Pipecat voice worker from validated OneLink context."""

from __future__ import annotations

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
from pipecat.transcriptions.language import Language
from pipecat.transports.base_transport import BaseTransport
from pipecat.turns.user_start.transcription_user_turn_start_strategy import (
    TranscriptionUserTurnStartStrategy,
)
from pipecat.turns.user_start.vad_user_turn_start_strategy import VADUserTurnStartStrategy
from pipecat.turns.user_turn_strategies import UserTurnStrategies

from app.api.models import RuntimeStream
from app.config import Settings
from app.media.transport import create_media_transport
from app.pipeline.context import ToolDefinition, VoiceContext
from app.pipeline.processors import (
    AssistantLifecycleProcessor,
    AudioResampleProcessor,
    ConversationActivity,
    InputRecordingProcessor,
    TurnLifecycleProcessor,
)
from app.pipeline.tool_dialogue import ToolDialogueCoordinator
from app.recordings.writer import DualChannelRecorder
from app.services.gemini_live import OneLinkGeminiLiveLLMService
from app.sessions.state import SessionState

GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION = (
    "Перед вызовом любого инструмента, кроме перевода звонка или завершения разговора, "
    "сначала коротко скажи собеседнику, что сейчас проверишь информацию. Затем сразу "
    "вызови инструмент и обязательно дождись его результата перед содержательным ответом."
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
GEMINI_PROACTIVE_AUDIO_MODELS = GEMINI_AUTO_LANGUAGE_MODELS
GEMINI_START_SENSITIVITIES = frozenset(
    {"START_SENSITIVITY_HIGH", "START_SENSITIVITY_LOW"}
)
GEMINI_END_SENSITIVITIES = frozenset({"END_SENSITIVITY_HIGH", "END_SENSITIVITY_LOW"})


@dataclass(slots=True)
class PipelineAssembly:
    worker: PipelineWorker
    transport: BaseTransport
    llm: object
    provider: str
    activity: ConversationActivity
    vad: SileroVADAnalyzer
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
            if self.provider in {"elevenlabs", "cartesia"} and isinstance(
                self.tts, (ElevenLabsTTSService, CartesiaTTSService)
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
                await self.worker.queue_frame(InputTextRawFrame(text=instruction))
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
            await self.worker.queue_frame(InputTextRawFrame(text=instruction))
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
        transport = create_media_transport(runtime_stream)
    credentials = settings.provider_credentials(context.ai.provider)
    stt = None
    tts = None
    input_resampler = None
    output_resampler = None

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
            vad,
            interruptions_enabled=context.ai.interruptions_enabled,
        )
        llm = OneLinkGeminiLiveLLMService(
            api_key=credentials["gemini_api_key"],
            tools=tools,
            http_options=HttpOptions(
                api_version="v1alpha" if proactive_audio_enabled else "v1beta"
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
            llm,
            AssistantLifecycleProcessor(state, activity, recorder),
            transport.output(),
            aggregators.assistant(),
        ]
        start_on_connect = True
    elif context.ai.provider == "openai-realtime":
        llm_context = LLMContext(messages=initial_messages, tools=tools)
        aggregators = _aggregators(
            llm_context,
            state,
            vad,
            interruptions_enabled=context.ai.interruptions_enabled,
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
            vad,
            interruptions_enabled=context.ai.interruptions_enabled,
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
        else:
            stt = ElevenLabsRealtimeSTTService(
                api_key=credentials["elevenlabs_api_key"],
                sample_rate=16_000,
                commit_strategy=CommitStrategy.VAD,
                settings=ElevenLabsRealtimeSTTService.Settings(
                    model=settings.elevenlabs_stt_model,
                    language=language,
                ),
            )
        llm = OpenRouterLLMService(
            api_key=credentials["openrouter_api_key"],
            settings=OpenRouterLLMService.Settings(
                model=context.ai.model,
                system_instruction=context.ai.system_prompt,
                temperature=context.ai.temperature,
                max_tokens=context.ai.max_output_tokens,
            ),
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
    return assembly


def _aggregators(
    llm_context: LLMContext,
    state: SessionState,
    vad: SileroVADAnalyzer,
    *,
    interruptions_enabled: bool,
    realtime_service_mode: bool = True,
) -> LLMContextAggregatorPair:
    aggregators = LLMContextAggregatorPair(
        llm_context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=vad,
            user_turn_strategies=_user_turn_strategies(interruptions_enabled),
        ),
        realtime_service_mode=realtime_service_mode,
    )
    _register_transcript_handlers(aggregators, state)
    return aggregators


def _user_turn_strategies(interruptions_enabled: bool) -> UserTurnStrategies:
    return UserTurnStrategies(
        start=[
            VADUserTurnStartStrategy(enable_interruptions=interruptions_enabled),
            TranscriptionUserTurnStartStrategy(enable_interruptions=interruptions_enabled),
        ]
    )


def _build_tools(
    context: VoiceContext,
    tool_dialogue: ToolDialogueCoordinator,
) -> ToolsSchema:
    schemas: list[FunctionSchema] = []
    for tool in context.tools:
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
    if context.ai.provider != "gemini-live" or not context.tools:
        return context.ai.system_prompt
    return f"{context.ai.system_prompt}\n\n{GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION}"


def _gemini_language(context: VoiceContext) -> str | None:
    if context.ai.language != "auto":
        return context.ai.language
    if context.ai.model in GEMINI_AUTO_LANGUAGE_MODELS:
        return None
    return "ru-KZ"


def _gemini_vad_params(context: VoiceContext) -> GeminiVADParams:
    if not context.ai.interruptions_enabled:
        return GeminiVADParams(disabled=True)

    start_sensitivity = context.ai.speech_start_sensitivity
    end_sensitivity = context.ai.speech_end_sensitivity
    if start_sensitivity not in GEMINI_START_SENSITIVITIES:
        start_sensitivity = "START_SENSITIVITY_LOW"
    if end_sensitivity not in GEMINI_END_SENSITIVITIES:
        end_sensitivity = "END_SENSITIVITY_HIGH"

    return GeminiVADParams(
        disabled=False,
        start_sensitivity=start_sensitivity,
        end_sensitivity=end_sensitivity,
        prefix_padding_ms=context.ai.prefix_padding_ms,
        silence_duration_ms=context.ai.silence_duration_ms,
    )


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

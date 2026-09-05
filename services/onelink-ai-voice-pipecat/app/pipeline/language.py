"""Language control for cascaded STT -> LLM -> TTS pipelines."""

from __future__ import annotations

import re
from dataclasses import dataclass

from loguru import logger
from pipecat.frames.frames import (
    Frame,
    InterimTranscriptionFrame,
    LLMUpdateSettingsFrame,
    TranscriptionFrame,
    TTSUpdateSettingsFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.services.llm_service import LLMService
from pipecat.services.settings import LLMSettings, TTSSettings
from pipecat.services.tts_service import TTSService
from pipecat.transcriptions.language import Language

_LANGUAGE_NAMES = {
    "en": "английском языке",
    "kk": "казахском языке",
    "ru": "русском языке",
}
_EXPLICIT_LANGUAGE_REQUESTS = {
    "en": (
        re.compile(r"\bin\s+english\b", re.IGNORECASE),
        re.compile(r"\b(?:на|по)\s+английск(?:ом|и)\b", re.IGNORECASE),
    ),
    "kk": (
        re.compile(r"\bқазақша\b", re.IGNORECASE),
        re.compile(r"\bқазақ\s+тілінде\b", re.IGNORECASE),
        re.compile(r"\b(?:на|по)\s+казахск(?:ом|и)\b", re.IGNORECASE),
    ),
    "ru": (
        re.compile(r"\bпо[-\s]?русски\b", re.IGNORECASE),
        re.compile(r"\bна\s+русском\b", re.IGNORECASE),
        re.compile(r"\bрусск(?:ий|ом)\s+язык(?:е)?\b", re.IGNORECASE),
    ),
}


def _normalize_language_code(value: object) -> str | None:
    raw = getattr(value, "value", value)
    if not isinstance(raw, str):
        return None
    parts = [part for part in raw.strip().replace("_", "-").split("-") if part]
    if not parts or parts[0].lower() == "auto":
        return None
    normalized = [parts[0].lower()]
    normalized.extend(part.upper() if len(part) == 2 else part for part in parts[1:])
    return "-".join(normalized)


def _base_language(value: object) -> str | None:
    code = _normalize_language_code(value)
    return code.split("-", 1)[0] if code else None


def _explicit_requested_language(text: str) -> str | None:
    for language, patterns in _EXPLICIT_LANGUAGE_REQUESTS.items():
        if any(pattern.search(text) for pattern in patterns):
            return language
    return None


def _is_substantive(text: str) -> bool:
    return len(re.findall(r"\w+", text, flags=re.UNICODE)) >= 4


@dataclass
class CascadeLanguageState:
    """Keep one authoritative output language for an automatic-language call."""

    configured_language: str
    allowed_codes: tuple[str, ...]
    active_code: str
    _candidate_base: str | None = None
    _candidate_hits: int = 0

    @classmethod
    def from_settings(cls, configured_language: str, priorities: list[str]) -> CascadeLanguageState:
        configured = _normalize_language_code(configured_language)
        allowed = tuple(
            dict.fromkeys(
                code
                for value in ([configured_language] if configured else priorities)
                if (code := _normalize_language_code(value)) is not None
            )
        )
        if not allowed:
            allowed = ("ru-KZ",)
        return cls(
            configured_language=configured_language,
            allowed_codes=allowed,
            active_code=configured or allowed[0],
        )

    @property
    def automatic(self) -> bool:
        return self.configured_language.strip().lower() == "auto"

    @property
    def active_base(self) -> str:
        return _base_language(self.active_code) or self.active_code.lower()

    @property
    def tts_language(self) -> Language | None:
        try:
            return Language(self.active_base)
        except ValueError:
            return None

    def system_instruction(self, base_instruction: str) -> str:
        language_name = _LANGUAGE_NAMES.get(self.active_base, self.active_code)
        related_language_guard = (
            " Не используй кыргызский язык: он не входит в разрешённые языки звонка."
            if self.active_base == "kk"
            else ""
        )
        lock = (
            f"Активный язык ответа: {language_name} ({self.active_code}). "
            f"Отвечай строго только на {language_name}. "
            "Не определяй язык ответа заново по похожим словам из транскрипции и не "
            "переключайся на другой язык без обновления активного языка runtime."
            f"{related_language_guard}"
        )
        return f"{base_instruction.rstrip()}\n\n{lock}"

    def observe(self, language: object, text: str) -> str | None:
        """Return a new active code when a final STT turn proves a language switch."""
        if not self.automatic:
            return None

        explicit_base = _explicit_requested_language(text)
        if explicit_base:
            return self._activate(self._allowed_code(explicit_base))

        detected_base = _base_language(language)
        detected_code = self._allowed_code(detected_base)
        if detected_code is None:
            self._reset_candidate()
            return None
        if detected_base == self.active_base:
            self._reset_candidate()
            return None
        if _is_substantive(text):
            return self._activate(detected_code)

        if self._candidate_base == detected_base:
            self._candidate_hits += 1
        else:
            self._candidate_base = detected_base
            self._candidate_hits = 1
        if self._candidate_hits >= 2:
            return self._activate(detected_code)
        return None

    def _allowed_code(self, base: str | None) -> str | None:
        if base is None:
            return None
        return next((code for code in self.allowed_codes if _base_language(code) == base), None)

    def _activate(self, code: str | None) -> str | None:
        self._reset_candidate()
        if code is None or code == self.active_code:
            return None
        self.active_code = code
        return code

    def _reset_candidate(self) -> None:
        self._candidate_base = None
        self._candidate_hits = 0


class CascadeLanguageStateProcessor(FrameProcessor):
    """Propagate STT language decisions to the cascaded LLM and TTS services."""

    def __init__(
        self,
        *,
        state: CascadeLanguageState,
        base_system_instruction: str,
        llm: LLMService,
        tts: TTSService,
    ) -> None:
        super().__init__()
        self.state = state
        self._base_system_instruction = base_system_instruction
        self._llm = llm
        self._tts = tts

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        is_final_transcript = (
            direction == FrameDirection.DOWNSTREAM
            and isinstance(frame, TranscriptionFrame)
            and not isinstance(frame, InterimTranscriptionFrame)
        )
        if is_final_transcript:
            previous = self.state.active_code
            active_code = self.state.observe(frame.language, frame.text)
            if active_code is not None:
                logger.info(
                    "Cascade language switched previous={} active={}",
                    previous,
                    active_code,
                )
                await self.push_frame(
                    LLMUpdateSettingsFrame(
                        delta=LLMSettings(
                            system_instruction=self.state.system_instruction(
                                self._base_system_instruction
                            )
                        ),
                        service=self._llm,
                    ),
                    direction,
                )
                tts_language = self.state.tts_language
                if tts_language is not None:
                    await self.push_frame(
                        TTSUpdateSettingsFrame(
                            delta=TTSSettings(language=tts_language),
                            service=self._tts,
                        ),
                        direction,
                    )
        await self.push_frame(frame, direction)

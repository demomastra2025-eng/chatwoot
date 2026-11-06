"""Private local batch ASR. Importing this module never initializes native models.

Only decoder API/chunk ideas derive from frozen VoiceCore e1885f8b (307-443).
No clinical rules, profiles, cached utterances or original engine are imported.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import importlib.metadata
import ipaddress
import json
import math
import multiprocessing
import os
from pathlib import Path
import re
import signal
import socket
from socketserver import ThreadingMixIn
import stat
import subprocess
import tempfile
import threading
import time
import unicodedata
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer

REQUEST_SCHEMA = "onelink.voicecore.request.v1"
RESPONSE_SCHEMA = "onelink.voicecore.response.v1"
MANIFEST_SCHEMA = "onelink.voicecore.models.v1"
MAX_BODY = 16 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_AUDIO = 100 * 1024 * 1024
MAX_DURATION = 1800
MAX_TEXT = 500_000
DEADLINE = 110
TOOL_TIMEOUT = 20
INPUT_DEADLINE = 10
GIGA = "sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16"
SENSE = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
VOSK = "vosk-model-kz-0.42"
DEMAND = {f"{d}/{f}" for d in (GIGA, SENSE) for f in ("model.int8.onnx", "tokens.txt")}
VOSK_FILES = (
    "README", "am/final.mdl", "ivector/splice.conf", "ivector/final.dubm",
    "ivector/final.ie", "ivector/online_cmvn.conf", "ivector/global_cmvn.stats",
    "ivector/final.mat", "graph/phones.txt", "graph/words.txt", "graph/num_pdfs",
    "graph/HCLG.fst", "graph/disambig_tid.int", "conf/model.conf", "conf/mfcc.conf",
    "rescore/G.fst", "rescore/G.carpa", "graph/phones/word_boundary.txt",
    "graph/phones/word_boundary.int",
)
DEMAND |= {f"{VOSK}/{f}" for f in VOSK_FILES}
DEMUXERS = {"audio.wav": "wav", "audio.mp3": "mp3", "audio.ogg": "ogg",
            "audio.m4a": "mov", "audio.flac": "flac", "audio.aac": "aac",
            "audio.webm": "matroska"}


class Failure(Exception):
    def __init__(self, code, status=422):
        self.code, self.status = code, status
        super().__init__(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def load_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Failure("DUPLICATE_JSON_KEY", 400)
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise Failure("INVALID_JSON", 400) from None


def postprocess(text):
    """The sole runtime/benchmark text transform; never transform a reference."""
    if not isinstance(text, str) or len(text) > MAX_TEXT:
        raise Failure("INVALID_DECODER_TEXT")
    return " ".join(unicodedata.normalize("NFC", text).split())


def validate_request(body, accounts):
    keys = {"schema", "account_id", "job_id", "channel_map", "audio_filename", "is_phone_call"}
    if not isinstance(body, dict) or set(body) != keys:
        raise Failure("INVALID_REQUEST_FIELDS", 400)
    if body["schema"] != REQUEST_SCHEMA:
        raise Failure("UNSUPPORTED_SCHEMA", 400)
    account = body["account_id"]
    if type(account) is not int or account <= 0:
        raise Failure("INVALID_ACCOUNT", 400)
    if account not in accounts:
        raise Failure("ACCOUNT_FORBIDDEN", 403)
    if not isinstance(body["job_id"], str) or not re.fullmatch("[0-9a-f]{32}", body["job_id"]):
        raise Failure("INVALID_JOB", 400)
    if not isinstance(body["audio_filename"], str) or body["audio_filename"] not in DEMUXERS:
        raise Failure("UNSUPPORTED_AUDIO", 415)
    if type(body["is_phone_call"]) is not bool:
        raise Failure("INVALID_PHONE_FLAG", 400)
    mapping = body["channel_map"]
    if not isinstance(mapping, dict) or (mapping and (
            set(mapping) != {"0", "1"} or any(type(v) is not str for v in mapping.values())
            or set(mapping.values()) != {"operator", "client"})):
        raise Failure("INVALID_CHANNEL_MAP", 400)
    return body


def open_audio(root, request, expected_uid=None):
    """Resolve each component by directory FD; never follow symlinks or reopen paths."""
    expected_uid = os.getuid() if expected_uid is None else expected_uid
    fds = []
    try:
        current = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        fds.append(current)
        for component in (str(request["account_id"]), request["job_id"]):
            current = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            fds.append(current)
            info = os.fstat(current)
            if info.st_uid != expected_uid or info.st_mode & 0o077:
                raise Failure("UNSAFE_SPOOL", 403)
        fd = os.open(request["audio_filename"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=current)
        fds.append(fd)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != expected_uid
                or info.st_nlink != 1 or info.st_mode & 0o077):
            raise Failure("UNSAFE_AUDIO", 403)
        if not 0 < info.st_size <= MAX_AUDIO:
            raise Failure("AUDIO_SIZE_LIMIT", 413)
        # A bounded private snapshot prevents mutation after metadata/hash checks.
        snapshot = tempfile.TemporaryFile()
        before = (info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        total = 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_AUDIO:
                snapshot.close()
                raise Failure("AUDIO_SIZE_LIMIT", 413)
            snapshot.write(chunk)
        after = os.fstat(fd)
        if total != info.st_size or before != (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            snapshot.close()
            raise Failure("AUDIO_CHANGED", 409)
        snapshot.seek(0)
        return snapshot
    except OSError:
        raise Failure("AUDIO_NOT_AVAILABLE", 404) from None
    finally:
        for fd in reversed(fds):
            os.close(fd)


def validate_manifest(root, manifest):
    if (not isinstance(manifest, dict) or set(manifest) != {"schema", "files", "dependencies", "tools"}
            or manifest["schema"] != MANIFEST_SCHEMA or not isinstance(manifest["files"], dict)
            or set(manifest["files"]) != DEMAND):
        raise Failure("INVALID_MODEL_MANIFEST", 503)
    base = Path(root).resolve(strict=True)
    for relative, digest in manifest["files"].items():
        path = base / relative
        if (not isinstance(digest, str) or not re.fullmatch("[0-9a-f]{64}", digest)
                or path.is_symlink() or path.resolve(strict=True) != path):
            raise Failure("UNSAFE_MODEL_FILE", 503)
        with path.open("rb") as handle:
            if hashlib.file_digest(handle, "sha256").hexdigest() != digest:
                raise Failure("MODEL_HASH_MISMATCH", 503)
    dependencies = manifest["dependencies"]
    required = {"numpy", "sherpa-onnx", "sherpa-onnx-core", "soundfile", "vosk", "cffi"}
    if not isinstance(dependencies, dict) or not required <= set(dependencies):
        raise Failure("INVALID_DEPENDENCY_MANIFEST", 503)
    for package, version in dependencies.items():
        if not isinstance(version, str) or importlib.metadata.version(package) != version:
            raise Failure("DEPENDENCY_MISMATCH", 503)
    if not isinstance(manifest["tools"], dict) or set(manifest["tools"]) != {"ffmpeg", "ffprobe"}:
        raise Failure("INVALID_TOOL_MANIFEST", 503)
    for name, digest in manifest["tools"].items():
        with open(f"/usr/bin/{name}", "rb") as handle:
            if hashlib.file_digest(handle, "sha256").hexdigest() != digest:
                raise Failure("TOOL_HASH_MISMATCH", 503)
    return hashlib.sha256(canonical(manifest)).hexdigest()


def decode_audio(snapshot, filename):
    """Forced demuxers + inherited FD prevent path/protocol/playlist interpretation."""
    fd = snapshot.fileno()
    source = f"/proc/self/fd/{fd}"
    options = ["-protocol_whitelist", "file,pipe", "-f", DEMUXERS[filename]]
    if filename == "audio.m4a":
        options += ["-enable_drefs", "0"]
    try:
        probe = subprocess.run(["/usr/bin/ffprobe", "-v", "error", *options,
            "-select_streams", "a:0", "-show_entries", "stream=channels,sample_rate:format=duration",
            "-of", "json", source], pass_fds=(fd,), stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=TOOL_TIMEOUT, check=True)
        if len(probe.stdout) > MAX_BODY:
            raise Failure("INVALID_AUDIO_METADATA")
        metadata = load_json(probe.stdout)
        stream = metadata["streams"][0]
        channels, sample_rate = int(stream["channels"]), int(stream["sample_rate"])
        duration = float(metadata["format"].get("duration", 0))
        if channels not in (1, 2) or not 8000 <= sample_rate <= 48000:
            raise Failure("UNSUPPORTED_AUDIO_FORMAT", 415)
        if not math.isfinite(duration) or duration < 0 or duration > MAX_DURATION:
            raise Failure("AUDIO_DURATION_LIMIT", 413)
        snapshot.seek(0)
        limit = MAX_DURATION * 16000 * channels * 2 + 4096
        with tempfile.TemporaryDirectory(prefix="voicecore-") as directory:
            output = Path(directory) / "decoded.wav"
            subprocess.run(["/usr/bin/ffmpeg", "-nostdin", "-v", "error", "-threads", "1",
                *options, "-i", source, "-map", "0:a:0", "-vn", "-sn", "-dn",
                "-threads", "1", "-ar", "16000", "-acodec", "pcm_s16le", "-fs", str(limit),
                "-f", "wav", str(output)], pass_fds=(fd,), stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=TOOL_TIMEOUT, check=True)
            if output.stat().st_size >= limit:
                raise Failure("AUDIO_DURATION_LIMIT", 413)
            with wave.open(str(output), "rb") as wav:
                frames = wav.getnframes()
                actual = frames / 16000
                if (wav.getnchannels() != channels or wav.getsampwidth() != 2
                        or wav.getframerate() != 16000 or not 0 < actual <= MAX_DURATION):
                    raise Failure("INVALID_DECODED_AUDIO")
                payload = wav.readframes(frames)
                if len(payload) != frames * channels * 2:
                    raise Failure("TRUNCATED_AUDIO")
            return payload, channels, sample_rate, actual
    except subprocess.TimeoutExpired:
        raise Failure("AUDIO_DECODE_TIMEOUT", 504) from None
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError, IndexError, TypeError, wave.Error):
        raise Failure("AUDIO_DECODE_FAILED") from None


class LocalModels:
    """Immutable local recognizers; never global account vocabularies or network IO."""
    def __init__(self, root):
        import numpy as np
        import sherpa_onnx
        import vosk
        self.np, self.vosk_api = np, vosk
        vosk.SetLogLevel(-1)
        self.ru = sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
            model=str(Path(root) / GIGA / "model.int8.onnx"),
            tokens=str(Path(root) / GIGA / "tokens.txt"), num_threads=2, debug=False)
        self.en = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(Path(root) / SENSE / "model.int8.onnx"),
            tokens=str(Path(root) / SENSE / "tokens.txt"), num_threads=2, use_itn=False, debug=False)
        self.kk = vosk.Model(str(Path(root) / VOSK))

    def recognize(self, pcm, channels):
        samples = self.np.frombuffer(pcm, dtype="<i2").reshape(-1, channels)
        results = []
        # Fixed bounded contiguous windows retain every frame, including short replies.
        for channel in range(channels):
            for start in range(0, len(samples), 20 * 16000):
                track = samples[start:start + 20 * 16000, channel]
                if not self.np.any(track):
                    continue
                floats = track.astype(self.np.float32) / 32768.0
                ru_stream = self.ru.create_stream()
                ru_stream.accept_waveform(16000, floats)
                self.ru.decode_stream(ru_stream)
                ru_text = postprocess(ru_stream.result.text)
                rec = self.vosk_api.KaldiRecognizer(self.kk, 16000)
                rec.SetWords(True)
                kk_words = []
                for index in range(0, len(track), 8000):
                    if rec.AcceptWaveform(track[index:index + 8000].astype("<i2").tobytes()):
                        kk_words.extend(load_json(rec.Result()).get("result", []))
                kk_words.extend(load_json(rec.FinalResult()).get("result", []))
                kk_text = postprocess(" ".join(word["word"] for word in kk_words))
                conf = sum(word.get("conf", 0) for word in kk_words) / max(1, len(kk_words))
                en_stream = self.en.create_stream()
                en_stream.accept_waveform(16000, floats)
                self.en.decode_stream(en_stream)
                en_text, en_lang = sense_voice_candidate(en_stream.result)
                text, language = select_candidate(ru_text, kk_text, conf, en_text, en_lang)
                if text:
                    results.append({"channel": channel, "start_sec": start / 16000,
                                    "end_sec": (start + len(track)) / 16000,
                                    "text": text, "language": language})
        return results


def sense_voice_candidate(result):
    """Adapt Sherpa2.0.1 SenseVoice's model-reported lang token (e.g. <|en|>)."""
    language = str(getattr(result, "lang", "")).lower()
    token = re.fullmatch(r"<\|([a-z]+)\|>", language)
    return postprocess(result.text), token[1] if token else language


def select_candidate(ru, kk, kk_confidence, en, en_language):
    """Conservative candidate selection, version1; quality explicitly unvalidated.

    No reference, clinic data, learned phrase, or output-dependent reference exists.
    English requires model-reported English; distinctive Kazakh + confidence picks KK.
    """
    ru, kk, en = (postprocess(text) for text in (ru, kk, en))
    if en_language in ("en", "english") and re.search("[A-Za-z]", en):
        return en, "en"
    if re.search("[әіңғүұқөһӘІҢҒҮҰҚӨҺ]", kk) and kk_confidence >= 0.60:
        return kk, "kk"
    if ru:
        return ru, "ru"
    if kk and kk_confidence >= 0.60:
        return kk, "kk"
    return "", "unknown"


class Runtime:
    def __init__(self, spool, accounts, model_version, models, decoder=decode_audio, uid=None):
        self.spool, self.accounts, self.model_version = spool, frozenset(accounts), model_version
        self.models, self.decoder, self.uid = models, decoder, uid

    def transcribe(self, body):
        request = validate_request(body, self.accounts)
        with open_audio(self.spool, request, self.uid) as snapshot:
            pcm, channels, rate, duration = self.decoder(snapshot, request["audio_filename"])
        if (type(channels) is not int or channels not in (1, 2) or type(rate) is not int
                or not 8000 <= rate <= 48000 or type(duration) not in (int, float)
                or not math.isfinite(duration) or not 0 < duration <= MAX_DURATION):
            raise Failure("INVALID_DECODED_AUDIO")
        mapping = request["channel_map"]
        if channels == 1 and mapping:
            raise Failure("CHANNEL_MAP_MISMATCH")
        turns, languages = [], set()
        for item in self.models.recognize(pcm, channels):
            channel = item["channel"]
            start, end = item["start_sec"], item["end_sec"]
            if (type(channel) is not int or channel not in range(channels)
                    or type(start) not in (int, float) or type(end) not in (int, float)
                    or not math.isfinite(start) or not math.isfinite(end)
                    or not 0 <= start <= end <= duration):
                raise Failure("INVALID_DECODER_TIMING")
            text = postprocess(item["text"])
            if text:
                if item["language"] not in ("ru", "kk", "en", "unknown"):
                    raise Failure("INVALID_DECODER_LANGUAGE")
                languages.add(item["language"])
                turns.append({"channel": channel, "speaker": mapping.get(str(channel), "unknown"),
                              "start_sec": start, "end_sec": end, "text": text})
        turns.sort(key=lambda turn: (turn["start_sec"], turn["channel"]))
        response = {"schema": RESPONSE_SCHEMA, "account_id": request["account_id"],
                    "job_id": request["job_id"], "text": "\n".join(t["text"] for t in turns),
                    "dialogue_turns": turns, "language": next(iter(languages)) if len(languages) == 1
                    else "mixed" if languages else "unknown", "duration_sec": duration,
                    "channels": channels, "channel_status": "mono" if channels == 1 else
                    "mapped" if mapping else "unmapped", "model_version": self.model_version}
        if len(canonical(response)) > MAX_RESPONSE:
            raise Failure("TRANSCRIPT_SIZE_LIMIT", 413)
        return response


def worker_main(connection, settings):
    os.setsid()  # Decoder subprocesses share this killable job process group.
    try:
        manifest = load_json(Path(settings["manifest"]).read_bytes())
        version = validate_manifest(settings["models"], manifest)
        runtime = Runtime(settings["spool"], settings["accounts"], version,
                          LocalModels(settings["models"]), uid=settings["spool_uid"])
        connection.send(("ready", version))
        while True:
            body = connection.recv()
            try:
                connection.send(("ok", runtime.transcribe(body)))
            except Failure as error:
                connection.send(("error", error.code, error.status))
            except Exception:
                connection.send(("error", "INFERENCE_FAILED", 503))
    except Exception:
        connection.send(("error", "MODEL_INITIALIZATION_FAILED", 503))
    finally:
        connection.close()


class Worker:
    def __init__(self, settings):
        self.lock, self.ready, self.version = threading.Lock(), False, None
        context = multiprocessing.get_context("spawn")
        self.connection, child = context.Pipe()
        self.process = context.Process(target=worker_main, args=(child, settings), daemon=True)
        self.process.start()
        child.close()

    def _poll_ready(self):
        if not self.process.is_alive():
            self.ready = False
        if not self.ready and self.process.is_alive() and self.connection.poll():
            result = self.connection.recv()
            if result[0] == "ready":
                self.ready, self.version = True, result[1]
        return self.ready

    def poll_ready(self):
        if not self.lock.acquire(blocking=False):
            return self.ready and self.process.is_alive()
        try:
            return self._poll_ready()
        finally:
            self.lock.release()

    def stop(self):
        if self.process.is_alive():
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                self.process.terminate()
            self.process.join(timeout=5)
            if self.process.is_alive():
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.join(timeout=5)
        self.ready = False

    def transcribe(self, body):
        if not self.lock.acquire(blocking=False):
            raise Failure("BUSY", 429)
        try:
            if not self._poll_ready():
                raise Failure("NOT_READY", 503)
            self.connection.send(body)
            if not self.connection.poll(DEADLINE):
                self.ready = False
                self.stop()
                raise Failure("INFERENCE_TIMEOUT", 504)
            result = self.connection.recv()
            if result[0] == "error":
                raise Failure(result[1], result[2])
            return result[1]
        except (EOFError, BrokenPipeError, OSError):
            self.ready = False
            raise Failure("WORKER_FAILED", 503) from None
        finally:
            self.lock.release()


def make_handler(worker, token, accounts):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def setup(self):
            super().setup()
            self.connection.settimeout(INPUT_DEADLINE)
            self._input_lock = threading.Lock()
            self._input_active = True
            self._input_expired = False
            self._input_deadline = time.monotonic() + INPUT_DEADLINE
            self._input_timer = threading.Timer(INPUT_DEADLINE, self._expire_input)
            self._input_timer.daemon = True
            self._input_timer.start()

        def _shutdown_input(self):
            # Retain the socket object: a recycled raw descriptor must never be used.
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        def _expire_input(self):
            with self._input_lock:
                if not self._input_active:
                    return
                self._input_active = False
                self._input_expired = True
            self._shutdown_input()

        def _complete_input(self):
            # The monotonic check also closes the gate if timer scheduling is late.
            with self._input_lock:
                expired = self._input_expired or time.monotonic() >= self._input_deadline
                self._input_active = False
                self._input_expired = expired
            self._input_timer.cancel()
            self._input_timer.join()
            if expired:
                self._shutdown_input()
                raise Failure("REQUEST_TIMEOUT", 408)

        def finish(self):
            # Runs for unauthorized GETs, parse failures, EOF and body exceptions too.
            with self._input_lock:
                self._input_active = False
            self._input_timer.cancel()
            self._input_timer.join()  # Reap before the server releases this handler slot.
            super().finish()

        def handle(self):
            try:
                super().handle()
            except OSError:
                pass  # Deadline/disconnect errors must not log raw request tracebacks.

        def log_message(self, *_args):
            pass  # Never log jobs, transcripts, tokens, audio paths or bodies.

        def respond(self, status, body):
            payload = canonical(body)
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except OSError:
                pass  # An expired or disconnected socket cannot receive an error.

        def dispatch(self):
            try:
                supplied = self.headers.get_all("Authorization", [])
                if len(supplied) != 1 or not hmac.compare_digest(
                        supplied[0].encode("utf-8"), f"Bearer {token}".encode("utf-8")):
                    raise Failure("UNAUTHORIZED", 401)
                if self.command == "GET" and self.path in ("/health", "/ready", "/version"):
                    self._complete_input()
                    ready = worker.poll_ready()
                    self.respond(200 if self.path != "/ready" or ready else 503,
                                 {"ready": ready, "schema": RESPONSE_SCHEMA,
                                  "model_version": worker.version,
                                  "limits": {"audio_bytes": MAX_AUDIO, "duration_sec": MAX_DURATION,
                                             "concurrency": 1, "deadline_sec": DEADLINE},
                                  "runtime_version": "voicecore-dev-1"})
                    return
                if self.command != "POST" or self.path != "/transcribe":
                    raise Failure("NOT_FOUND", 404)
                if self.headers.get("Transfer-Encoding"):
                    raise Failure("TRANSFER_ENCODING_FORBIDDEN", 400)
                if self.headers.get("Content-Type", "").split(";", 1)[0].strip() != "application/json":
                    raise Failure("JSON_REQUIRED", 415)
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not re.fullmatch("[0-9]+", lengths[0]):
                    raise Failure("CONTENT_LENGTH_REQUIRED", 411)
                length = int(lengths[0])
                if not 0 < length <= MAX_BODY:
                    raise Failure("BODY_SIZE_LIMIT", 413)
                payload = self.rfile.read(length)
                if len(payload) != length:
                    raise Failure("TRUNCATED_BODY", 400)
                body = validate_request(load_json(payload), accounts)
                self._complete_input()
                self.respond(200, worker.transcribe(body))
            except Failure as error:
                self.respond(error.status, {"error": {"code": error.code}})
            except (TimeoutError, socket.timeout):
                self.respond(408, {"error": {"code": "REQUEST_TIMEOUT"}})
            except Exception:
                self.respond(503, {"error": {"code": "INTERNAL_FAILURE"}})

        do_GET = dispatch
        do_POST = dispatch
        do_PUT = dispatch
        do_DELETE = dispatch
    return Handler


class BoundedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    request_queue_size = 1

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(4)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    if not ipaddress.ip_address(args.host).is_loopback or not 1024 <= args.port <= 65535:
        parser.error("private loopback and non-privileged explicit port required")
    token = os.environ.get("ONELINK_VOICECORE_TOKEN", "")
    accounts_raw = os.environ.get("ONELINK_VOICECORE_ACCOUNT_IDS", "")
    if len(token.encode()) < 32 or not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", accounts_raw):
        parser.error("strong token and explicit account allowlist required")
    if not token.isascii() or any(ord(char) < 33 or ord(char) > 126 for char in token):
        parser.error("token must be printable ASCII without whitespace")
    settings = {"manifest": str(args.manifest), "accounts": {int(a) for a in accounts_raw.split(",")},
                "models": os.environ["ONELINK_VOICECORE_MODELS_ROOT"],
                "spool": os.environ["ONELINK_VOICECORE_SPOOL_ROOT"],
                "spool_uid": int(os.environ.get("ONELINK_VOICECORE_SPOOL_UID", os.getuid()))}
    worker = Worker(settings)
    server = BoundedHTTPServer((args.host, args.port), make_handler(worker, token, settings["accounts"]))
    try:
        server.serve_forever()
    finally:
        server.server_close()
        worker.stop()


if __name__ == "__main__":
    main()

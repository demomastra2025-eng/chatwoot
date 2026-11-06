"""Pure stdlib tests: synthetic text/bytes only, no native imports, models or API."""
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import voicecore as vc
import benchmark


def request():
    return {"schema": vc.REQUEST_SCHEMA, "account_id": 7, "job_id": "a" * 32,
            "audio_filename": "audio.wav", "channel_map": {}, "is_phone_call": True}


class ModelDouble:
    def __init__(self, turns=()):
        self.turns = turns

    def recognize(self, pcm, channels):
        return copy.deepcopy(self.turns)


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.job = self.root / "7" / ("a" * 32)
        self.job.mkdir(parents=True)
        self.job.parent.chmod(0o700)
        self.job.chmod(0o700)
        self.audio = self.job / "audio.wav"
        self.audio.write_bytes(b"synthetic-not-audio")
        self.audio.chmod(0o600)
        self.body = request()

    def tearDown(self):
        self.tmp.cleanup()

    def runtime(self, turns=(), channels=2):
        def decode(snapshot, filename):
            self.assertEqual(snapshot.read(), b"synthetic-not-audio")
            self.assertEqual(filename, "audio.wav")
            return b"pcm", channels, 8000, 1.5
        return vc.Runtime(self.root, {7}, "f" * 64, ModelDouble(turns), decode)

    def test_import_has_no_native_dependencies(self):
        self.assertNotIn("sherpa_onnx", sys.modules)
        self.assertNotIn("vosk", sys.modules)
        self.assertNotIn("numpy", sys.modules)

    def test_request_is_strict_and_account_bound(self):
        invalid = [("account_id", True), ("account_id", 8), ("job_id", "../x"),
                   ("audio_filename", "https://example.invalid/audio.wav"),
                   ("audio_filename", "../audio.wav"), ("is_phone_call", "false"),
                   ("channel_map", {"0": ["operator"], "1": "client"}),
                   ("channel_map", {"0": "operator"}),
                   ("channel_map", {"0": "operator", "1": "operator"})]
        for key, value in invalid:
            with self.subTest(key=key, value=value), self.assertRaises(vc.Failure):
                vc.validate_request({**request(), key: value}, {7})
        for extra in ("audio_path", "clinic_id", "use_symbiosis_arbitrator", "learn"):
            with self.assertRaises(vc.Failure):
                vc.validate_request({**request(), extra: True}, {7})

    def test_json_rejects_duplicates_and_nonfinite(self):
        for value in (b'{"x":1,"x":2}', b'{"x":NaN}', b'[] trailing', b'\xff'):
            with self.assertRaises(vc.Failure):
                vc.load_json(value)

    def test_voice_message_formats_use_fixed_demuxers_without_accepting_paths(self):
        for filename, demuxer in (("audio.aac", "aac"), ("audio.webm", "matroska")):
            with self.subTest(filename=filename):
                body = {**request(), "audio_filename": filename, "is_phone_call": False}
                self.assertEqual(vc.validate_request(body, {7}), body)
                self.assertEqual(vc.DEMUXERS[filename], demuxer)
                with self.assertRaises(vc.Failure):
                    vc.validate_request({**body, "audio_filename": "../" + filename}, {7})

    def test_phone_or_voice_message_flag_is_strict_bool_with_identical_pipeline(self):
        turn = {"channel": 0, "start_sec": 0, "end_sec": 1, "text": "synthetic", "language": "ru"}
        runtime = self.runtime([turn], channels=1)
        call = runtime.transcribe({**request(), "is_phone_call": True})
        voice_message = runtime.transcribe({**request(), "is_phone_call": False})
        self.assertEqual(call, voice_message)
        for invalid in ("false", "true", 0, 1, None):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(vc.Failure, "INVALID_PHONE_FLAG"):
                vc.validate_request({**request(), "is_phone_call": invalid}, {7})

    def test_private_snapshot_survives_original_replacement(self):
        with vc.open_audio(self.root, self.body) as snapshot:
            self.audio.unlink()
            self.audio.write_bytes(b"replacement")
            self.assertEqual(snapshot.read(), b"synthetic-not-audio")

    def test_symlink_file_parent_and_hardlink_fail_closed(self):
        target = self.root / "target"
        target.write_bytes(b"synthetic")
        target.chmod(0o600)
        self.audio.unlink()
        self.audio.symlink_to(target)
        with self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body)
        self.audio.unlink()
        os.link(target, self.audio)
        with self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body)
        self.audio.unlink()
        self.job.rmdir()
        self.job.symlink_to(self.root)
        with self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body)

    def test_permissions_ownership_size_and_fifo_fail_closed(self):
        self.audio.chmod(0o644)
        with self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body)
        self.audio.chmod(0o600)
        with self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body, expected_uid=os.getuid() + 1)
        with patch.object(vc, "MAX_AUDIO", 3), self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body)
        self.audio.unlink()
        os.mkfifo(self.audio, 0o600)
        with self.assertRaises(vc.Failure):
            vc.open_audio(self.root, self.body)

    def test_both_channels_short_turns_overlap_unknown_preserved(self):
        turns = [{"channel": 1, "start_sec": .05, "end_sec": .10, "text": "second", "language": "ru"},
                 {"channel": 0, "start_sec": 0, "end_sec": .2, "text": "first", "language": "ru"}]
        result = self.runtime(turns).transcribe(self.body)
        self.assertEqual(result["text"], "first\nsecond")
        self.assertEqual(result["channel_status"], "unmapped")
        self.assertEqual([t["channel"] for t in result["dialogue_turns"]], [0, 1])
        self.assertEqual([t["speaker"] for t in result["dialogue_turns"]], ["unknown", "unknown"])
        self.assertEqual(set(result), {"schema", "account_id", "job_id", "text", "dialogue_turns",
                        "language", "duration_sec", "channels", "channel_status", "model_version"})

    def test_both_map_orientations(self):
        turns = [{"channel": c, "start_sec": 0, "end_sec": 1, "text": str(c), "language": "ru"}
                 for c in (0, 1)]
        for roles in (("operator", "client"), ("client", "operator")):
            self.body["channel_map"] = dict(zip(("0", "1"), roles))
            result = self.runtime(turns).transcribe(self.body)
            self.assertEqual(result["channel_status"], "mapped")
            self.assertEqual([t["speaker"] for t in result["dialogue_turns"]], list(roles))

    def test_mono_unknown_and_silence(self):
        result = self.runtime(channels=1).transcribe(self.body)
        self.assertEqual((result["text"], result["dialogue_turns"], result["language"],
                          result["channel_status"]), ("", [], "unknown", "mono"))
        self.body["channel_map"] = {"0": "operator", "1": "client"}
        with self.assertRaisesRegex(vc.Failure, "CHANNEL_MAP_MISMATCH"):
            self.runtime(channels=1).transcribe(self.body)

    def test_decoder_failure_not_successful_silence(self):
        runtime = self.runtime()
        runtime.decoder = lambda *_: (_ for _ in ()).throw(vc.Failure("CODEC_FAILED"))
        with self.assertRaisesRegex(vc.Failure, "CODEC_FAILED"):
            runtime.transcribe(self.body)

    def test_invalid_timing_or_channel_rejects_entire_job(self):
        for changes in ({"channel": 2}, {"start_sec": float("nan")}, {"end_sec": 2}, {"end_sec": -.1}):
            turn = {"channel": 0, "start_sec": 0, "end_sec": 1, "text": "synthetic", "language": "ru"}
            with self.assertRaises(vc.Failure):
                self.runtime([{**turn, **changes}]).transcribe(self.body)

    def test_single_postprocess_and_reference_free_selector(self):
        self.assertEqual(vc.postprocess("  cafe\u0301\t test\n"), "café test")
        self.assertEqual(vc.select_candidate("synthetic ru", "қазақ", .8, "English", "en"), ("English", "en"))
        self.assertEqual(vc.select_candidate("synthetic ru", "қазақ", .8, "English", ""), ("қазақ", "kk"))
        self.assertEqual(vc.select_candidate("synthetic ru", "қазақ", .1, "English", ""), ("synthetic ru", "ru"))

    def test_manifest_must_be_complete_before_any_native_import(self):
        for manifest in ({}, {"schema": vc.MANIFEST_SCHEMA, "files": {}, "dependencies": {}, "tools": {}}):
            with self.assertRaisesRegex(vc.Failure, "INVALID_MODEL_MANIFEST"):
                vc.validate_manifest(self.root, manifest)

    def test_benchmark_invokes_runtime_and_never_rewrites_reference(self):
        turn = {"channel": 0, "start_sec": 0, "end_sec": 1, "text": "one two", "language": "ru"}
        case = {"request": self.body, "reference": "One two three"}
        untouched = copy.deepcopy(case)
        result = benchmark.evaluate(self.runtime([turn]), [case])
        self.assertEqual(case, untouched)
        self.assertEqual((result["word_errors"], result["reference_words"]), (2, 3))
        self.assertAlmostEqual(result["wer"], 2 / 3)

    def test_packaged_manifest_exact_digest_and_paths(self):
        manifest = vc.load_json((Path(vc.__file__).parent / "model-manifest.json").read_bytes())
        self.assertEqual(set(manifest["files"]), vc.DEMAND)
        self.assertEqual(__import__("hashlib").sha256(vc.canonical(manifest)).hexdigest(),
                         "1f18b6338ccb72b202aa89c942b3989775dc93af137e201da21846a676b6095e")

    def test_decode_uses_forced_demuxer_inherited_fd_and_bounded_subprocesses(self):
        commands = []
        metadata = vc.canonical({"streams": [{"channels": 2, "sample_rate": "8000"}],
                                 "format": {"duration": "1.5"}})
        def run(command, **kwargs):
            commands.append((command, kwargs))
            if command[0].endswith("ffprobe"):
                return SimpleNamespace(stdout=metadata)
            Path(command[-1]).write_bytes(b"fake-output-not-audio")
            return SimpleNamespace()
        wav = unittest.mock.MagicMock()
        wav.__enter__.return_value = wav
        wav.getnframes.return_value = 24000
        wav.getnchannels.return_value = 2
        wav.getsampwidth.return_value = 2
        wav.getframerate.return_value = 16000
        wav.readframes.return_value = b"x" * 96000
        with tempfile.TemporaryFile() as snapshot, patch.object(vc.subprocess, "run", run), \
                patch.object(vc.wave, "open", return_value=wav):
            pcm, channels, rate, duration = vc.decode_audio(snapshot, "audio.m4a")
        self.assertEqual((channels, rate, duration), (2, 8000, 1.5))
        self.assertEqual(len(pcm), 96000)
        for command, kwargs in commands:
            self.assertEqual(command[command.index("-f") + 1], "mov")
            self.assertEqual(command[command.index("-protocol_whitelist") + 1], "file,pipe")
            self.assertEqual(command[command.index("-enable_drefs") + 1], "0")
            self.assertEqual(kwargs["timeout"], 20)
            self.assertEqual(len(kwargs["pass_fds"]), 1)
            self.assertFalse(kwargs.get("shell", False))
            self.assertTrue(any(str(part).startswith("/proc/self/fd/") for part in command))

    def test_decode_timeout_is_typed_not_empty_success(self):
        with tempfile.TemporaryFile() as snapshot, patch.object(vc.subprocess, "run",
                side_effect=vc.subprocess.TimeoutExpired("synthetic", 20)):
            with self.assertRaisesRegex(vc.Failure, "AUDIO_DECODE_TIMEOUT"):
                vc.decode_audio(snapshot, "audio.wav")


class FakeSocket:
    def __init__(self, wire):
        self.reader = io.BytesIO(wire)
        self.sent = bytearray()

    def makefile(self, *args, **kwargs):
        return self.reader

    def sendall(self, data):
        self.sent.extend(data)

    def settimeout(self, timeout):
        pass


class HttpContractTest(unittest.TestCase):
    def wire(self, path="/transcribe", payload=None, auth=True, extra=b""):
        payload = vc.canonical(request()) if payload is None else payload
        token = b"Authorization: Bearer " + b"x" * 32 + b"\r\n" if auth else b""
        wire = (b"POST " + path.encode() + b" HTTP/1.0\r\n" + token +
                b"Content-Type: application/json\r\nContent-Length: " + str(len(payload)).encode() +
                b"\r\n" + extra + b"\r\n" + payload)
        sock = FakeSocket(wire)
        class WorkerDouble:
            def transcribe(self, body):
                return {"accepted": True}
        vc.make_handler(WorkerDouble(), "x" * 32, {7})(sock, ("127.0.0.1", 1), object())
        return bytes(sock.sent)

    def test_auth_before_body_or_spool(self):
        self.assertIn(b"401", self.wire(payload=b"not json", auth=False).split(b"\r\n")[0])

    def test_learn_absent_and_bad_requests_typed(self):
        self.assertIn(b"404", self.wire(path="/clinic/learn").split(b"\r\n")[0])
        self.assertIn(b"400", self.wire(payload=b'{"x":1,"x":2}').split(b"\r\n")[0])
        self.assertIn(b"400", self.wire(extra=b"Transfer-Encoding: chunked\r\n").split(b"\r\n")[0])

    def test_valid_request(self):
        self.assertIn(b"200", self.wire().split(b"\r\n")[0])


class InputDeadlineTest(unittest.TestCase):
    """Virtual clock and timer exercise slow input without sockets, sleeps or models."""
    def run_handler(self, *, slow_headers=False, body_elapsed=0, auth=True, during_inference=None,
                    method=b"POST", path=b"/transcribe", body_error=False):
        clock, timers = [0.0], []
        payload = vc.canonical(request())
        auth_line = b"Authorization: Bearer " + b"x" * 32 + b"\r\n" if auth else b""
        wire = (method + b" " + path + b" HTTP/1.0\r\n" + auth_line +
                b"Content-Type: application/json\r\nContent-Length: " + str(len(payload)).encode() +
                b"\r\n\r\n" + payload)

        class TimerDouble:
            def __init__(self, interval, callback):
                self.interval, self.callback = interval, callback
                self.started = self.cancelled = self.fired = False
                self.joined = False
                timers.append(self)

            def start(self):
                self.started = True

            def cancel(self):
                self.cancelled = True

            def join(self):
                self.joined = True

            def fire(self):
                if self.started and not self.cancelled and not self.fired:
                    self.fired = True
                    self.callback()

        class DeadlineSocket(FakeSocket):
            def __init__(self, data):
                super().__init__(data)
                self.shutdowns = []

            def shutdown(self, how):
                self.shutdowns.append(how)

            def sendall(self, data):
                if self.shutdowns:
                    raise BrokenPipeError("synthetic expired connection")
                super().sendall(data)

        sock = DeadlineSocket(wire)
        other_socket = DeadlineSocket(b"")

        class DripReader(io.BytesIO):
            def readline(self, limit=-1):
                if slow_headers:
                    clock[0] += 3.0  # Every increment is below the inactivity timeout.
                    if clock[0] >= vc.INPUT_DEADLINE:
                        timers[0].fire()
                if sock.shutdowns:
                    return b""
                return super().readline(limit)

            def read(self, length=-1):
                if body_error:
                    raise OSError("synthetic body disconnect")
                clock[0] += body_elapsed
                return super().read(length)

        sock.reader = DripReader(wire)
        worker = unittest.mock.Mock()
        worker.version = "f" * 64
        worker.transcribe.side_effect = lambda body: (
            during_inference(timers[0], sock, clock) if during_inference else {"accepted": True})
        with patch.object(vc.threading, "Timer", TimerDouble), \
                patch.object(vc.time, "monotonic", side_effect=lambda: clock[0]):
            vc.make_handler(worker, "x" * 32, {7})(sock, ("127.0.0.1", 1), object())
        return worker, timers, sock, other_socket

    def test_slow_header_trickle_expires_absolute_budget_and_own_socket_only(self):
        worker, timers, sock, other = self.run_handler(slow_headers=True)
        worker.transcribe.assert_not_called()
        self.assertEqual(len(timers), 1)
        self.assertEqual(timers[0].interval, 10)
        self.assertTrue(timers[0].fired)
        self.assertTrue(timers[0].cancelled)
        self.assertTrue(timers[0].joined)
        self.assertEqual(sock.shutdowns, [vc.socket.SHUT_RDWR])
        self.assertEqual(other.shutdowns, [])

    def test_late_timer_cannot_admit_body_past_monotonic_deadline(self):
        worker, timers, sock, _ = self.run_handler(body_elapsed=11)
        worker.transcribe.assert_not_called()
        self.assertFalse(timers[0].fired)  # Timer delivery deliberately delayed.
        self.assertTrue(timers[0].cancelled)
        self.assertEqual(sock.shutdowns, [vc.socket.SHUT_RDWR])

    def test_validated_body_cancels_timer_before_inference_and_racing_callback_safe(self):
        def inference(timer, sock, clock):
            self.assertTrue(timer.cancelled)
            clock[0] = 100.0  # Inference has its own110s deadline.
            timer.callback()  # Even a callback already scheduled before cancel is safe.
            self.assertEqual(sock.shutdowns, [])
            return {"accepted": True}
        worker, timers, sock, _ = self.run_handler(body_elapsed=9, during_inference=inference)
        worker.transcribe.assert_called_once()
        self.assertEqual(sock.shutdowns, [])
        self.assertTrue(timers[0].cancelled)

    def test_unauthorized_input_always_cancels_timer_in_finish(self):
        worker, timers, sock, _ = self.run_handler(auth=False, method=b"GET", path=b"/health")
        worker.transcribe.assert_not_called()
        self.assertTrue(timers[0].cancelled)
        self.assertTrue(timers[0].joined)
        timers[0].callback()
        self.assertEqual(sock.shutdowns, [])

    def test_body_disconnect_always_cancels_and_reaps_timer(self):
        worker, timers, sock, _ = self.run_handler(body_error=True)
        worker.transcribe.assert_not_called()
        self.assertTrue(timers[0].cancelled)
        self.assertTrue(timers[0].joined)
        timers[0].callback()
        self.assertEqual(sock.shutdowns, [])


class WorkerContractTest(unittest.TestCase):
    def worker(self, response=("ok", {"synthetic": True})):
        worker = vc.Worker.__new__(vc.Worker)
        worker.lock = __import__("threading").Lock()
        worker.ready, worker.version = True, "f" * 64
        worker.process = unittest.mock.Mock()
        worker.process.is_alive.return_value = True
        worker.connection = unittest.mock.Mock()
        worker.connection.poll.return_value = True
        worker.connection.recv.return_value = response
        return worker

    def test_busy_rejected_without_queuing_or_reading_pipe(self):
        worker = self.worker()
        worker.lock.acquire()
        try:
            with self.assertRaisesRegex(vc.Failure, "BUSY"):
                worker.transcribe(request())
            worker.connection.send.assert_not_called()
        finally:
            worker.lock.release()

    def test_deadline_stops_process_before_timeout_response(self):
        worker = self.worker()
        worker.connection.poll.return_value = False
        worker.stop = unittest.mock.Mock()
        with self.assertRaisesRegex(vc.Failure, "INFERENCE_TIMEOUT"):
            worker.transcribe(request())
        worker.stop.assert_called_once()
        self.assertFalse(worker.ready)
        self.assertFalse(worker.lock.locked())

    def test_health_poll_during_inference_never_consumes_response(self):
        worker = self.worker()
        worker.lock.acquire()
        try:
            self.assertTrue(worker.poll_ready())
            worker.connection.recv.assert_not_called()
        finally:
            worker.lock.release()

    def test_worker_errors_never_become_success(self):
        worker = self.worker(("error", "INFERENCE_FAILED", 503))
        with self.assertRaisesRegex(vc.Failure, "INFERENCE_FAILED"):
            worker.transcribe(request())

    def test_stop_kills_the_subprocess_group(self):
        worker = self.worker()
        worker.process.pid = 123456789
        worker.process.is_alive.side_effect = [True, False]
        with patch.object(vc.os, "killpg") as kill:
            worker.stop()
        kill.assert_called_once_with(123456789, vc.signal.SIGTERM)
        worker.process.join.assert_called_once_with(timeout=5)
        self.assertFalse(worker.ready)


if __name__ == "__main__":
    unittest.main()

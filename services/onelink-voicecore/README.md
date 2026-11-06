# OneLink VoiceCore: isolated DEV batch runtime

This is a new conservative local pipeline, not the old v7.3 engine. ASR quality,
roles on actual provider recordings, throughput and memory remain **UNKNOWN**.
No former97–99% cached-text score applies. Feature remains disabled by default in
Rails; this directory neither installs a service nor changes live DEV/PROD.

`voicecore.py` imports only stdlib until explicitly starting its child process.
Only generic decoder API ideas derive from frozen source SHA256e1885f8b,
methods307–443. Original code, patient-derived JSON, clinic profiles, clinical
normalizers, dictionaries, learning, cloud arbitration and `.env` reading are absent.
`benchmark.evaluate` calls the same `Runtime.transcribe` as HTTP and computes
aggregate WER/CER against unchanged caller-provided references. It does not fetch
data or run automatically. Dataset provenance/holdout separation remains separate.

The immutable model manifest pins23 local public model files/2,875,719,362B,
six native package distributions and ffmpeg/ffprobe binaries. Its canonical
SHA256/model_version is
`1f18b6338ccb72b202aa89c942b3989775dc93af137e201da21846a676b6095e`.
Model weights are not included. Runtime validates all hashes/versions **before**
loading GigaAM int8 RU, Vosk full KK and SenseVoice int8 EN in a single spawned
worker. A missing asset/version fails readiness. Versions are a reproducibility
pin from the prepared venv, not a claim of current vendor support/security.

Input is private internal HTTP on an explicitly selected loopback port. Set
`ONELINK_VOICECORE_TOKEN` (at least32 printable ASCII bytes),
`ONELINK_VOICECORE_ACCOUNT_IDS` (comma-separated numeric allowlist),
`ONELINK_VOICECORE_MODELS_ROOT`, `ONELINK_VOICECORE_SPOOL_ROOT` and optionally
`ONELINK_VOICECORE_SPOOL_UID` (numeric writer UID; default service UID). No env
file is loaded. Rails and runtime must mount the same spool, Rails read-write and
runtime read-only, with account/job directories0700 and audio files0600 owned by
that UID. Staging jobs are single-use immutable snapshots, cleaned by Rails.
Run only after explicit coordinated DEV execution approval, using the prepared
venv Python with `voicecore.py --port <isolated-port> --manifest model-manifest.json`.
`ONELINK_VOICECORE_URL`, `ENABLED` and the same account/token/spool variables are
Rails configuration; the runtime never enables a product feature.

All endpoints require authentication: GET `/health`, `/ready`, `/version` and
POST `/transcribe`. No learning routes. Request fields are exactly:

```json
{"schema":"onelink.voicecore.request.v1","account_id":7,"job_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","audio_filename":"audio.wav","channel_map":{},"is_phone_call":true}
```

These IDs/bytes are synthetic. Filename is one of audio.wav/mp3/ogg/m4a/flac/aac/webm;
it identifies a file under `<spool>/<account>/<job>/`, never a caller path/URL.
`is_phone_call` is strictly boolean: true for calls, false for voice messages.
Both use this same decoder/postprocessor; the flag never selects DSP or rules.
Every path component uses no-follow directory descriptors; file owner, mode,
regular type, link count, size and unchanged inode metadata are checked while
copying into a bounded private snapshot. Forced demuxers, `/proc/self/fd`, disabled
MOV external references, explicit file/pipe protocol allowlist and20s subprocess
timeouts constrain ffprobe/ffmpeg. Keep model mounts read-only, deny network
egress independently with the deployment sandbox, cap CPU/RAM/PIDs and run as a
dedicated user. These deployment controls are necessary and are not installed by
this package; do not treat deleting cloud code as an OS-level network boundary.

Limits: input100MiB/1800s/1–2channels/8–48kHz, JSON16KiB, response2MiB, one active
inference, four bounded HTTP handlers, accept backlog1, absolute monotonic10s
header+body read/validation budget (in addition to inactivity timeout), and total
inference110s. Native decoder timeout terminates/reaps the worker process group,
including ffmpeg, and marks not-ready until service restart; no automatic retry
or paid fallback. These are operational limits, not latency promises.

Decoded PCM keeps both channels, resampled individually to16kHz. All samples are
visited in fixed20s windows without short-turn VAD filtering. Window timestamps
are coarse bounds, **not** aligned word times or proven speaker turns. Overlap
across channels survives. A nonempty trusted map must contain exactly both0/1
with distinct operator/client values; empty map produces unknown speakers. Mono
remains unknown and rejects a two-channel map. Decoder errors fail the complete
job; genuine exact-zero silence returns empty text/turns with valid metadata.

Candidate selectorv1 uses model-reported EN when available, Vosk distinctive
Kazakh characters plus confidence>=0.60, otherwise Giga RU. This heuristic is
explicit, reference-free and unvalidated; KK without distinctive letters may be
misclassified. Sherpa2.0.1 exposes the read-only result property `lang`;
SenseVoice supplies a symbol-table token such as `<|en|>`, which the adapter
unwraps to `en` before selection. See the pinned upstream
[Python binding](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/sherpa-onnx/python/csrc/offline-stream.cc#L76)
and [SenseVoice result conversion](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/sherpa-onnx/csrc/offline-recognizer-sense-voice-impl.h#L53).
Missing, unknown or malformed language metadata never establishes English from
Latin text alone. Actual native selection still requires smoke verification.
Conservative text processing
is NFC+whitespace only; no memorized substitutions or automatic corrections.

Response schema is `onelink.voicecore.response.v1` with account_id/job_id/text,
dialogue_turns[{speaker,channel,start_sec,end_sec,text}], language,
duration_sec/channels/channel_status and64hex model_version. Unknown speakers
are retained. Rails must verify every field before storage and avoid its old
unknown=>operator parser default. Errors use appropriate non200 statuses and
`{"error":{"code":"..."}}`, without body/path/token/traceback logging.

Pure checks, no model/audio/API:

```
python3 -m unittest discover -s services/onelink-voicecore/tests -v
```

Next gates: independent diff review, coordinated synthetic native decoding and
hostile compressed-input tests, actual process deadline/egress/resource evidence,
then owner-approved untouched human-reference audio quality. Deployment/real
recordings/PROD require their own permission. Rollback: disable Rails feature and
restore the prior whole pinned runtime package; existing transcripts stay intact.

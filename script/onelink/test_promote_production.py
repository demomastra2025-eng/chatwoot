#!/usr/bin/env python3
"""Run the real promoter against a disposable fake Docker/Compose fleet, never production."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("promote_production.sh")
SHA = "a" * 40
OLD_SHA = "b" * 40
APP_REF = "ghcr.io/demomastra2025-eng/chatwoot@sha256:" + "c" * 64
VOICE_REF = "ghcr.io/demomastra2025-eng/onelink-ai-voice@sha256:" + "d" * 64
OLD_APP_ID = "sha256:" + "e" * 64
OLD_VOICE_ID = "sha256:" + "f" * 64
NEW_APP_ID = "sha256:" + "1" * 64
NEW_VOICE_ID = "sha256:" + "2" * 64
SERVICES = (
    "chatwoot_rails", "chatwoot_rails_2", "chatwoot_sidekiq",
    "chatwoot_outbound_messages_worker", "chatwoot_medelement_commands_worker",
    "chatwoot_captain_runtime_worker", "onelink_ai_voice",
)
FENCED = ("chatwoot_outbound_messages_worker", "chatwoot_medelement_commands_worker")

# The only `docker` on PATH in these tests. Every compose call validates both
# paths against a fresh temp root. No real daemon, DB, .env.production or SSH.
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

root = Path(os.environ["FAKE_ROOT"])
path = root / "fleet.json"
state = json.loads(path.read_text())
args = sys.argv[1:]
state["trace"].append(args)


def save():
    path.write_text(json.dumps(state))


def fail(msg):
    save()
    sys.exit(msg)


def emit(text):
    print(text)
    save()


def cid_service(cid):
    return next((name for name, entry in state["fleet"].items() if entry["cid"] == cid), None)


if args[0] == "compose":
    assert args[1:5] == ["--env-file", str(root / ".env.production"), "-f", str(root / "docker-compose.production.yml")], args
    cmd = args[5:]
    if cmd[:1] == ["config"]:
        if cmd[1:] == ["--quiet"]:
            save()
        elif cmd[1:] == ["--format", "json"]:
            services = {name: {"image": os.environ.get("CHATWOOT_IMAGE") if name.startswith("chatwoot_") else os.environ.get("ONELINK_AI_VOICE_IMAGE")} for name in state["fleet"]}
            if state.get("bad_inventory"):
                services["chatwoot_sidekiq"]["image"] = "unknown-image"
            emit(json.dumps({"services": services}))
        else:
            fail("unexpected config")
    elif cmd[:1] == ["ps"]:
        name = cmd[-1]
        entry = state["fleet"][name]
        emit(entry["cid"] if entry["status"] == "running" or "--all" in cmd else "")
    elif cmd[:1] == ["stop"]:
        name = cmd[1]
        if state.get("fail_stop") == name and (state.get("fail_stop_always") or not state.get("fail_stop_used")):
            state["fail_stop_used"] = True
            if state.get("partial_stop"):
                state["fleet"][name]["status"] = "exited"
            fail("simulated compose stop failure")
        state["fleet"][name]["status"] = "exited"
        save()
    elif cmd[:1] == ["up"]:
        name = cmd[-1]
        entry = state["fleet"][name]
        if state.get("fail_up") == name and not state.get("fail_up_used"):
            state["fail_up_used"] = True
            if state.get("partial_up"):
                entry["cid"] += "-partial"
                entry["status"] = "exited"
            fail("simulated compose up failure")
        image = os.environ.get("CHATWOOT_IMAGE") if name.startswith("chatwoot_") else os.environ.get("ONELINK_AI_VOICE_IMAGE")
        entry.update(cid=entry["cid"] + "-next", image=state["images"][image], sha=os.environ["SOURCE_SHA"], status="running")
        save()
    elif cmd[:1] == ["run"]:
        if state.get("fail_prepare"):
            fail("simulated DB prepare failure")
        save()
    elif cmd[:1] == ["exec"]:
        if "schema_migrations" in str(cmd):
            if state.get("fail_db_read"):
                fail("simulated database read failure")
            emit(state.get("db_phase", "absent"))
        elif any("finalize_release.rb" in part for part in cmd):
            if state.get("fail_finalizer"):
                fail("simulated finalizer failure")
            save()
        else:
            fail("unexpected compose exec")
    else:
        fail("unexpected compose command")
elif args[0] == "pull":
    save()
elif args[0] == "run":
    if "--entrypoint" not in args:
        fail("unexpected run")
    kind = args[args.index("--entrypoint") + 1]
    if kind == "cat":
        emit("a" * 40)
    elif kind == "sh" and "20260924120000" in args[-1]:
        emit("yes" if state.get("target_t2") else "no")
    elif kind == "sh" and "captain_outbound_messages_v2" in args[-1]:
        if not state.get("target_fences", True):
            fail("missing target fence")
        save()
    else:
        fail("unexpected image inspect")
elif args[0] == "inspect":
    name = cid_service(args[-1])
    if name is None:
        fail("unknown container")
    entry = state["fleet"][name]
    fmt = args[args.index("-f") + 1]
    if ".Image" in fmt:
        emit(entry["image"])
    elif ".State.Health" in fmt:
        emit("healthy")
    elif ".State.Status" in fmt:
        emit(entry["status"])
    else:
        fail("unknown inspection format")
elif args[0] == "exec":
    name = cid_service(args[1])
    if name is None or state["fleet"][name]["status"] != "running":
        fail("container not running")
    if "cat" in args and "/app/.git_sha" in args:
        emit(state["fleet"][name]["sha"])
    elif "test" in args and "-f" in args:
        t2 = state["fleet"][name].get("t2", False)
        ok = not t2 if "!" in args else t2
        if not ok:
            fail("T2 marker mismatch")
        save()
    elif name == "onelink_ai_voice" and "sh" in args:
        emit(json.dumps({"sessions": 0, "janus_server_runtime": {"active_calls": 0}}))
    else:
        fail("unexpected docker exec")
elif args[0] == "image" and args[1] == "ls":
    emit("sha256:b-bridge" if state.get("bridge_tag") else "")
elif args[0] == "image" and args[1] == "inspect":
    emit(state["images"].get(args[-1], "unknown"))
elif args[0] == "tag":
    state["images"][args[2]] = args[1]
    save()
else:
    fail("unexpected docker command")
'''


class PromoteProductionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "docker").write_text(FAKE_DOCKER, encoding="utf-8")
        (self.bin / "docker").chmod(0o755)
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertEqual(source.count("ROOT=/root/crafty"), 1)
        root_guard = '[[ ${EUID} -eq 0 ]] || { echo "must run as root" >&2; exit 77; }'
        self.assertEqual(source.count(root_guard), 1)
        # Only a private copy gets a sandbox root. The production script remains
        # hard-coded to /root/crafty and retains its root guard; the fake runs
        # under an ordinary CI user too.
        test_source = source.replace("ROOT=/root/crafty", f"ROOT={self.root}")
        test_source = test_source.replace(root_guard, root_guard.replace("-eq 0", "-ge 0"))
        (self.root / "promote.sh").write_text(test_source, encoding="utf-8")
        (self.root / ".env.production").write_text("CHATWOOT_IMAGE=old\nONELINK_AI_VOICE_IMAGE=old\n", encoding="utf-8")
        (self.root / "docker-compose.production.yml").write_text("services: {}\n", encoding="utf-8")
        self.state = {
            "trace": [],
            "fleet": {name: {"cid": "id-" + name, "image": OLD_VOICE_ID if name == "onelink_ai_voice" else OLD_APP_ID,
                             "sha": OLD_SHA, "status": "running", "t2": False} for name in SERVICES},
            "images": {APP_REF: NEW_APP_ID, VOICE_REF: NEW_VOICE_ID},
        }
        self.save()

    def save(self):
        (self.root / "fleet.json").write_text(json.dumps(self.state), encoding="utf-8")

    def run_promote(self, *args, dry_run=False):
        env = {**os.environ, "FAKE_ROOT": str(self.root), "PATH": f"{self.bin}:{os.environ['PATH']}"}
        if dry_run:
            env["DRY_RUN"] = "true"
        else:
            env.pop("DRY_RUN", None)
        result = subprocess.run(["bash", str(self.root / "promote.sh"), *(args or (SHA, APP_REF, VOICE_REF))],
                                env=env, capture_output=True, text=True, check=False, timeout=25)
        self.state = json.loads((self.root / "fleet.json").read_text(encoding="utf-8"))
        return result

    def trace(self, prefix):
        return [entry for entry in self.state["trace"] if entry[:len(prefix)] == prefix]

    def up(self, name):
        return [entry for entry in self.trace(["compose"]) if "up" in entry and entry[-1] == name]

    def assert_before_db(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.trace(["compose", "--env-file", str(self.root / ".env.production"),
                                     "-f", str(self.root / "docker-compose.production.yml"), "run"]))
        self.assertFalse(any("stop" in entry or "up" in entry for entry in self.state["trace"]))

    def test_three_argument_contract_and_dry_run(self):
        result = self.run_promote(SHA, APP_REF)
        self.assertEqual(result.returncode, 64)
        result = self.run_promote(dry_run=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("voice_image=" + VOICE_REF, result.stdout)
        self.assertFalse(any(entry[0] in ("pull", "run", "tag") for entry in self.state["trace"]))
        self.assertEqual(self.state["fleet"]["onelink_ai_voice"]["image"], OLD_VOICE_ID)
        self.assertEqual((self.root / ".env.production").read_text(), "CHATWOOT_IMAGE=old\nONELINK_AI_VOICE_IMAGE=old\n")

    def test_t2_refused_before_database_even_with_bridge_marker(self):
        self.state["target_t2"] = True
        self.save()
        result = self.run_promote()
        self.assert_before_db(result)
        self.assertIn("NEEDS_BUSINESS: T2", result.stderr)

    def test_workflow_passes_exact_three_arguments(self):
        workflow = SCRIPT.parents[2] / ".github/workflows/onelink_promote_production.yml"
        self.assertIn('"promote $RELEASE_SHA $IMAGE_REF $VOICE_IMAGE_REF"', workflow.read_text(encoding="utf-8"))

    def test_missing_fenced_target_refused_before_database(self):
        self.state["target_fences"] = False
        self.save()
        result = self.run_promote()
        self.assert_before_db(result)
        self.assertIn("lacks both fenced consumer", result.stderr)

    def test_rejects_mixed_fleet_applied_t2_and_bad_compose_plan(self):
        for mutation in (lambda s: s["fleet"]["chatwoot_rails_2"].update(sha="c" * 40),
                         lambda s: s.update(db_phase="present"),
                         lambda s: s.update(bridge_tag=True),
                         lambda s: s.update(bad_inventory=True)):
            with self.subTest(mutation=mutation):
                original = json.loads(json.dumps(self.state))
                mutation(self.state)
                self.save()
                self.assert_before_db(self.run_promote())
                self.state = original
                self.save()

    def test_success_retires_both_consumers_before_any_new_producer_and_promotes_voice(self):
        result = self.run_promote()
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = self.state["trace"]
        stops = [i for i, entry in enumerate(entries) if "stop" in entry]
        ups = [i for i, entry in enumerate(entries) if "up" in entry]
        self.assertEqual([entries[i][-1] for i in stops], list(FENCED))
        self.assertEqual([entries[i][-1] for i in ups[:2]], list(FENCED))
        self.assertLess(max(stops), min(ups))
        self.assertLess(ups[1], next(i for i, entry in enumerate(entries) if "up" in entry and entry[-1] == "chatwoot_captain_runtime_worker"))
        self.assertEqual(entries[ups[-1]][-1], "onelink_ai_voice")
        self.assertTrue(any("script/onelink/finalize_release.rb" in entry for entry in entries))
        self.assertEqual((self.root / ".env.production").read_text(),
                         f"CHATWOOT_IMAGE={APP_REF}\nONELINK_AI_VOICE_IMAGE={VOICE_REF}\n")
        self.assertTrue(all(entry["sha"] == SHA and entry["status"] == "running" for entry in self.state["fleet"].values()))

    def test_partial_consumer_upgrade_never_restores_legacy_consumers(self):
        self.state.update(fail_up=FENCED[1], partial_up=True)
        self.save()
        result = self.run_promote()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("mixed-version/operator gate", result.stderr)
        self.assertFalse(self.up("chatwoot_captain_runtime_worker"))
        self.assertEqual(self.state["fleet"][FENCED[0]]["image"], NEW_APP_ID)
        self.assertNotEqual(self.state["fleet"][FENCED[1]]["status"], "running")
        self.assertFalse(any("onelink-chatwoot-rollback:" in str(entry) and entry[-1] in FENCED for entry in self.state["trace"]))
        self.assertEqual((self.root / ".env.production").read_text(), "CHATWOOT_IMAGE=old\nONELINK_AI_VOICE_IMAGE=old\n")

    def test_failed_stop_prevents_new_producers_and_reports_operator_gate(self):
        self.state.update(fail_stop=FENCED[0], partial_stop=True)
        self.save()
        result = self.run_promote()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("mixed-version/operator gate", result.stderr)
        self.assertFalse(any("up" in entry for entry in self.state["trace"]))
        self.assertNotEqual(self.state["fleet"][FENCED[0]]["status"], "running")

    def test_persistent_stop_failure_is_not_reported_as_safe_rollback(self):
        self.state.update(fail_stop=FENCED[0], fail_stop_always=True)
        self.save()
        result = self.run_promote()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("safe recovery verification failed", result.stderr)
        self.assertIn("mixed-version/operator gate", result.stderr)
        self.assertFalse(any("up" in entry for entry in self.state["trace"]))

    def test_unreadable_t2_database_phase_refuses_prepare(self):
        self.state["fail_db_read"] = True
        self.save()
        result = self.run_promote()
        self.assert_before_db(result)
        self.assertIn("database T2 phase is unprovable", result.stderr)

    def test_failure_after_new_producer_restores_web_but_keeps_new_fences(self):
        self.state.update(fail_up="chatwoot_rails", partial_up=True)
        self.save()
        result = self.run_promote()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("mixed-version/operator gate", result.stderr)
        for name in FENCED:
            self.assertEqual(self.state["fleet"][name]["image"], NEW_APP_ID)
        for name in ("chatwoot_rails", "chatwoot_rails_2"):
            self.assertEqual(self.state["fleet"][name]["image"], OLD_APP_ID)
        self.assertEqual(self.state["fleet"]["chatwoot_captain_runtime_worker"]["image"], NEW_APP_ID)
        self.assertEqual(self.state["fleet"]["onelink_ai_voice"]["image"], OLD_VOICE_ID)

    def test_post_voice_finalizer_failure_restores_voice_without_unfencing(self):
        self.state["fail_finalizer"] = True
        self.save()
        result = self.run_promote()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("mixed-version/operator gate", result.stderr)
        self.assertTrue(self.up("onelink_ai_voice"))
        self.assertEqual(self.state["fleet"]["onelink_ai_voice"]["image"], OLD_VOICE_ID)
        self.assertEqual(self.state["fleet"][FENCED[0]]["image"], NEW_APP_ID)
        self.assertEqual((self.root / ".env.production").read_text(), "CHATWOOT_IMAGE=old\nONELINK_AI_VOICE_IMAGE=old\n")

    def test_database_prepare_failure_leaves_runtime_unchanged(self):
        self.state["fail_prepare"] = True
        self.save()
        result = self.run_promote()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(any("up" in entry or "stop" in entry for entry in self.state["trace"]))
        self.assertTrue(all(entry["sha"] == OLD_SHA for entry in self.state["fleet"].values()))


if __name__ == "__main__":
    unittest.main()

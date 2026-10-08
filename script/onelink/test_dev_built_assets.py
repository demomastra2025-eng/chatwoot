"""DEV artifact and restricted prebuild/deployment contracts (no services/builds)."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_built_assets as assets

ROOT = Path(__file__).resolve().parents[2]
SHA = "1" * 40


class BuiltAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "artifact"
        self.release = Path(self.temp.name) / "release"
        (self.root / "public/vite/.vite").mkdir(parents=True)
        (self.root / "public/vite/assets").mkdir()
        (self.root / "public/packs/js").mkdir(parents=True)
        (self.root / "public/packs/js/sdk.js").write_text("sdk", encoding="utf-8")
        self.manifest = {}
        for name in assets.ENTRYPOINTS:
            file = f"assets/{name}-abc.js"
            (self.root / "public/vite" / file).write_text(name, encoding="utf-8")
            self.manifest[f"entrypoints/{name}.js"] = {"file": file, "isEntry": True}
        self.write_manifest()
        (self.root / "public/vite/.vite/manifest-assets.json").write_text("{}", encoding="utf-8")
        (self.release / "lib/onelink").mkdir(parents=True)
        (self.release / "lib/onelink/dev_runtime.rb").write_text(assets.CONTRACT, encoding="utf-8")
        self.seal()

    def tearDown(self):
        self.temp.cleanup()

    def write_manifest(self):
        (self.root / "public/vite/.vite/manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def seal(self):
        assets.manifest(self.root)
        proof = {"version": 1, "git_sha": SHA, "mode": "production", "files": assets.inventory(self.root)}
        (self.root / assets.PROOF).write_text(json.dumps(proof), encoding="utf-8")

    def test_consumes_exact_sha_and_supports_same_sha_redeployment(self):
        assets.install(self.root, SHA, self.release)
        first = assets.verify(self.release, SHA)
        assets.install(self.root, SHA, self.release)
        self.assertEqual(assets.verify(self.release, SHA), first)

    def test_wrong_sha_and_mode_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "SHA/mode"):
            assets.verify(self.root, "2" * 40)
        proof = json.loads((self.root / assets.PROOF).read_text())
        proof["mode"] = "development"
        (self.root / assets.PROOF).write_text(json.dumps(proof), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "SHA/mode"):
            assets.verify(self.root, SHA)

    def test_tampering_or_additional_files_are_rejected(self):
        target = self.root / "public/vite/assets/dashboard-abc.js"
        target.write_text("tampered", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            assets.verify(self.root, SHA)
        target.write_text("dashboard", encoding="utf-8")
        (self.root / "public/vite/unsealed.js").write_text("extra", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "inventory"):
            assets.verify(self.root, SHA)

    def test_all_entrypoints_sdk_and_both_manifests_are_required(self):
        for relative in ("public/packs/js/sdk.js", "public/vite/.vite/manifest-assets.json"):
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(ValueError):
                    assets.verify(self.root, SHA)
                path.write_bytes(original)
        del self.manifest["entrypoints/portal.js"]
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "portal"):
            assets.verify(self.root, SHA)

    def test_css_assets_and_imports_must_resolve(self):
        entry = self.manifest["entrypoints/dashboard.js"]
        for key, value in (("css", "assets/missing.css"), ("assets", "assets/missing.png"),
                           ("imports", "missing.js"), ("dynamicImports", "missing.js")):
            with self.subTest(key=key):
                entry[key] = [value]
                self.write_manifest()
                with self.assertRaises(ValueError):
                    assets.manifest(self.root)
                del entry[key]

    def test_path_traversal_and_symlinks_are_rejected(self):
        self.manifest["entrypoints/dashboard.js"]["file"] = "../../escape.js"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "unsafe"):
            assets.manifest(self.root)
        self.manifest["entrypoints/dashboard.js"]["file"] = "assets/dashboard-abc.js"
        self.write_manifest()
        # Git Bash can create symlinks only on Windows hosts with suitable permissions.
        link = self.root / "public/vite/assets/link.js"
        try:
            link.symlink_to("dashboard-abc.js")
        except OSError:
            return
        with self.assertRaisesRegex(ValueError, "symlink"):
            assets.verify(self.root, SHA)

    def test_incompatible_rollback_and_unsealed_destinations_are_rejected(self):
        source = self.release / "lib/onelink/dev_runtime.rb"
        source.write_text("old runtime", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "flags off"):
            assets.install(self.root, SHA, self.release)
        source.write_text(assets.CONTRACT, encoding="utf-8")
        (self.release / "public/vite").mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "unsealed"):
            assets.install(self.root, SHA, self.release)

    def test_same_sha_does_not_repair_tampered_live_assets(self):
        assets.install(self.root, SHA, self.release)
        target = self.release / "public/packs/js/sdk.js"
        target.write_text("changed live", encoding="utf-8")
        with self.assertRaises(ValueError):
            assets.install(self.root, SHA, self.release)
        self.assertEqual(target.read_text(), "changed live")

    def test_public_urls_have_expected_content_hashes(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with contextlib.ExitStack() as stack:
                original = sys.argv
                stack.callback(setattr, sys, "argv", original)
                sys.argv = ["assets", "urls", str(self.root), SHA]
                self.assertEqual(assets.main(), 0)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), len(assets.ENTRYPOINTS) + 1)
        self.assertTrue(any(line.startswith("/packs/js/sdk.js ") for line in lines))
        self.assertTrue(any(line.startswith("/vite/assets/dashboard-abc.js ") for line in lines))


class DeploymentContractTest(unittest.TestCase):
    def bash(self):
        bash = shutil.which("bash")
        if not bash or os.name == "nt":
            # Windows Store bash is WSL's missing-runtime stub, use Git Bash.
            bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else None
        if not bash or not Path(bash).exists():
            self.skipTest("bash not installed")
        return bash

    def test_preparation_default_off_and_mismatched_flags_fail_before_build(self):
        # Exercise the real env parser against isolated files, ending before any
        # build/git/service command. No production path or root privilege is used.
        source = (ROOT / "script/onelink/prepare_dev_assets.sh").read_text(encoding="utf-8")
        parser = source[source.index("# Parse the DEV file"):source.index('mkdir -p "${ARTIFACTS}"')]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "runtime").mkdir()
            env_file = root / ".env.development"
            fixture = root / "parse.sh"
            fixture.write_text("set -euo pipefail\nROOT=" + shlex.quote(root.as_posix()) +
                               "\nENV_FILE=\"${ROOT}/.env.development\"\nDEV_TOOLCHAIN_PATH=\"$PATH\"\nconfigure_toolchain() { :; }\n" + parser,
                               encoding="utf-8", newline="\n")
            env = dict(os.environ)
            for key in ("ONELINK_DEV_BUILT_ASSETS", "RAILS_ENV", "NODE_ENV", "POSTGRES_DATABASE"):
                env.pop(key, None)
            for flag_file, flag, rails_env, database, expected in (
                (False, "", "development", "chatwoot_dev", 0),
                (False, "0", "development", "chatwoot_dev", 0),
                (False, "1", "development", "chatwoot_dev", 65),
                (True, "0", "development", "chatwoot_dev", 65),
                (False, "true", "development", "chatwoot_dev", 65),
                (False, "0", "production", "chatwoot_dev", 65),
                (False, "0", "development", "chatwoot_production", 65),
            ):
                with self.subTest(flag_file=flag_file, flag=flag, rails_env=rails_env, database=database):
                    marker = root / "runtime/built-assets.enabled"
                    if flag_file:
                        marker.touch()
                    else:
                        marker.unlink(missing_ok=True)
                    env_file.write_text(f"RAILS_ENV={rails_env}\nPOSTGRES_DATABASE={database}\n" +
                                        (f"ONELINK_DEV_BUILT_ASSETS={flag}\n" if flag else ""), encoding="utf-8", newline="\n")
                    result = subprocess.run([self.bash(), str(fixture)], env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected == 0:
                        self.assertIn("no build required", result.stdout)

    def test_preparation_and_deployment_share_the_versioned_toolchain(self):
        contracts = []
        for name in ("prepare_dev_assets.sh", "deploy_dev_release.sh"):
            source = (ROOT / "script/onelink" / name).read_text(encoding="utf-8")
            start = source.index("readonly RBENV_ROOT=")
            end = source.index("\nconfigure_toolchain\n", start)
            contract = source[start:end]
            contracts.append(contract)
            self.assertIn("readonly DEV_NODE_ROOT=/opt/node-24", contract)
            self.assertIn("readonly DEV_RUBY_VERSION=3.4.4", contract)
            self.assertIn('${DEV_NODE_ROOT}/bin:${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:', contract)
            self.assertIn('"$(node --version)" == v24.*', contract)
            self.assertIn('"$(pnpm --version)" == 10.*', contract)
            self.assertIn('RBENV_VERSION="${DEV_RUBY_VERSION}"', contract)
        self.assertEqual(contracts[0], contracts[1])

    def test_workflow_prepares_before_deploy_and_checks_installed_tools(self):
        workflow = (ROOT / ".github/workflows/onelink_release.yml").read_text(encoding="utf-8")
        prepare = workflow.index('"prepare-assets $GITHUB_SHA"')
        deploy = workflow.index('"$DEPLOY_VERB $GITHUB_SHA"')
        self.assertLess(workflow.index("'asset-tools-sha256'"), prepare)
        self.assertLess(prepare, deploy)
        self.assertIn("script/onelink/prepare_dev_assets.sh script/onelink/dev_built_assets.py", workflow)

    def test_deployment_consumes_artifact_before_worker_stop_without_build(self):
        deploy = (ROOT / "script/onelink/deploy_dev_release.sh").read_text(encoding="utf-8")
        self.assertNotIn("bin/vite build", deploy)
        self.assertNotIn("/root/work/e-heavy.sh", deploy)
        self.assertLess(deploy.index('"${ASSET_TOOL}" install'), deploy.index('systemctl stop "${WORKER_SERVICES[@]}"'))
        self.assertLess(deploy.index('"${ASSET_TOOL}" verify "${PREVIOUS}"'), deploy.index('systemctl stop "${WORKER_SERVICES[@]}"'))
        self.assertIn('verify_asset_http "${PREVIOUS}"', deploy)
        self.assertIn('[[ "${actual}" == "${expected}" ]]', deploy)
        self.assertNotIn("already deployed", deploy.lower())

    def test_forced_preparation_uses_existing_gate_and_rejects_shell_input(self):
        bash = self.bash()
        script = ROOT / "script/onelink/dev_forced_command.sh"
        with tempfile.TemporaryDirectory() as temp:
            fake = Path(temp) / "sudo"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n', encoding="utf-8")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{temp}{os.pathsep}{os.environ.get('PATH', '')}")
            env["SSH_ORIGINAL_COMMAND"] = f"prepare-assets {SHA}"
            result = subprocess.run([bash, str(script)], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["--non-interactive", "/root/work/e-heavy.sh",
                                                        "/usr/local/sbin/onelink-dev-prepare-assets", SHA])
            for command in (f"prepare-assets {SHA}; id", f"prepare-assets {SHA} extra", "prepare-assets short", "bash"):
                env["SSH_ORIGINAL_COMMAND"] = command
                result = subprocess.run([bash, str(script)], env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 64, command)


if __name__ == "__main__":
    unittest.main()

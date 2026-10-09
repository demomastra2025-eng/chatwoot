import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import retain_previous_vite_assets as assets


SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40
APP_DIGEST_A = "1" * 64
APP_DIGEST_B = "2" * 64
APP_DIGEST_C = "3" * 64
VOICE_IMAGE = f"{assets.VOICE_IMAGE_REPOSITORY}@sha256:{'4' * 64}"


def deployment(identifier, sha, app_digest, *, states=("success",), payload=None, environment="production"):
    return {
        "id": identifier,
        "sha": sha,
        "environment": environment,
        "payload": payload or {
            "image": f"{assets.APP_IMAGE_REPOSITORY}@sha256:{app_digest}",
            "voice_image": VOICE_IMAGE,
        },
        "statuses": [{"state": state} for state in states],
    }


def tar_stream(members):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as archive:
        for name, content, member_type in members:
            info = tarfile.TarInfo(name)
            info.type = member_type
            if member_type == tarfile.REGTYPE:
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
            else:
                info.linkname = "target.js"
                archive.addfile(info)
    stream.seek(0)
    return stream


class ProductionProofSelectionTest(unittest.TestCase):
    def select(self, rows):
        by_id = {row["id"]: row for row in rows}
        deployment_pages = {1: rows}
        return assets.select_previous_images(
            lambda page: deployment_pages.get(page, []),
            lambda identifier: by_id[identifier]["statuses"],
        )

    def test_successful_inactive_deployment_is_retained_when_it_has_success_history(self):
        previous = deployment(10, SHA_A, APP_DIGEST_A, states=("inactive", "success"))

        selected = self.select([previous])

        self.assertEqual(selected, [{
            "sha": SHA_A,
            "image": f"{assets.APP_IMAGE_REPOSITORY}@sha256:{APP_DIGEST_A}",
            "digest": APP_DIGEST_A,
        }])

    def test_latest_success_qualifies_but_latest_failure_error_or_pending_do_not(self):
        deployments = [
            deployment(1, SHA_A, APP_DIGEST_A, states=("success",)),
            deployment(2, SHA_B, APP_DIGEST_B, states=("failure", "success")),
            deployment(3, SHA_C, APP_DIGEST_C, states=("error", "success")),
        ]
        statuses = {
            1: [{"state": "success"}],
            2: [{"state": "failure"}, {"state": "success"}],
            3: [{"state": "error"}, {"state": "success"}],
        }
        selected = assets.select_previous_images(
            lambda page: deployments if page == 1 else [],
            lambda identifier: statuses[identifier],
        )

        self.assertEqual([item["sha"] for item in selected], [SHA_A])
        self.assertFalse(assets.deployment_qualifies([{"state": "pending"}, {"state": "success"}]))

    def test_selects_two_distinct_shas_and_uses_the_newest_success_for_repeated_sha(self):
        deployments = [
            deployment(1, SHA_A, APP_DIGEST_A),
            deployment(2, SHA_A, APP_DIGEST_B, states=("inactive", "success")),
            deployment(3, SHA_B, APP_DIGEST_C),
            deployment(4, SHA_C, "5" * 64),
        ]
        selected = self.select(deployments)

        self.assertEqual([item["sha"] for item in selected], [SHA_A, SHA_B])
        self.assertEqual(selected[0]["digest"], APP_DIGEST_A)

    def test_empty_production_history_is_a_valid_bootstrap(self):
        self.assertEqual(self.select([]), [])

    def test_successful_deployment_with_bad_payload_fails_closed(self):
        bad = deployment(1, SHA_A, APP_DIGEST_A, payload={
            "image": "ghcr.io/attacker/chatwoot@sha256:" + APP_DIGEST_A,
            "voice_image": VOICE_IMAGE,
        })

        with self.assertRaisesRegex(ValueError, "canonical repository/digest"):
            self.select([bad])

    def test_successful_deployment_requires_valid_voice_proof_shape(self):
        bad = deployment(1, SHA_A, APP_DIGEST_A, payload={
            "image": f"{assets.APP_IMAGE_REPOSITORY}@sha256:{APP_DIGEST_A}",
            "voice_image": "ghcr.io/attacker/voice:dev",
        })

        with self.assertRaisesRegex(ValueError, "voice image proof"):
            self.select([bad])

    def test_unrelated_environment_is_not_selected(self):
        row = deployment(1, SHA_A, APP_DIGEST_A, environment="development")
        self.assertEqual(self.select([row]), [])


class ViteManifestTest(unittest.TestCase):
    def test_collects_only_referenced_files_from_both_runtime_catalogs(self):
        current = {
            "entrypoints/dashboard.js": {
                "file": "assets/dashboard-entry.js",
                "isEntry": True,
                "imports": ["chunks/shared.js"],
                "dynamicImports": ["chunks/lazy.js"],
                "css": ["assets/dashboard.css"],
                "assets": ["assets/icon.svg"],
            },
            "chunks/shared.js": {"file": "assets/shared.js"},
            "chunks/lazy.js": {"file": "assets/lazy.js"},
            "ignored.html": {"file": "ignored.html"},
            "sw.js": {"file": "assets/sw-abc.js"},
            "manifest": {"file": ".vite/manifest.json"},
        }
        rails_assets = {"rails/logo.svg": {"file": "assets/rails-logo.svg"}}

        result = assets.manifest_references([current, rails_assets])

        self.assertEqual(result, [
            "assets/dashboard-entry.js",
            "assets/dashboard.css",
            "assets/icon.svg",
            "assets/lazy.js",
            "assets/rails-logo.svg",
            "assets/shared.js",
        ])

    def test_rejects_manifest_traversal_absolute_paths_and_windows_paths(self):
        for value in ("../secret.js", "assets/../../secret.js", "/etc/passwd", r"assets\secret.js", "C:/secret.js"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                assets.safe_asset_path(value)

    def test_rejects_dangling_manifest_imports(self):
        with self.assertRaisesRegex(ValueError, "dynamicImports"):
            assets.manifest_references([{"entry.js": {"file": "entry.js", "dynamicImports": ["missing.js"]}}])

    def test_enforces_manifest_file_count_limit(self):
        manifest = {f"source-{index}.js": {"file": f"assets/{index}.js"} for index in range(2)}
        with patch.object(assets, "MAX_FILES", 1), self.assertRaisesRegex(ValueError, "file limit"):
            assets.manifest_references([manifest])


class DockerCopyTarTest(unittest.TestCase):
    def test_reads_one_regular_file_without_extracting_archive_paths(self):
        content = assets.extract_single_regular_tar(
            tar_stream([("dashboard.js", b"safe bytes", tarfile.REGTYPE)]),
            "public/vite/assets/dashboard.js",
            100,
        )

        self.assertEqual(content, b"safe bytes")

    def test_rejects_traversal_symlink_extra_members_and_size_overflow(self):
        cases = [
            ([("../dashboard.js", b"x", tarfile.REGTYPE)], 100),
            ([("dashboard.js", b"", tarfile.SYMTYPE)], 100),
            ([
                ("dashboard.js", b"x", tarfile.REGTYPE),
                ("extra.js", b"y", tarfile.REGTYPE),
            ], 100),
            ([("dashboard.js", b"four", tarfile.REGTYPE)], 3),
        ]
        for members, byte_limit in cases:
            with self.subTest(members=members), self.assertRaises(ValueError):
                assets.extract_single_regular_tar(
                    tar_stream(members), "public/vite/assets/dashboard.js", byte_limit
                )


class RetainedOutputTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name) / "staging"
        self.output.mkdir()
        (self.output / ".keep").write_text("", encoding="utf-8")
        assets.reset_output(self.output)

    @staticmethod
    def image(digest):
        return f"{assets.APP_IMAGE_REPOSITORY}@sha256:{digest}"

    def test_resets_only_managed_output_and_keeps_bootstrap_marker(self):
        old_file = self.output / "public" / "vite" / "assets" / "old.js"
        old_file.parent.mkdir(parents=True)
        old_file.write_bytes(b"old")
        assets.reset_output(self.output)

        self.assertTrue((self.output / ".keep").is_file())
        self.assertFalse(old_file.exists())
        self.assertEqual(json.loads((self.output / "origins.json").read_text(encoding="utf-8")), {
            "version": 1,
            "versions": [],
        })

    def test_merges_identical_old_asset_bytes_and_records_sha_digest_hashes(self):
        assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {"assets/shared.js": b"shared"})
        assets.merge_assets(self.output, SHA_B, self.image(APP_DIGEST_B), {"assets/shared.js": b"shared"})

        self.assertEqual((self.output / "public/vite/assets/shared.js").read_bytes(), b"shared")
        origins = json.loads((self.output / "origins.json").read_text(encoding="utf-8"))
        self.assertEqual([item["sha"] for item in origins["versions"]], [SHA_A, SHA_B])
        self.assertEqual(origins["versions"][0]["files"]["assets/shared.js"]["sha256"],
                         hashlib.sha256(b"shared").hexdigest())
        self.assertNotIn("token", (self.output / "origins.json").read_text(encoding="utf-8"))

    def test_old_image_conflict_fails_before_adding_any_files(self):
        assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {"assets/z.js": b"old"})

        with self.assertRaisesRegex(ValueError, "conflicts with an earlier image"):
            assets.merge_assets(self.output, SHA_B, self.image(APP_DIGEST_B), {
                "assets/a.js": b"new",
                "assets/z.js": b"different",
            })

        self.assertFalse((self.output / "public/vite/assets/a.js").exists())

    def test_file_count_and_total_byte_caps_are_enforced(self):
        with patch.object(assets, "MAX_FILES", 1), self.assertRaisesRegex(ValueError, "file count"):
            assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {
                "assets/a.js": b"a",
                "assets/b.js": b"b",
            })
        with patch.object(assets, "MAX_TOTAL_BYTES", 3), self.assertRaisesRegex(ValueError, "total byte"):
            assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {
                "assets/a.js": b"aa",
                "assets/b.js": b"bb",
            })

    def test_same_sha_with_different_image_digest_is_rejected(self):
        assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {"assets/a.js": b"a"})
        with self.assertRaisesRegex(ValueError, "conflicting immutable image digests"):
            assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_B), {"assets/a.js": b"a"})

    def test_same_sha_and_digest_cannot_be_collected_twice(self):
        assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {"assets/a.js": b"a"})
        with self.assertRaisesRegex(ValueError, "already collected"):
            assets.merge_assets(self.output, SHA_A, self.image(APP_DIGEST_A), {"assets/a.js": b"a"})

    def test_current_collision_with_different_bytes_fails_before_copying_anything(self):
        current = Path(self.temporary.name) / "current"
        current.mkdir()
        (current / "assets").mkdir()
        (current / "assets/z.js").write_bytes(b"current")
        retained = Path(self.temporary.name) / "retained"
        (retained / "assets").mkdir(parents=True)
        (retained / "assets/a.js").write_bytes(b"new")
        (retained / "assets/z.js").write_bytes(b"old")

        with self.assertRaisesRegex(ValueError, "conflicts with current build"):
            assets.merge_staged_into_current(current, retained)

        self.assertFalse((current / "assets/a.js").exists())
        self.assertEqual((current / "assets/z.js").read_bytes(), b"current")

    def test_current_identical_collision_is_allowed_without_overwriting(self):
        current = Path(self.temporary.name) / "current"
        current.mkdir()
        (current / "assets").mkdir()
        (current / "assets/shared.js").write_bytes(b"same")
        retained = Path(self.temporary.name) / "retained"
        (retained / "assets").mkdir(parents=True)
        (retained / "assets/shared.js").write_bytes(b"same")
        (retained / "assets/old.js").write_bytes(b"old")

        assets.merge_staged_into_current(current, retained)

        self.assertEqual((current / "assets/shared.js").read_bytes(), b"same")
        self.assertEqual((current / "assets/old.js").read_bytes(), b"old")

    def test_current_merge_rejects_symlink_inputs(self):
        current = Path(self.temporary.name) / "current"
        current.mkdir()
        retained = Path(self.temporary.name) / "retained"
        retained.mkdir()
        (retained / "linked.js").symlink_to(current)

        with self.assertRaisesRegex(ValueError, "symlink"):
            assets.merge_staged_into_current(current, retained)


if __name__ == "__main__":
    unittest.main()

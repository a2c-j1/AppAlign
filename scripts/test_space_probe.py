#!/usr/bin/env python3
"""Guard and child-lifecycle tests; never supply a fake OS to the native helper."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
MODULE_SPEC = importlib.util.spec_from_file_location("space_probe_wrapper", ROOT / "scripts" / "space-probe.py")
assert MODULE_SPEC and MODULE_SPEC.loader
probe = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(probe)


class SpaceProbeGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        developer = subprocess.run(
            ["/usr/bin/xcode-select", "-p"], check=True, capture_output=True, text=True, timeout=2
        ).stdout.strip()
        cls.fixture_directory = tempfile.TemporaryDirectory(prefix="appalign-space-probe-fixtures-")
        cls.fixture_binary = Path(cls.fixture_directory.name) / "space-probe-fixtures"
        compiler = Path(developer) / "Toolchains" / "XcodeDefault.xctoolchain" / "usr" / "bin" / "swiftc"
        sdk = Path(developer) / "Platforms" / "MacOSX.platform" / "Developer" / "SDKs" / "MacOSX26.5.sdk"
        subprocess.run(
            [
                str(compiler),
                "-swift-version",
                "6",
                "-sdk",
                str(sdk),
                "-target",
                "arm64-apple-macosx26.0",
                str(ROOT / "scripts" / "space-probe-core.swift"),
                str(ROOT / "scripts" / "test-space-probe-fixtures.swift"),
                "-o",
                str(cls.fixture_binary),
            ],
            check=True,
            capture_output=True,
            timeout=60,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture_directory.cleanup()

    def test_native_pure_metadata_and_type_fixtures(self) -> None:
        result = subprocess.run(
            [str(self.fixture_binary)], check=False, capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Space probe pure fixtures passed", result.stdout)

    def test_pure_guard_requires_allowlisted_major_and_exact_build(self) -> None:
        self.assertIsNone(probe.evaluate_os_guard(27, "26A434", 27, "26A434"))
        self.assertEqual(probe.evaluate_os_guard(27, "26A434", 26, "26A434"), "unsupported_expected_os_major")
        self.assertEqual(probe.evaluate_os_guard(26, "23G93", 27, "23G93"), "unsupported_os_major")
        self.assertEqual(probe.evaluate_os_guard(27, "26A434", 27, "26A435"), "build_mismatch_or_unavailable")

    def test_runtime_mismatch_refuses_before_compiling_or_starting_private_helper(self) -> None:
        with mock.patch.object(probe, "read_running_os", return_value=(27, "26A434")):
            with mock.patch.object(probe, "compile_helper") as compile_helper:
                record, exit_code = probe.run_probe(27, "26A435", "A1B2C3D4-0000-1111-2222-123456789ABC")
        self.assertEqual(exit_code, 2)
        self.assertEqual(record["error"], "build_mismatch_or_unavailable")
        self.assertFalse(record["adoption"])
        compile_helper.assert_not_called()

    def test_cli_help_and_argument_errors(self) -> None:
        help_result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "space-probe.py"), "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--expected-os-major 27", help_result.stdout)

        missing = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "space-probe.py")],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(json.loads(missing.stdout)["error"], "invalid_arguments")

        invalid_uuid = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "space-probe.py"),
                "--expected-os-major",
                "27",
                "--expected-build",
                "26A434",
                "--display-uuid",
                "not-a-display-uuid",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(invalid_uuid.returncode, 2)
        self.assertEqual(json.loads(invalid_uuid.stdout)["error"], "invalid_display_uuid")

    def test_wrapper_reports_real_host_guard_without_invoking_helper(self) -> None:
        actual_major, actual_build = probe.read_running_os()
        if actual_major == 27 and actual_build:
            expected_major, expected_build = 26, actual_build
            expected_error = "unsupported_expected_os_major"
        else:
            expected_major, expected_build = 27, "not-the-real-build"
            expected_error = "unsupported_os_major" if actual_major != 27 else "build_mismatch_or_unavailable"

        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts" / "space-probe.py"),
                "--expected-os-major",
                str(expected_major),
                "--expected-build",
                expected_build,
                "--display-uuid",
                "A1B2C3D4-0000-1111-2222-123456789ABC",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
        self.assertEqual(result.returncode, 2)
        output = json.loads(result.stdout)
        self.assertEqual(output["error"], expected_error)
        self.assertFalse(output["adoption"])

    def test_timeout_kills_and_reaps_only_the_direct_dummy_child(self) -> None:
        commands = [
            "import time; time.sleep(30)",
            "import os, time; os.close(1); time.sleep(30)",
        ]
        for command in commands:
            with self.subTest(command=command):
                result = probe.run_child([sys.executable, "-c", command])
                self.assertEqual(result.error, "timeout")
                self.assertIsNotNone(result.pid)
                self.assertIsNotNone(result.returncode)
                with self.assertRaises(ProcessLookupError):
                    os.kill(result.pid, 0)

    def test_oversized_child_output_is_not_forwarded(self) -> None:
        result = probe.run_child([sys.executable, "-c", "print('x' * 10000)"])
        self.assertEqual(result.error, "helper_output_too_large")
        self.assertIsNotNone(result.returncode)
        self.assertEqual(result.payload, b"")

    def test_list_child_output_limit_is_larger_but_bounded(self) -> None:
        accepted = probe.run_child([sys.executable, "-c", "import sys; sys.stdout.write('x' * 8000)"],
                                   max_stdout=probe.MAX_LIST_CHILD_STDOUT)
        self.assertIsNone(accepted.error)
        self.assertEqual(len(accepted.payload), 8000)
        rejected = probe.run_child([sys.executable, "-c", "import sys; sys.stdout.write('x' * 17000)"],
                                   max_stdout=probe.MAX_LIST_CHILD_STDOUT)
        self.assertEqual(rejected.error, "helper_output_too_large")
        self.assertEqual(rejected.payload, b"")

    def test_wrapper_validates_type_kind_uuid_and_exact_fields(self) -> None:
        expected_uuid = "D16814E6-E4F8-4D8F-0857-D6964E3302DB"

        def payload(raw_type: int | None, kind: str, candidate: str | None) -> dict[str, object]:
            return {
                "osMajor": 27,
                "build": "26A434",
                "displayUUID": expected_uuid,
                "rawSpaceID": "41",
                "kind": kind,
                "error": None,
                "adoption": False,
                "rawSpaceType": raw_type,
                "spaceUUIDCandidate": candidate,
            }

        for raw_type, kind in [(0, "user"), (2, "system"), (4, "fullscreen")]:
            record = probe.validate_helper_payload(
                json.dumps(payload(raw_type, kind, expected_uuid)).encode(), 0, 27, "26A434", expected_uuid
            )
            self.assertIsNone(record["error"])
            self.assertEqual(record["kind"], kind)
            self.assertFalse(record["adoption"])

        unsupported = payload(3, "unknown", expected_uuid)
        unsupported["error"] = "unsupported_space_type"
        record = probe.validate_helper_payload(json.dumps(unsupported).encode(), 3, 27, "26A434", expected_uuid)
        self.assertEqual(record["error"], "unsupported_space_type")
        self.assertEqual(record["kind"], "unknown")

        invalid_payloads = []
        unknown_field = payload(0, "user", expected_uuid)
        unknown_field["extra"] = "ignored-fields-must-not-be-forwarded"
        invalid_payloads.append(unknown_field)
        invalid_payloads.append(payload(0, "system", expected_uuid))
        invalid_uuid = payload(0, "user", "personal Space")
        invalid_payloads.append(invalid_uuid)
        invalid_payloads.append(payload(True, "user", expected_uuid))
        invalid_payloads.append(payload(None, "user", expected_uuid))
        for invalid in invalid_payloads:
            with self.subTest(payload=invalid):
                record = probe.validate_helper_payload(
                    json.dumps(invalid).encode(), 0, 27, "26A434", expected_uuid
                )
                self.assertEqual(record["error"], "invalid_helper_response")
                self.assertIsNone(record["spaceUUIDCandidate"])
                self.assertFalse(record["adoption"])

    def test_wrapper_validates_complete_list_schema_membership_and_uniqueness(self) -> None:
        display_uuid = "D16814E6-E4F8-4D8F-0857-D6964E3302DB"
        candidate_a = "06497333-89E6-B6A1-90A2-D67FCC9F9348"
        candidate_b = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        base = {
            "osMajor": 27, "build": "26A434", "displayUUID": display_uuid,
            "rawSpaceID": "41", "kind": "user", "error": None, "adoption": False,
            "rawSpaceType": 0, "spaceUUIDCandidate": candidate_a,
            "spaces": [
                {"rawSpaceID": "41", "rawSpaceType": 0, "kind": "user", "spaceUUIDCandidate": candidate_a, "error": None},
                {"rawSpaceID": "42", "rawSpaceType": 2, "kind": "system", "spaceUUIDCandidate": candidate_b, "error": None},
            ],
        }
        valid = probe.validate_helper_payload(json.dumps(base).encode(), 0, 27, "26A434", display_uuid,
                                              list_mode=True)
        self.assertIsNone(valid["error"])
        self.assertEqual(len(valid["spaces"]), 2)
        self.assertFalse(valid["adoption"])

        sixty_four = json.loads(json.dumps(base))
        sixty_four["spaces"] = []
        for index in range(64):
            item_id = str(41 + index)
            item_uuid = f"00000000-0000-0000-0000-{index + 1:012X}"
            item_type, item_kind = (0, "user") if index == 0 else (2, "system")
            sixty_four["spaces"].append({"rawSpaceID": item_id, "rawSpaceType": item_type,
                                          "kind": item_kind, "spaceUUIDCandidate": item_uuid, "error": None})
        sixty_four["spaceUUIDCandidate"] = sixty_four["spaces"][0]["spaceUUIDCandidate"]
        full = probe.validate_helper_payload(json.dumps(sixty_four).encode(), 0, 27, "26A434", display_uuid,
                                             list_mode=True)
        self.assertIsNone(full["error"])
        self.assertEqual(len(full["spaces"]), 64)

        variants = []
        duplicate_id = json.loads(json.dumps(base))
        duplicate_id["spaces"][1]["rawSpaceID"] = "41"
        variants.append(duplicate_id)
        duplicate_uuid = json.loads(json.dumps(base))
        duplicate_uuid["spaces"][1]["spaceUUIDCandidate"] = candidate_a
        variants.append(duplicate_uuid)
        wrong_kind = json.loads(json.dumps(base))
        wrong_kind["spaces"][1]["kind"] = "user"
        variants.append(wrong_kind)
        missing_current = json.loads(json.dumps(base))
        missing_current["spaces"][0]["rawSpaceID"] = "43"
        variants.append(missing_current)
        current_type_mismatch = json.loads(json.dumps(base))
        current_type_mismatch["spaces"][0]["rawSpaceType"] = 2
        current_type_mismatch["spaces"][0]["kind"] = "system"
        variants.append(current_type_mismatch)
        current_uuid_mismatch = json.loads(json.dumps(base))
        current_uuid_mismatch["spaces"][0]["spaceUUIDCandidate"] = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        variants.append(current_uuid_mismatch)
        extra_item_key = json.loads(json.dumps(base))
        extra_item_key["spaces"][0]["secret"] = "must not pass"
        variants.append(extra_item_key)
        too_many = json.loads(json.dumps(base))
        too_many["spaces"] = [dict(base["spaces"][0]) for _ in range(65)]
        variants.append(too_many)
        missing_spaces = dict(base)
        del missing_spaces["spaces"]
        variants.append(missing_spaces)
        for invalid in variants:
            with self.subTest(payload=invalid):
                record = probe.validate_helper_payload(json.dumps(invalid).encode(), 0, 27, "26A434",
                                                       display_uuid, list_mode=True)
                self.assertEqual(record["error"], "invalid_helper_response")
                self.assertFalse(record["adoption"])

        known_item_failure = json.loads(json.dumps(base))
        known_item_failure["spaces"][1]["spaceUUIDCandidate"] = None
        known_item_failure["spaces"][1]["error"] = "invalid_space_uuid"
        known_item_failure["error"] = "invalid_space_uuid"
        known_failure = probe.validate_helper_payload(json.dumps(known_item_failure).encode(), 3, 27, "26A434",
                                                      display_uuid, list_mode=True)
        self.assertEqual(known_failure["error"], "invalid_space_uuid")
        self.assertIsNone(known_failure["spaces"][1]["spaceUUIDCandidate"])

        current_item_failure = json.loads(json.dumps(base))
        current_item_failure["spaces"][0]["spaceUUIDCandidate"] = None
        current_item_failure["spaces"][0]["error"] = "invalid_space_uuid"
        current_item_failure["spaceUUIDCandidate"] = None
        current_item_failure["error"] = "invalid_space_uuid"
        current_failure = probe.validate_helper_payload(json.dumps(current_item_failure).encode(), 3, 27, "26A434",
                                                        display_uuid, list_mode=True)
        self.assertEqual(current_failure["error"], "invalid_space_uuid")
        self.assertIsNone(current_failure["spaceUUIDCandidate"])

        unknown_type = json.loads(json.dumps(base))
        unknown_type["spaces"][1].update({"rawSpaceType": 3, "kind": "unknown",
                                          "spaceUUIDCandidate": None, "error": "unsupported_space_type"})
        unknown_type["error"] = "unsupported_space_type"
        unknown_failure = probe.validate_helper_payload(json.dumps(unknown_type).encode(), 3, 27, "26A434",
                                                        display_uuid, list_mode=True)
        self.assertEqual(unknown_failure["error"], "unsupported_space_type")
        self.assertEqual(unknown_failure["spaces"][1]["kind"], "unknown")

        false_success = json.loads(json.dumps(known_item_failure))
        self.assertEqual(probe.validate_helper_payload(json.dumps(false_success).encode(), 0, 27, "26A434",
                                                       display_uuid, list_mode=True)["error"],
                         "invalid_helper_response")
        wrong_aggregate = json.loads(json.dumps(known_item_failure))
        wrong_aggregate["error"] = "unsupported_space_type"
        self.assertEqual(probe.validate_helper_payload(json.dumps(wrong_aggregate).encode(), 3, 27, "26A434",
                                                       display_uuid, list_mode=True)["error"],
                         "invalid_helper_response")

        rejected_in_normal_mode = probe.validate_helper_payload(json.dumps(base).encode(), 0, 27, "26A434",
                                                                display_uuid, list_mode=False)
        self.assertEqual(rejected_in_normal_mode["error"], "invalid_helper_response")


if __name__ == "__main__":
    unittest.main(verbosity=2)

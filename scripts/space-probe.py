#!/usr/bin/env python3
"""Guarded wrapper for the isolated, read-only SkyLight Space ID probe."""

from __future__ import annotations

import argparse
import json
import os
import re
import selectors
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
HELPER_SOURCE = ROOT / "scripts" / "space-probe.swift"
CORE_SOURCE = ROOT / "scripts" / "space-probe-core.swift"
HELPER_BINARY = ROOT / "build" / "issue-12-probe" / "space-probe"
ALLOWED_OS_MAJOR = 27
CHILD_TIMEOUT_SECONDS = 2.0
MAX_CHILD_STDOUT = 2048
ERROR_CODES = {
    "skylight_unavailable",
    "main_connection_symbol_missing",
    "current_space_symbol_missing",
    "main_connection_failed",
    "zero_space_id",
    "space_type_symbol_missing",
    "managed_display_spaces_symbol_missing",
    "space_copy_name_symbol_missing",
    "managed_display_spaces_unavailable",
    "invalid_display_metadata",
    "display_uuid_not_found",
    "ambiguous_display_uuid",
    "invalid_spaces_metadata",
    "invalid_space_id",
    "duplicate_space_id",
    "current_space_not_found",
    "ambiguous_current_space_id",
    "invalid_space_uuid",
    "space_changed_during_probe",
    "unsupported_space_type",
}


def result_record(
    os_major: int | None,
    build: str | None,
    display_uuid: str | None,
    raw_space_id: str | None,
    kind: str,
    error: str | None,
    raw_space_type: int | None = None,
    space_uuid_candidate: str | None = None,
) -> dict[str, Any]:
    return {
        "osMajor": os_major,
        "build": build,
        "displayUUID": display_uuid,
        "rawSpaceID": raw_space_id,
        "kind": kind,
        "error": error,
        "adoption": False,
        "rawSpaceType": raw_space_type,
        "spaceUUIDCandidate": space_uuid_candidate,
    }


def emit_result(record: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
    sys.stdout.flush()


def canonical_uuid(value: str) -> str | None:
    if len(value) != 36:
        return None
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError):
        return None


def evaluate_os_guard(
    actual_major: int | None,
    actual_build: str | None,
    expected_major: int,
    expected_build: str,
) -> str | None:
    """Pure guard: this probe is deliberately allowlisted to the verified major 27 host."""
    if expected_major != ALLOWED_OS_MAJOR:
        return "unsupported_expected_os_major"
    if actual_major != expected_major:
        return "unsupported_os_major"
    if not actual_build or actual_build != expected_build:
        return "build_mismatch_or_unavailable"
    return None


def read_running_os() -> tuple[int | None, str | None]:
    try:
        version = subprocess.run(
            ["/usr/bin/sw_vers", "-productVersion"],
            check=True,
            capture_output=True,
            text=True,
            timeout=1.0,
        ).stdout.strip()
        build = subprocess.run(
            ["/usr/bin/sw_vers", "-buildVersion"],
            check=True,
            capture_output=True,
            text=True,
            timeout=1.0,
        ).stdout.strip()
        major = int(version.split(".", maxsplit=1)[0])
        if not re.fullmatch(r"[A-Za-z0-9]+", build):
            return major, None
        return major, build
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, None


def developer_path() -> Path:
    developer = subprocess.run(
        ["/usr/bin/xcode-select", "-p"],
        check=True,
        capture_output=True,
        text=True,
        timeout=2.0,
    ).stdout.strip()
    return Path(developer)


def compile_helper() -> Path:
    HELPER_BINARY.parent.mkdir(parents=True, exist_ok=True)
    developer = developer_path()
    compiler = developer / "Toolchains" / "XcodeDefault.xctoolchain" / "usr" / "bin" / "swiftc"
    subprocess.run(
        [
            str(compiler),
            "-swift-version",
            "6",
            "-sdk",
            str(Path(developer) / "Platforms" / "MacOSX.platform" / "Developer" / "SDKs" / "MacOSX26.5.sdk"),
            "-target",
            "arm64-apple-macosx26.0",
            str(CORE_SOURCE),
            str(HELPER_SOURCE),
            "-o",
            str(HELPER_BINARY),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=90.0,
    )
    return HELPER_BINARY


class ChildResult:
    def __init__(self, *, payload: bytes = b"", error: str | None = None, pid: int | None = None, returncode: int | None = None):
        self.payload = payload
        self.error = error
        self.pid = pid
        self.returncode = returncode


def run_child(argv: list[str], timeout: float = CHILD_TIMEOUT_SECONDS) -> ChildResult:
    """Capture bounded stdout, discard stderr, and kill/reap only the direct child on timeout."""
    try:
        child = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
    except OSError:
        return ChildResult(error="helper_start_failed")

    assert child.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    os.set_blocking(child.stdout.fileno(), False)
    output = bytearray()
    deadline = time.monotonic() + timeout
    stream_open = True

    while stream_open:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            if child.poll() is None:
                child.kill()  # Exact child PID only; no process-group or name-based kill.
            child.wait()  # Reap the child started above.
            child.stdout.close()
            selector.close()
            return ChildResult(error="timeout", pid=child.pid, returncode=child.returncode)

        events = selector.select(min(remaining, 0.1))
        if not events:
            if child.poll() is not None:
                # Poll once more for EOF after the process has closed its pipe.
                continue
            continue

        for key, _ in events:
            try:
                chunk = os.read(key.fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                selector.unregister(key.fileobj)
                stream_open = False
                break
            if len(output) + len(chunk) > MAX_CHILD_STDOUT:
                if child.poll() is None:
                    child.kill()
                child.wait()
                child.stdout.close()
                selector.close()
                return ChildResult(error="helper_output_too_large", pid=child.pid, returncode=child.returncode)
            output.extend(chunk)

    try:
        child.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        if child.poll() is None:
            child.kill()
        child.wait()
        child.stdout.close()
        selector.close()
        return ChildResult(error="timeout", pid=child.pid, returncode=child.returncode)
    returncode = child.returncode
    child.stdout.close()
    selector.close()
    return ChildResult(payload=bytes(output), pid=child.pid, returncode=returncode)


def validate_helper_payload(
    payload: bytes,
    returncode: int | None,
    os_major: int,
    build: str,
    display_uuid: str,
) -> dict[str, Any]:
    try:
        candidate = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")

    expected_keys = {
        "osMajor",
        "build",
        "displayUUID",
        "rawSpaceID",
        "kind",
        "error",
        "adoption",
        "rawSpaceType",
        "spaceUUIDCandidate",
    }
    if not isinstance(candidate, dict) or set(candidate) != expected_keys:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    if type(candidate["osMajor"]) is not int or candidate["osMajor"] != os_major or type(candidate["build"]) is not str or candidate["build"] != build:
        return result_record(os_major, build, display_uuid, None, "unknown", "helper_identity_mismatch")
    if type(candidate["displayUUID"]) is not str or candidate["displayUUID"] != display_uuid:
        return result_record(os_major, build, display_uuid, None, "unknown", "helper_identity_mismatch")
    if type(candidate["adoption"]) is not bool or candidate["adoption"] is not False:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    if type(candidate["kind"]) is not str or candidate["kind"] not in {"user", "system", "fullscreen", "unknown"}:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")

    raw_space_type = candidate["rawSpaceType"]
    if raw_space_type is not None and (type(raw_space_type) is not int or raw_space_type < -(2**31) or raw_space_type > 2**31 - 1):
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    expected_kind = {0: "user", 2: "system", 4: "fullscreen"}.get(raw_space_type)
    error = candidate["error"]
    if type(error) is not str and error is not None:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    if error is not None and error not in ERROR_CODES:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    if expected_kind is None:
        if raw_space_type is None and candidate["kind"] != "unknown":
            return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
        if raw_space_type is not None and (candidate["kind"] != "unknown" or error != "unsupported_space_type"):
            return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    elif candidate["kind"] != expected_kind:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")

    space_uuid_candidate = candidate["spaceUUIDCandidate"]
    if space_uuid_candidate is not None:
        if type(space_uuid_candidate) is not str or canonical_uuid(space_uuid_candidate) != space_uuid_candidate:
            return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")

    raw_space_id = candidate["rawSpaceID"]
    if raw_space_id is not None:
        if not isinstance(raw_space_id, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", raw_space_id):
            return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
        if int(raw_space_id) > (2**64 - 1):
            return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")

    if returncode != 0 and error is None:
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    if returncode == 0 and (
        error is not None
        or raw_space_id is None
        or expected_kind is None
        or space_uuid_candidate is None
    ):
        return result_record(os_major, build, display_uuid, None, "unknown", "invalid_helper_response")
    return result_record(os_major, build, display_uuid, raw_space_id, candidate["kind"], error,
                         raw_space_type, space_uuid_candidate)


def run_probe(expected_major: int, expected_build: str, display_uuid: str) -> tuple[dict[str, Any], int]:
    actual_major, actual_build = read_running_os()
    guard_error = evaluate_os_guard(actual_major, actual_build, expected_major, expected_build)
    if guard_error:
        return result_record(actual_major, actual_build, display_uuid, None, "unknown", guard_error), 2

    try:
        helper = compile_helper()
    except (OSError, subprocess.SubprocessError):
        return result_record(actual_major, actual_build, display_uuid, None, "unknown", "helper_build_failed"), 3

    child_result = run_child(
        [
            str(helper),
            "--expected-os-major",
            str(expected_major),
            "--expected-build",
            expected_build,
            "--display-uuid",
            display_uuid,
        ]
    )
    if child_result.error:
        return result_record(actual_major, actual_build, display_uuid, None, "unknown", child_result.error), 3
    record = validate_helper_payload(child_result.payload, child_result.returncode, actual_major, actual_build, display_uuid)
    return record, 0 if child_result.returncode == 0 and record["error"] is None else 3


class ProbeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(message)


def main(argv: list[str] | None = None) -> int:
    parser = ProbeArgumentParser(add_help=False)
    parser.add_argument("--help", action="store_true")
    parser.add_argument("--expected-os-major", type=int)
    parser.add_argument("--expected-build")
    parser.add_argument("--display-uuid")
    try:
        args = parser.parse_args(argv)
    except ValueError:
        emit_result(result_record(None, None, None, None, "unknown", "invalid_arguments"))
        return 2

    if args.help:
        print("Usage: space-probe.py --expected-os-major 27 --expected-build BUILD --display-uuid UUID")
        print("Read-only isolated Space ID probe; output adoption is always false.")
        return 0

    if args.expected_os_major is None or not args.expected_build or not args.display_uuid:
        emit_result(result_record(None, None, None, None, "unknown", "invalid_arguments"))
        return 2
    if not re.fullmatch(r"[A-Za-z0-9]+", args.expected_build):
        emit_result(result_record(None, None, None, None, "unknown", "invalid_expected_build"))
        return 2
    normalized_uuid = canonical_uuid(args.display_uuid)
    if normalized_uuid is None:
        emit_result(result_record(None, None, None, None, "unknown", "invalid_display_uuid"))
        return 2
    record, exit_code = run_probe(args.expected_os_major, args.expected_build, normalized_uuid)
    emit_result(record)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

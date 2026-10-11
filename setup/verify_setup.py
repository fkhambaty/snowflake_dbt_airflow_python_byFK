#!/usr/bin/env python3
"""Verify the local tools required before building the Meridian source database."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPOSE_FILE = ROOT / "01_source_postgres" / "docker-compose.postgres.yml"


@dataclass(frozen=True)
class Check:
    name: str
    passed: bool
    detail: str
    required: bool = True


def run(command: list[str], timeout: int = 15) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def executable_check(name: str, command: list[str], required: bool = True) -> Check:
    executable = shutil.which(command[0])
    if not executable:
        return Check(name, False, f"{command[0]} is not on PATH", required)
    result = run(command)
    output = (result.stdout or result.stderr).strip().splitlines()
    detail = output[0] if output else f"exit code {result.returncode}"
    return Check(name, result.returncode == 0, detail, required)


def desktop_app_exists(names: tuple[str, ...]) -> bool:
    system = platform.system()
    if system == "Darwin":
        return any((Path("/Applications") / f"{name}.app").exists() for name in names)
    if system == "Windows":
        program_files = Path(os.getenv("ProgramFiles", "C:/Program Files"))
        local_app_data = Path(os.getenv("LOCALAPPDATA", "C:/Users/Public"))
        candidates = [
            program_files / "DBeaver" / "dbeaver.exe",
            program_files / "DBeaver Community" / "dbeaver.exe",
            local_app_data / "Programs" / "DBeaver" / "dbeaver.exe",
            program_files / "Microsoft VS Code" / "Code.exe",
            local_app_data / "Programs" / "Microsoft VS Code" / "Code.exe",
        ]
        lowered = {name.lower() for name in names}
        return any(
            candidate.exists()
            and any(name in str(candidate).lower() for name in lowered)
            for candidate in candidates
        )
    return any(shutil.which(name.lower()) for name in names)


def main() -> int:
    checks = [
        Check(
            "Python 3.12+",
            sys.version_info >= (3, 12),
            f"{platform.python_version()} at {sys.executable}",
        ),
        executable_check("Git", ["git", "--version"]),
        executable_check("Docker CLI", ["docker", "--version"]),
        executable_check("Docker Compose", ["docker", "compose", "version"]),
        Check(
            "DBeaver Community",
            desktop_app_exists(("DBeaver", "dbeaver")),
            "desktop application found"
            if desktop_app_exists(("DBeaver", "dbeaver"))
            else "desktop application not found",
        ),
        Check(
            "Visual Studio Code",
            desktop_app_exists(("Visual Studio Code", "VS Code", "Code"))
            or shutil.which("code") is not None,
            "editor found"
            if desktop_app_exists(("Visual Studio Code", "VS Code", "Code"))
            or shutil.which("code")
            else "optional: install Visual Studio Code or use another editor",
            required=False,
        ),
    ]

    docker = run(["docker", "info"]) if shutil.which("docker") else None
    checks.append(
        Check(
            "Docker engine",
            docker is not None and docker.returncode == 0,
            "running"
            if docker is not None and docker.returncode == 0
            else "start Docker Desktop and wait for the engine",
        )
    )
    checks.append(
        Check(
            "Course compose file",
            COMPOSE_FILE.exists(),
            str(COMPOSE_FILE.relative_to(ROOT)),
        )
    )

    if docker is not None and docker.returncode == 0:
        postgres = run(
            [
                "docker",
                "compose",
                "-f",
                str(COMPOSE_FILE),
                "ps",
                "--status",
                "running",
                "--services",
            ]
        )
        running = "postgres" in postgres.stdout.split()
        checks.append(
            Check(
                "Meridian PostgreSQL",
                running,
                "running"
                if running
                else "not built yet; run python3 setup/start_postgres.py",
                required=False,
            )
        )

    print(f"Meridian setup check — {platform.system()} {platform.release()}\n")
    for check in checks:
        label = "PASS" if check.passed else ("INFO" if not check.required else "FAIL")
        print(f"[{label:4}] {check.name}: {check.detail}")

    failures = [check for check in checks if check.required and not check.passed]
    if failures:
        print("\nFix every FAIL row, then run this command again.")
        return 1

    print("\nRequired setup checks passed.")
    print("Next: python3 setup/start_postgres.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

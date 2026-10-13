#!/usr/bin/env python3
"""Build and exercise the local Compose stack with synthetic data."""

from __future__ import annotations

import http.cookiejar
import os
import pathlib
import re
import secrets
import socket
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import base64
import json

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = "hacklv2-test-" + uuid.uuid4().hex[:10]


def run_compose(env_file: pathlib.Path, *arguments: str, check: bool = True) -> str:
    command = [
        "docker",
        "compose",
        "--project-name",
        PROJECT,
        "--env-file",
        str(env_file),
    ]
    completed = subprocess.run(
        command + list(arguments),
        cwd=ROOT,
        env=os.environ.copy(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if check and completed.returncode:
        raise AssertionError(f"Compose command failed: {' '.join(arguments)}\n{completed.stdout}")
    return completed.stdout


def request(
    opener: urllib.request.OpenerDirector,
    url: str,
    data: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, str]:
    encoded = urllib.parse.urlencode(data).encode() if data is not None else None
    request_object = urllib.request.Request(url, data=encoded, headers=headers or {})
    try:
        with opener.open(request_object, timeout=10) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def main() -> None:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

    with tempfile.TemporaryDirectory(prefix="hacklv2-compose-test-") as temporary:
        env_file = pathlib.Path(temporary) / ".env"
        env_file.write_text(
            f"DB_PASSWORD={secrets.token_urlsafe(32)}\n"
            f"APP_DB_PASSWORD={secrets.token_urlsafe(32)}\n"
            f"BACKUP_DB_PASSWORD={secrets.token_urlsafe(32)}\n"
            f"APP_PORT={port}\n"
            "AUTH_REQUIRED=true\n"
            "ALLOWED_USERS=hackathon@example.test\n",
            encoding="utf-8",
        )
        started = False
        try:
            run_compose(env_file, "config", "--quiet")
            run_compose(env_file, "up", "--build", "--wait", "--wait-timeout", "180")
            started = True

            states = run_compose(env_file, "ps", "--format", "json").splitlines()
            if len(states) != 2 or any('"healthy"' not in line for line in states):
                raise AssertionError(f"Services are not healthy: {states}")

            app_container = run_compose(env_file, "ps", "-q", "app").strip()
            user_id = subprocess.check_output(
                ["docker", "exec", app_container, "id", "-u"], text=True
            ).strip()
            if user_id == "0":
                raise AssertionError("Application container runs as root")
            database_user = subprocess.check_output(
                [
                    "docker",
                    "exec",
                    app_container,
                    "php",
                    "-r",
                    "require '/var/www/app/db_connect.php'; echo connectDatabase()->query('SELECT current_user')->fetchColumn();",
                ],
                text=True,
            ).strip()
            if database_user != "inventory_app":
                raise AssertionError("The application does not use its restricted database role")

            base_url = f"http://127.0.0.1:{port}"
            opener = urllib.request.build_opener(
                urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
            )
            status, body = request(opener, base_url + "/health.php")
            if status != 200 or body.strip() != "ok":
                raise AssertionError("Liveness endpoint did not respond successfully")
            status, body = request(opener, base_url + "/ready.php")
            if status != 200 or body.strip() != "ready":
                app_logs = run_compose(env_file, "logs", "--no-color", "app", check=False)
                raise AssertionError(
                    f"Readiness endpoint failed (HTTP {status}, {body!r}).\n{app_logs}"
                )
            if request(opener, base_url + "/index.php")[0] != 403:
                raise AssertionError("Anonymous inventory access was not denied")
            def principal(user: str) -> str:
                encoded_principal = json.dumps({"userDetails": user}).encode()
                return base64.b64encode(encoded_principal).decode()

            status, body = request(
                opener,
                base_url + "/index.php",
                headers={"X-MS-CLIENT-PRINCIPAL": principal("hackathon@example.test")},
            )
            if status != 200:
                raise AssertionError("Allow-listed authenticated user was denied")
            unauthorized_status, unauthorized_body = request(
                urllib.request.build_opener(),
                base_url + "/index.php",
                headers={"X-MS-CLIENT-PRINCIPAL": principal("unauthorized@example.test")},
            )
            if unauthorized_status != 403:
                raise AssertionError(
                    f"User outside the allowlist was not denied (HTTP {unauthorized_status}, {unauthorized_body[:80]!r})"
                )
            if status != 200 or body.count('name="quantity"') != 108:
                raise AssertionError("Expected the page to show all 108 inventory rows")

            token_match = re.search(r'name="csrf_token" value="([a-f0-9]+)"', body)
            if token_match is None:
                raise AssertionError("Missing CSRF token")
            token = token_match.group(1)
            allowed_headers = {
                "X-MS-CLIENT-PRINCIPAL": principal("hackathon@example.test")
            }
            if request(
                opener,
                base_url + "/index.php",
                {"id": "1", "quantity": "42"},
                allowed_headers,
            )[0] != 403:
                raise AssertionError("A missing CSRF token was not rejected")
            if request(
                opener,
                base_url + "/index.php",
                {"id": "1", "quantity": "-1", "csrf_token": token},
                allowed_headers,
            )[0] != 422:
                raise AssertionError("An invalid stock quantity was not rejected")
            if request(
                opener,
                base_url + "/index.php",
                {"id": "1 OR 1=1", "quantity": "1", "csrf_token": token},
                allowed_headers,
            )[0] != 422:
                raise AssertionError("An invalid item identifier was not rejected")

            status, response = request(
                opener,
                base_url + "/index.php",
                {"id": "1", "quantity": "43", "csrf_token": token},
                allowed_headers,
            )
            if status != 200 or "Stock quantity updated." not in response:
                raise AssertionError("Inventory update failed")

            run_compose(
                env_file,
                "exec",
                "-T",
                "database",
                "psql",
                "-U",
                "postgres",
                "-d",
                "inventory",
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                "/docker-entrypoint-initdb.d/01-inventory.sql",
            )
            count = run_compose(
                env_file,
                "exec",
                "-T",
                "database",
                "psql",
                "-U",
                "postgres",
                "-d",
                "inventory",
                "-Atc",
                "SELECT count(*) FROM inventory",
            ).strip()
            quantity = run_compose(
                env_file,
                "exec",
                "-T",
                "database",
                "psql",
                "-U",
                "postgres",
                "-d",
                "inventory",
                "-Atc",
                "SELECT quantity FROM inventory WHERE id=1",
            ).strip()
            if count != "108" or quantity != "43":
                raise AssertionError("SQL rerun was not idempotent or lost the stock update")

            denied_update = run_compose(
                env_file,
                "exec",
                "-T",
                "database",
                "psql",
                "-U",
                "inventory_app",
                "-d",
                "inventory",
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                "UPDATE inventory SET category=category WHERE id=1",
                check=False,
            )
            if "permission denied" not in denied_update.lower():
                raise AssertionError("The application database role can update a protected column")
            run_compose(
                env_file,
                "exec",
                "-T",
                "database",
                "pg_dump",
                "-U",
                "inventory_backup",
                "-d",
                "inventory",
                "--format=custom",
                "--file=/tmp/inventory-test.dump",
            )

            print("PASS: rootless production image, health/readiness, 108 synthetic rows, CSRF/input rejection,")
            print("      allowlisted auth, least-privilege app/backup roles, and idempotent SQL preserving stock changes.")
        finally:
            if started:
                run_compose(env_file, "down", "--volumes", "--remove-orphans", check=False)


if __name__ == "__main__":
    main()

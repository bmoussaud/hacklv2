#!/usr/bin/env python3
"""Exercise the backup command safely with fake pg_dump and Azure CLI executables."""

from __future__ import annotations

import hashlib
import pathlib
import secrets
import subprocess
import sys
import tempfile

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "inventory-backup:test"
DUMP_BYTES = b"synthetic database dump\n"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="inventory-backup-test-") as temporary:
        test_dir = pathlib.Path(temporary)
        bin_dir = test_dir / "bin"
        bin_dir.mkdir()
        az_log = test_dir / "az-calls.txt"
        dump_path = test_dir / "dump-path.txt"
        (bin_dir / "az").write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$AZ_MOCK_LOG\"\n",
            encoding="utf-8",
            newline="\n",
        )
        (bin_dir / "pg_dump").write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  case \"$1\" in --file=*) output=\"${1#--file=}\" ;; esac\n"
            "  shift\n"
            "done\n"
            "printf 'synthetic database dump\\n' > \"$output\"\n"
            "printf '%s' \"$output\" > \"$PGDUMP_PATH_FILE\"\n",
            encoding="utf-8",
            newline="\n",
        )
        for executable in (bin_dir / "az", bin_dir / "pg_dump"):
            executable.chmod(0o755)

        env = {
            "PATH": "/test/bin:/usr/bin:/bin",
            "PGHOST": "private-db.example.test",
            "PGPORT": "5432",
            "PGDATABASE": "inventory",
            "PGUSER": "inventory_backup",
            "PGPASSWORD": secrets.token_urlsafe(24),
            "PGSSLMODE": "verify-full",
            "STORAGE_ACCOUNT": "hackathondemobackup",
            "STORAGE_CONTAINER": "postgres-backups",
            "AZURE_CLIENT_ID": "synthetic-managed-identity",
            "AZ_MOCK_LOG": "/test/az-calls.txt",
            "PGDUMP_PATH_FILE": "/test/dump-path.txt",
            "HOME": "/tmp",
            "AZURE_CONFIG_DIR": "/tmp/azure-cli",
        }
        result = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--user",
                "10001:10001",
                "--volume",
                f"{test_dir}:/test",
                "--entrypoint",
                "/bin/sh",
                *sum((["--env", f"{key}={value}"] for key, value in env.items()), []),
                IMAGE,
                "-c",
                "set -eu; "
                "export PATH=\"$PATH\"; "
                "/usr/local/bin/backup.sh; "
                "test ! -e \"$(cat \"$PGDUMP_PATH_FILE\")\"",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if result.returncode:
            raise AssertionError(f"Backup job simulation failed:\n{result.stdout}")

        calls = az_log.read_text(encoding="utf-8").splitlines()
        if len(calls) != 2 or "--client-id synthetic-managed-identity" not in calls[0]:
            raise AssertionError("Backup did not log in with the assigned managed identity")
        upload = calls[1]
        expected_sha = hashlib.sha256(DUMP_BYTES).hexdigest()
        if (
            "storage blob upload" not in upload
            or "--auth-mode login" not in upload
            or f"sha256={expected_sha}" not in upload
            or "postgres/inventory/" not in upload
        ):
            raise AssertionError(f"Blob upload omitted OAuth, unique path, or checksum metadata: {upload}")
        if env["PGPASSWORD"] in "\n".join(calls):
            raise AssertionError("Database password was passed to Azure CLI")

        restore_bin = test_dir / "restore-bin"
        restore_bin.mkdir()
        restore_log = test_dir / "restore-calls.txt"
        expected_sha = hashlib.sha256(DUMP_BYTES).hexdigest()
        (restore_bin / "az").write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf 'az %s\\n' \"$*\" >> \"$RESTORE_LOG\"\n"
            "case \"$*\" in\n"
            "  *'blob show'*) printf '%s\\n' \"$EXPECTED_SHA\" ;;\n"
            "  *'blob download'*)\n"
            "    while [ \"$#\" -gt 0 ]; do\n"
            "      if [ \"$1\" = '--file' ]; then shift; output=\"$1\"; fi\n"
            "      shift\n"
            "    done\n"
            "    printf 'synthetic database dump\\n' > \"$output\"\n"
            "    ;;\n"
            "esac\n",
            encoding="utf-8",
            newline="\n",
        )
        for command in ("createdb", "pg_restore", "psql"):
            (restore_bin / command).write_text(
                "#!/bin/sh\n"
                "printf '%s %s\\n' \"$(basename \"$0\")\" \"$*\" >> \"$RESTORE_LOG\"\n"
                "if [ \"$(basename \"$0\")\" = psql ]; then printf '108\\n'; fi\n",
                encoding="utf-8",
                newline="\n",
            )
        for executable in restore_bin.iterdir():
            executable.chmod(0o755)

        restore_env = {
            "PATH": "/test/restore-bin:/usr/bin:/bin",
            "PGHOST": "private-db.example.test",
            "PGPORT": "5432",
            "PGUSER": "postgres_admin",
            "PGPASSWORD": secrets.token_urlsafe(24),
            "PGSSLMODE": "verify-full",
            "STORAGE_ACCOUNT": "hackathondemobackup",
            "STORAGE_CONTAINER": "postgres-backups",
            "AZURE_CLIENT_ID": "synthetic-restore-identity",
            "BLOB_NAME": "postgres/inventory/20250101T020000Z.dump",
            "EXPECTED_SHA": expected_sha,
            "RESTORE_LOG": "/test/restore-calls.txt",
            "HOME": "/tmp",
            "AZURE_CONFIG_DIR": "/tmp/azure-cli",
        }
        restore_result = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--user",
                "10001:10001",
                "--volume",
                f"{test_dir}:/test",
                "--entrypoint",
                "/bin/sh",
                *sum(
                    (["--env", f"{key}={value}"] for key, value in restore_env.items()),
                    [],
                ),
                IMAGE,
                "-c",
                "/usr/local/bin/restore.sh",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if restore_result.returncode:
            raise AssertionError(f"Verified restore simulation failed:\n{restore_result.stdout}")
        restore_calls = restore_log.read_text(encoding="utf-8")
        if (
            "az login --identity" not in restore_calls
            or "--query metadata.sha256" not in restore_calls
            or "inventory_restore_" not in restore_calls
            or "pg_restore --no-password --single-transaction --no-owner --no-acl" not in restore_calls
            or "108 inventory rows" not in restore_result.stdout
        ):
            raise AssertionError("Restore omitted managed identity, isolated database, or row-count verification")

        restore_log.write_text("", encoding="utf-8")
        restore_env["EXPECTED_SHA"] = "0" * 64
        corrupt_result = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--user",
                "10001:10001",
                "--volume",
                f"{test_dir}:/test",
                "--entrypoint",
                "/bin/sh",
                *sum(
                    (["--env", f"{key}={value}"] for key, value in restore_env.items()),
                    [],
                ),
                IMAGE,
                "-c",
                "/usr/local/bin/restore.sh",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if corrupt_result.returncode == 0 or "createdb " in restore_log.read_text(encoding="utf-8"):
            raise AssertionError("Restore did not stop before database creation on a checksum mismatch")
        print(
            "PASS: managed identity login, verified-TLS backup, OAuth Blob upload, SHA-256 "
            "metadata, isolated restore, row-count check, checksum mismatch rejection, temp cleanup."
        )


if __name__ == "__main__":
    main()

"""Register the TypeSafe SLC with Exasol and install the Jev UDFs.

Run after `exaslct deploy` has uploaded the container to BucketFS:

    python exasol/deploy.py --container typesafe-python-3.12-release-<HASH>

The API key is read from .env (TYPESAFE_API_KEY) and stored in an Exasol
CONNECTION object, so it never appears in script text or query logs.
"""

import argparse
import pathlib
import sys

import pyexasol
from dotenv import dotenv_values

ROOT = pathlib.Path(__file__).resolve().parent
ALIAS = "PYTHON3_TYPESAFE"
CONNECTION_NAME = "TYPESAFE_API"
BASE_URL = "https://api.typesafe.ai"


def language_definition(container: str, bfs_name: str, bucket: str, path: str) -> str:
    """Build the SCRIPT_LANGUAGES entry for the uploaded container."""
    location = f"{bfs_name}/{bucket}/{path}/{container}"
    return (
        f"{ALIAS}=localzmq+protobuf:///{location}?lang=python"
        f"#buckets/{location}/exaudf/exaudfclient"
    )


def merged_script_languages(current: str, definition: str) -> str:
    """Append our alias to SCRIPT_LANGUAGES, replacing any earlier copy of it."""
    kept = [tok for tok in current.split() if not tok.startswith(f"{ALIAS}=")]
    return " ".join(kept + [definition])


def statements(sql_path: pathlib.Path):
    """Split an Exasol script file on lines containing only '/'."""
    for chunk in sql_path.read_text(encoding="utf-8").split("\n/\n"):
        chunk = chunk.strip()
        if chunk:
            yield chunk


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", required=True, help="container name in BucketFS, without .tar.gz")
    parser.add_argument("--dsn", default="127.0.0.1:9563")
    parser.add_argument("--user", default="sys")
    parser.add_argument("--password", default="exasol")
    parser.add_argument("--bucketfs-name", default="bfsdefault")
    parser.add_argument("--bucket", default="default")
    parser.add_argument("--path-in-bucket", default="slc")
    args = parser.parse_args()

    api_key = dotenv_values(ROOT.parent / ".env").get("TYPESAFE_API_KEY")
    if not api_key:
        print("TYPESAFE_API_KEY missing from .env", file=sys.stderr)
        return 1

    con = pyexasol.connect(
        dsn=args.dsn, user=args.user, password=args.password,
        websocket_sslopt={"cert_reqs": 0}, autocommit=True,
    )

    definition = language_definition(
        args.container, args.bucketfs_name, args.bucket, args.path_in_bucket
    )
    current = con.execute(
        "SELECT SYSTEM_VALUE FROM SYS.EXA_PARAMETERS WHERE PARAMETER_NAME='SCRIPT_LANGUAGES'"
    ).fetchval() or ""
    merged = merged_script_languages(current, definition)

    con.execute(f"ALTER SYSTEM SET SCRIPT_LANGUAGES='{merged}'")
    con.execute(f"ALTER SESSION SET SCRIPT_LANGUAGES='{merged}'")
    print(f"registered language alias {ALIAS}")

    escaped = api_key.replace("'", "''")
    con.execute(
        f"CREATE OR REPLACE CONNECTION {CONNECTION_NAME} "
        f"TO '{BASE_URL}' USER 'apikey' IDENTIFIED BY '{escaped}'"
    )
    print(f"created connection {CONNECTION_NAME}")

    for statement in statements(ROOT / "udfs.sql"):
        con.execute(statement)
    print("installed UDFs into TYPESAFE_LAB")

    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

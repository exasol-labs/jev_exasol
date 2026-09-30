"""Install the entity-resolution UDF and scripts into TYPESAFE_LAB.

    python exasol/install.py

Reuses the PYTHON3_TYPESAFE language alias and the TYPESAFE_API connection that
the invoice use case's deploy.py created. Each .sql file is one CREATE SCRIPT
whose body swallows anything after it, so every file is executed whole.
"""

import argparse
import pathlib

import pyexasol

HERE = pathlib.Path(__file__).resolve().parent
FILES = ["jev_entity_match.sql", "find_candidates.sql", "resolve_entities.sql"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsn", default="127.0.0.1:9563")
    parser.add_argument("--user", default="sys")
    parser.add_argument("--password", default="exasol")
    args = parser.parse_args()

    con = pyexasol.connect(
        dsn=args.dsn, user=args.user, password=args.password,
        websocket_sslopt={"cert_reqs": 0}, autocommit=True,
    )
    con.execute("CREATE SCHEMA IF NOT EXISTS TYPESAFE_LAB")
    for name in FILES:
        con.execute((HERE / name).read_text(encoding="utf-8"))
        print(f"installed {name}")
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

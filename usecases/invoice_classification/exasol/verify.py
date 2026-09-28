"""Smoke-test the TypeSafe SLC and the Jev UDFs against Exasol.

    python exasol/verify.py
"""

import argparse
import json

import pyexasol

DOCUMENT = "I was charged twice. Please fix this ASAP."

TICKETS = [
    ("T-1", "I was charged twice. Please fix this ASAP."),
    ("T-2", "Could you tell me when the next maintenance window is? No rush."),
    ("T-3", "The cluster has been down for six hours and nobody has replied. Unacceptable."),
]


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

    # 1. Is typesafe-sdk actually importable inside the container?
    con.execute(
        "CREATE OR REPLACE PYTHON3_TYPESAFE SCALAR SCRIPT TYPESAFE_LAB.SLC_VERSIONS()\n"
        "RETURNS VARCHAR(2000) AS\n"
        "import sys\n"
        "def run(ctx):\n"
        "    import typesafe_sdk, httpx2, pydantic\n"
        "    return 'python=%s typesafe_sdk=%s httpx2=%s pydantic=%s' % (\n"
        "        sys.version.split()[0], typesafe_sdk.__version__,\n"
        "        httpx2.__version__, pydantic.VERSION)\n"
    )
    print("[1] container:", con.execute("SELECT TYPESAFE_LAB.SLC_VERSIONS()").fetchval())

    # 2. Scalar UDF — the main.py shape.
    raw = con.execute(
        f"SELECT TYPESAFE_LAB.JEV_CLASSIFY('{DOCUMENT}')"
    ).fetchval()
    result = json.loads(raw)
    print(f"\n[2] JEV_CLASSIFY  model={result['model']}  request_id={result['request_id']}")
    print(f"    billing (noul)  p(yes)={result['billing']:.3f}")
    print(f"    tone (choice)   {result['tone']}  confidence={result['tone_confidence']:.3f}")
    print(f"    urgency (score) {result['urgency']:.3f}  confidence={result['urgency_confidence']:.3f}")

    # 3. Set UDF — concurrent over a group.
    con.execute("CREATE OR REPLACE TABLE TYPESAFE_LAB.TICKETS (id VARCHAR(256), body VARCHAR(2000000))")
    con.ext.insert_multi(("TYPESAFE_LAB", "TICKETS"), TICKETS)

    rows = con.execute("""
        SELECT TYPESAFE_LAB.JEV_CLASSIFY_BATCH(id, body)
        FROM TYPESAFE_LAB.TICKETS
        GROUP BY TRUE
        ORDER BY id
    """).fetchall()

    print("\n[3] JEV_CLASSIFY_BATCH")
    print(f"    {'id':<5} {'billing':>8} {'tone':<12} {'conf':>6} {'urgency':>8} {'conf':>6}  error")
    for rid, billing, tone, tone_c, urgency, urgency_c, error in rows:
        if error:
            print(f"    {rid:<5} {'-':>8} {'-':<12} {'-':>6} {'-':>8} {'-':>6}  {error}")
        else:
            print(f"    {rid:<5} {billing:>8.3f} {tone:<12} {tone_c:>6.3f} {urgency:>8.3f} {urgency_c:>6.3f}")

    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Load the Companies House extract into Exasol as the company master.

    python data/prepare_master.py --csv BasicCompanyData-2026-09-01-part1_7.csv

Writes two tables in ENTITY_RESOLUTION:

  COMPANY_MASTER   every company except the held-out ones (~849k rows)
  COMPANY_HOLDOUT  ~0.1% of companies, picked by a hash of the company number.
                   They stand in for companies "not in our master yet", so
                   generate_incoming.py can build records that must NOT match.

The registry has no VAT numbers or websites, so both are made up here, derived
from the company number and name so every run produces the same values. About
65% of companies get a VAT number and 70% a website; both are unique.
"""

import argparse
import csv
import datetime
import hashlib
import re

import pyexasol

SCHEMA = "ENTITY_RESOLUTION"

COLUMNS = """
    COMPANY_NUMBER      VARCHAR(8) NOT NULL,
    COMPANY_NAME        VARCHAR(300),
    ADDRESS_LINE1       VARCHAR(500),
    ADDRESS_LINE2       VARCHAR(500),
    POST_TOWN           VARCHAR(200),
    COUNTY              VARCHAR(200),
    COUNTRY             VARCHAR(100),
    POSTCODE            VARCHAR(20),
    COMPANY_CATEGORY    VARCHAR(200),
    COMPANY_STATUS      VARCHAR(100),
    INCORPORATION_DATE  DATE,
    SIC_1               VARCHAR(300),
    PREVIOUS_NAME       VARCHAR(300),
    VAT_ID              VARCHAR(20),
    WEBSITE             VARCHAR(200)
"""

# Stripped from the name before building a website domain.
LEGAL_WORDS = {"LTD", "LIMITED", "PLC", "LLP", "LP", "CIC", "CO", "COMPANY", "THE"}
TLDS = [".co.uk"] * 6 + [".com"] * 3 + [".uk"]


def h(*parts: str) -> int:
    return int(hashlib.md5("|".join(parts).encode("utf-8")).hexdigest(), 16)


def is_holdout(number: str) -> bool:
    return h(number) % 1000 == 0


def iso_date(value: str):
    # The registry writes dates as dd/mm/yyyy.
    if not value:
        return None
    return datetime.datetime.strptime(value, "%d/%m/%Y").date().isoformat()


def make_vat(number: str, used: set):
    if h("vat", number) % 100 >= 65:
        return None
    salt = 0
    while True:
        digits = "%09d" % (h("vat", number, str(salt)) % 10**9)
        if digits not in used:
            used.add(digits)
            return "GB" + digits
        salt += 1


def make_website(number: str, name: str, town: str, used: set):
    if h("web", number) % 100 >= 70:
        return None
    tokens = [t for t in re.sub(r"[^A-Z0-9 ]", "", name.upper().replace("&", " AND ")).split()
              if t not in LEGAL_WORDS]
    root = "".join(tokens).lower()[:40]
    if len(root) < 3:
        return None
    tld = TLDS[h("tld", number) % len(TLDS)]
    # Two companies can normalise to the same root ("ACME LTD", "ACME (UK) LTD");
    # the later one gets its town appended, then a counter, like a real registrant would.
    candidates = [root, root + "-" + re.sub(r"[^a-z]", "", town.lower())]
    candidates += [root + str(i) for i in range(2, 1000)]
    for c in candidates:
        domain = c + tld
        if domain not in used:
            used.add(domain)
            return "www." + domain


def rows(csv_path: str):
    used_vat, used_web = set(), set()
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = [c.strip() for c in next(reader)]
        col = {name: i for i, name in enumerate(header)}
        for r in reader:
            number = r[col["CompanyNumber"]].strip()
            name = r[col["CompanyName"]].strip()
            town = r[col["RegAddress.PostTown"]].strip()
            yield is_holdout(number), (
                number,
                name,
                r[col["RegAddress.AddressLine1"]].strip() or None,
                r[col["RegAddress.AddressLine2"]].strip() or None,
                town or None,
                r[col["RegAddress.County"]].strip() or None,
                r[col["RegAddress.Country"]].strip() or None,
                r[col["RegAddress.PostCode"]].strip() or None,
                r[col["CompanyCategory"]].strip() or None,
                r[col["CompanyStatus"]].strip() or None,
                iso_date(r[col["IncorporationDate"]].strip()),
                r[col["SICCode.SicText_1"]].strip() or None,
                r[col["PreviousName_1.CompanyName"]].strip() or None,
                make_vat(number, used_vat),
                make_website(number, name, town, used_web),
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True, help="Companies House BasicCompanyData CSV")
    parser.add_argument("--dsn", default="127.0.0.1:9563")
    parser.add_argument("--user", default="sys")
    parser.add_argument("--password", default="exasol")
    args = parser.parse_args()

    master, holdout = [], []
    for held_out, row in rows(args.csv):
        (holdout if held_out else master).append(row)
    print(f"read {len(master)} master and {len(holdout)} held-out companies")

    con = pyexasol.connect(
        dsn=args.dsn, user=args.user, password=args.password,
        websocket_sslopt={"cert_reqs": 0}, autocommit=True,
    )
    con.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
    for table, data in (("COMPANY_MASTER", master), ("COMPANY_HOLDOUT", holdout)):
        con.execute(f"CREATE OR REPLACE TABLE {SCHEMA}.{table} ({COLUMNS})")
        con.import_from_iterable(data, (SCHEMA, table))
        count = con.execute(f"SELECT COUNT(*) FROM {SCHEMA}.{table}").fetchval()
        print(f"loaded {count} rows into {SCHEMA}.{table}")
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

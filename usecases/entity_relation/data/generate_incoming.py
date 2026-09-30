"""Generate messy "incoming" company records from the master and load them.

    python data/generate_incoming.py

Run after prepare_master.py. Picks companies from ENTITY_RESOLUTION.COMPANY_MASTER
(and COMPANY_HOLDOUT, for records that must not match), writes one messy record
per copy, and loads two tables:

  INCOMING_RECORDS  what a CRM / vendor list / web form would hold -- all Jev sees
  INCOMING_TRUTH    the answer key: which company each record really is

The same records are written to incoming_records.csv and incoming_truth.csv
next to this file. The seed is fixed, so a rerun against the same master
produces the same records.

Each record gets one VARIATION_TYPE, the change that makes it hard to match:

  SPELLING      typos, abbreviations, & vs AND, merged words
  LEGAL_SUFFIX  LIMITED vs Ltd. vs no suffix, PLC vs Public Limited Company
  ADDRESS       Rd/St/Ave, missing lines, postcode without a space or moved
  DOMAIN        trading name plus a website in another form (https, shop., email)
  VAT           trading name plus the VAT number in another format
  TRANSLATION   name translated into German/French/Spanish/Dutch/Italian
  MIXED         spelling + legal suffix + address changes together, no keys
  NO_MATCH      a held-out company that is not in the master at all

A company can appear up to three times, so the incoming table also contains
duplicates of itself for the dedup half of the demo.
"""

import argparse
import csv
import pathlib
import random
import re

import pyexasol

HERE = pathlib.Path(__file__).resolve().parent
SCHEMA = "ENTITY_RESOLUTION"
SEED = 20260929
TARGET_RECORDS = 2000
TARGET_NO_MATCH = 250

RECORD_COLUMNS = ["INCOMING_ID", "SOURCE_SYSTEM", "RECORD_NAME", "ADDRESS",
                  "POSTCODE", "COUNTRY", "WEBSITE", "VAT_ID"]
TRUTH_COLUMNS = ["INCOMING_ID", "VARIATION_TYPE", "TRUE_COMPANY_NUMBER", "ENTITY_ID"]

POSITIVE_TYPES = ["SPELLING", "LEGAL_SUFFIX", "ADDRESS", "DOMAIN", "VAT", "MIXED"]
POSITIVE_WEIGHTS = [3, 3, 2.5, 2.5, 2.5, 3]

LEGAL_SUFFIX = re.compile(r"\s+(LIMITED|LTD\.?|PLC|LLP|CIC)$")
SUFFIX_SWAPS = {
    "LIMITED": ["LTD", "Ltd.", "Ltd", "", "Limited Company"],
    "LTD": ["LIMITED", "Limited", "", "Ltd."],
    "LTD.": ["LIMITED", "Ltd", ""],
    "PLC": ["P.L.C.", "Public Limited Company", ""],
    "LLP": ["L.L.P.", "Limited Liability Partnership", ""],
    "CIC": ["Community Interest Company", ""],
}
ABBREVIATIONS = {
    "AND": "&", "&": "AND", "SERVICES": "SVCS", "INTERNATIONAL": "INTL",
    "MANAGEMENT": "MGMT", "ENGINEERING": "ENG", "CONSULTING": "CONSULTANCY",
    "CONSULTANCY": "CONSULTING", "SOLUTIONS": "SOLNS", "TECHNOLOGIES": "TECH",
    "TECHNOLOGY": "TECH", "PROPERTIES": "PROPS", "DEVELOPMENTS": "DEVS",
    "ASSOCIATES": "ASSOC", "CONSTRUCTION": "CONSTR", "TRANSPORT": "TRANS",
    "HOLDINGS": "HLDGS", "INVESTMENTS": "INVEST", "ELECTRICAL": "ELEC", "GROUP": "GRP",
}
# Dropped from the end of a trading name ("Blue Fox Services Ltd" -> "Blue Fox").
GENERIC_TAIL = {"SERVICES", "SOLUTIONS", "GROUP", "SYSTEMS", "ENTERPRISES", "UK", "INTERNATIONAL"}
STREET_ABBREVIATIONS = {
    "ROAD": "Rd", "STREET": "St", "AVENUE": "Ave", "LANE": "Ln", "DRIVE": "Dr",
    "HOUSE": "Ho", "CLOSE": "Cl", "COURT": "Ct", "BUSINESS": "Bus.", "FIRST FLOOR": "1st Floor",
    "SECOND FLOOR": "2nd Floor", "GROUND FLOOR": "Gnd Floor", "INDUSTRIAL ESTATE": "Ind. Est.",
}
TRANSLATED_COUNTRY = {
    "de": "Vereinigtes Königreich", "fr": "Royaume-Uni", "es": "Reino Unido",
    "nl": "Verenigd Koninkrijk", "it": "Regno Unito",
}
SOURCES = ["CRM", "ERP_VENDORS", "WEB_FORM"]

BASE_COLUMNS = """COMPANY_NUMBER, COMPANY_NAME, ADDRESS_LINE1, ADDRESS_LINE2, POST_TOWN,
                  COUNTRY, POSTCODE, WEBSITE, VAT_ID"""
BASE_FILTER = """COMPANY_STATUS LIKE 'Active%' AND POSTCODE IS NOT NULL
                 AND ADDRESS_LINE1 IS NOT NULL AND COMPANY_NAME LIKE '% %'"""


def title(text: str) -> str:
    # Per letter run, so "ROAD," and "O'NEILL" come out as "Road," and "O'Neill".
    return re.sub(r"[A-Za-z]+", lambda m: m.group().capitalize(), text)


def typo(word: str, rng: random.Random) -> str:
    i = rng.randrange(1, len(word) - 1)
    op = rng.choice(["swap", "drop", "double", "vowel"])
    if op == "swap":
        return word[:i] + word[i + 1] + word[i] + word[i + 2:]
    if op == "drop":
        return word[:i] + word[i + 1:]
    if op == "double":
        return word[:i] + word[i] + word[i:]
    vowels = [j for j, c in enumerate(word) if c in "AEIOU" and j > 0]
    if not vowels:
        return word[:i] + word[i + 1:]
    j = rng.choice(vowels)
    return word[:j] + rng.choice([v for v in "AEIOU" if v != word[j]]) + word[j + 1:]


def spelling(name: str, rng: random.Random) -> str:
    tokens = name.split()
    core = [i for i, t in enumerate(tokens)
            if len(t) >= 4 and t.isalpha() and not LEGAL_SUFFIX.match(" " + t)]
    mergeable = [i for i in core if i + 1 in core]
    ops = ["typo"] if core else []
    if any(t in ABBREVIATIONS for t in tokens):
        ops.append("abbreviate")
    if mergeable:
        ops.append("merge")
    chosen = rng.sample(ops, k=min(len(ops), rng.choice([1, 2])))
    # Merging shifts token positions, so it runs after the index-based edits.
    for op in sorted(chosen, key=lambda o: o == "merge"):
        if op == "typo":
            i = rng.choice(core)
            tokens[i] = typo(tokens[i], rng)
        elif op == "abbreviate":
            # The typo may already have hit the only abbreviable word.
            targets = [i for i, t in enumerate(tokens) if t in ABBREVIATIONS]
            if targets:
                i = rng.choice(targets)
                tokens[i] = ABBREVIATIONS[tokens[i]]
        elif op == "merge":
            i = rng.choice(mergeable)
            tokens[i:i + 2] = [tokens[i] + tokens[i + 1]]
    out = " ".join(tokens)
    return title(out) if rng.random() < 0.5 else out


def legal_suffix(name: str, rng: random.Random) -> str:
    m = LEGAL_SUFFIX.search(name)
    if not m:
        return name + " Ltd"
    new = rng.choice(SUFFIX_SWAPS[m.group(1)])
    stem = name[:m.start()]
    if rng.random() < 0.5:
        stem = title(stem)
    return (stem + " " + new).strip()


def trading_name(name: str, rng: random.Random) -> str:
    tokens = LEGAL_SUFFIX.sub("", name).split()
    if len(tokens) >= 3 and tokens[-1] in GENERIC_TAIL and rng.random() < 0.6:
        tokens = tokens[:-1]
    return title(" ".join(tokens))


def standard_address(base: dict) -> str:
    return ", ".join(p for p in (base["ADDRESS_LINE1"], base["ADDRESS_LINE2"], base["POST_TOWN"]) if p)


def address_variant(base: dict, rng: random.Random):
    parts = [base["ADDRESS_LINE1"]]
    if base["ADDRESS_LINE2"] and rng.random() < 0.5:
        parts.append(base["ADDRESS_LINE2"])
    if base["POST_TOWN"] and rng.random() < 0.8:
        parts.append(base["POST_TOWN"])
    address = ", ".join(parts)
    for long, short in STREET_ABBREVIATIONS.items():
        address = re.sub(r"\b%s\b" % long, short, address)
    address = title(address) if rng.random() < 0.7 else address.lower()
    postcode = base["POSTCODE"]
    roll = rng.random()
    if roll < 0.35:
        postcode = postcode.replace(" ", "")
    elif roll < 0.5:
        postcode = postcode.lower()
    elif roll < 0.75:
        # Postcode typed into the address line, postcode field left empty.
        address, postcode = address + " " + postcode, None
    return address, postcode


def domain_variant(website: str, rng: random.Random) -> str:
    host = website[len("www."):]
    return rng.choice([
        "https://www." + host + "/", host, "http://" + host + "/contact-us",
        "shop." + host, "info@" + host, "WWW." + host.upper(), "https://" + host + "/about",
    ])


def vat_variant(vat: str, rng: random.Random) -> str:
    d = vat[2:]
    return rng.choice([
        f"GB {d[:3]} {d[3:7]} {d[7:]}", d, f"gb {d}", f"GB-{d[:3]}-{d[3:7]}-{d[7:]}",
        f"{d[:3]} {d[3:7]} {d[7:]}", f"GB {d}",
    ])


def make_record(base: dict, kind: str, rng: random.Random, in_master: bool, translation=None) -> dict:
    """One incoming record for `base`, changed the way `kind` says.

    Records that match carry a website or VAT number only when that key IS the
    variation (DOMAIN, VAT), so every other type is matched on the change it
    names rather than on an exact key. NO_MATCH records keep their own keys
    some of the time; they never equal a master key.
    """
    rec = {
        "RECORD_NAME": base["COMPANY_NAME"],
        "ADDRESS": standard_address(base),
        "POSTCODE": base["POSTCODE"] if rng.random() < 0.9 else None,
        "COUNTRY": rng.choice(["United Kingdom", "UK", "GB", base["COUNTRY"], None]),
        "WEBSITE": None,
        "VAT_ID": None,
    }
    if not in_master:
        rec["WEBSITE"] = base["WEBSITE"] if base["WEBSITE"] and rng.random() < 0.4 else None
        rec["VAT_ID"] = base["VAT_ID"] if base["VAT_ID"] and rng.random() < 0.35 else None
    if rng.random() < 0.5:
        rec["RECORD_NAME"] = title(rec["RECORD_NAME"])
        rec["ADDRESS"] = title(rec["ADDRESS"])

    if kind == "SPELLING":
        rec["RECORD_NAME"] = spelling(base["COMPANY_NAME"], rng)
    elif kind == "LEGAL_SUFFIX":
        rec["RECORD_NAME"] = legal_suffix(base["COMPANY_NAME"], rng)
    elif kind == "ADDRESS":
        rec["ADDRESS"], rec["POSTCODE"] = address_variant(base, rng)
    elif kind == "DOMAIN":
        # Web sign-ups: a trading name and a website, often nothing else.
        rec["RECORD_NAME"] = trading_name(base["COMPANY_NAME"], rng)
        rec["WEBSITE"] = domain_variant(base["WEBSITE"], rng)
        if rng.random() < 0.5:
            rec["ADDRESS"] = rec["POSTCODE"] = None
    elif kind == "VAT":
        rec["RECORD_NAME"] = trading_name(base["COMPANY_NAME"], rng)
        rec["VAT_ID"] = vat_variant(base["VAT_ID"], rng)
        if rng.random() < 0.5:
            rec["ADDRESS"] = rec["POSTCODE"] = None
    elif kind == "MIXED":
        rec["RECORD_NAME"] = legal_suffix(spelling(base["COMPANY_NAME"], rng).upper(), rng)
        rec["ADDRESS"], rec["POSTCODE"] = address_variant(base, rng)
    elif kind == "TRANSLATION":
        rec["RECORD_NAME"] = translation["translated_name"]
        rec["ADDRESS"] = title(standard_address(base))
        rec["COUNTRY"] = TRANSLATED_COUNTRY[translation["language"]]
    return rec


def positive_kind(base: dict, rng: random.Random) -> str:
    while True:
        kind = rng.choices(POSITIVE_TYPES, POSITIVE_WEIGHTS)[0]
        if kind == "DOMAIN" and not base["WEBSITE"]:
            continue
        if kind == "VAT" and not base["VAT_ID"]:
            continue
        return kind


def fetch(con, sql: str) -> list:
    stmt = con.execute(sql)
    cols = stmt.column_names()
    return [dict(zip(cols, r)) for r in stmt.fetchall()]


def generate(con) -> list:
    rng = random.Random(SEED)
    with open(HERE / "translations.csv", newline="", encoding="utf-8") as f:
        translations = {t["company_number"]: t for t in csv.DictReader(f)}

    numbers = ", ".join("'%s'" % n for n in translations)
    translated = fetch(con, f"SELECT {BASE_COLUMNS} FROM {SCHEMA}.COMPANY_MASTER "
                            f"WHERE COMPANY_NUMBER IN ({numbers}) ORDER BY COMPANY_NUMBER")
    if len(translated) != len(translations):
        found = {b["COMPANY_NUMBER"] for b in translated}
        raise SystemExit(f"translations.csv companies missing from master: {set(translations) - found}")

    order = f"ORDER BY HASH_MD5(COMPANY_NUMBER || '{SEED}')"
    positives = fetch(con, f"SELECT {BASE_COLUMNS} FROM {SCHEMA}.COMPANY_MASTER "
                           f"WHERE {BASE_FILTER} AND COMPANY_NUMBER NOT IN ({numbers}) {order} LIMIT 2000")
    holdouts = fetch(con, f"SELECT {BASE_COLUMNS} FROM {SCHEMA}.COMPANY_HOLDOUT "
                          f"WHERE {BASE_FILTER} {order} LIMIT 400")

    records = []  # (record, truth) pairs

    def add(base, kinds, in_master, translation=None):
        for kind in kinds:
            rec = make_record(base, kind, rng, in_master, translation)
            rec["SOURCE_SYSTEM"] = rng.choice(SOURCES)
            truth = {
                "VARIATION_TYPE": kind if in_master else "NO_MATCH",
                "TRUE_COMPANY_NUMBER": base["COMPANY_NUMBER"] if in_master else None,
                "ENTITY_ID": base["COMPANY_NUMBER"],
            }
            records.append((rec, truth))

    def copies():
        return rng.choices([1, 2, 3], [60, 30, 10])[0]

    for base in translated:
        t = translations[base["COMPANY_NUMBER"]]
        add(base, ["TRANSLATION"] + [positive_kind(base, rng) for _ in range(copies() - 1)], True, t)

    no_match = 0
    for base in holdouts:
        if no_match >= TARGET_NO_MATCH:
            break
        kinds = [rng.choice(["SPELLING", "LEGAL_SUFFIX", "ADDRESS"]) for _ in range(copies())]
        kinds = kinds[:TARGET_NO_MATCH - no_match]
        add(base, kinds, False)
        no_match += len(kinds)

    for base in positives:
        if len(records) >= TARGET_RECORDS:
            break
        n = min(copies(), TARGET_RECORDS - len(records))
        add(base, [positive_kind(base, rng) for _ in range(n)], True)

    if len(records) < TARGET_RECORDS:
        raise SystemExit(f"only {len(records)} records generated, wanted {TARGET_RECORDS}")

    # Shuffle so copies of one company are not next to each other, then number them.
    rng.shuffle(records)
    for i, (rec, truth) in enumerate(records, start=1):
        rec["INCOMING_ID"] = truth["INCOMING_ID"] = "IN-%05d" % i
    return records


def write_csv(path: pathlib.Path, columns: list, rows: list):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=columns)
        w.writeheader()
        w.writerows({c: r[c] for c in columns} for r in rows)


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
    records = generate(con)
    recs = [r for r, _ in records]
    truths = [t for _, t in records]
    write_csv(HERE / "incoming_records.csv", RECORD_COLUMNS, recs)
    write_csv(HERE / "incoming_truth.csv", TRUTH_COLUMNS, truths)

    con.execute(f"""CREATE OR REPLACE TABLE {SCHEMA}.INCOMING_RECORDS (
        INCOMING_ID VARCHAR(10) NOT NULL, SOURCE_SYSTEM VARCHAR(20), RECORD_NAME VARCHAR(300),
        ADDRESS VARCHAR(1000), POSTCODE VARCHAR(20), COUNTRY VARCHAR(100),
        WEBSITE VARCHAR(300), VAT_ID VARCHAR(30))""")
    con.execute(f"""CREATE OR REPLACE TABLE {SCHEMA}.INCOMING_TRUTH (
        INCOMING_ID VARCHAR(10) NOT NULL, VARIATION_TYPE VARCHAR(20),
        TRUE_COMPANY_NUMBER VARCHAR(8), ENTITY_ID VARCHAR(8))""")
    con.import_from_iterable([[r[c] for c in RECORD_COLUMNS] for r in recs], (SCHEMA, "INCOMING_RECORDS"))
    con.import_from_iterable([[t[c] for c in TRUTH_COLUMNS] for t in truths], (SCHEMA, "INCOMING_TRUTH"))

    for row in con.execute(f"""SELECT VARIATION_TYPE, COUNT(*) FROM {SCHEMA}.INCOMING_TRUTH
                               GROUP BY VARIATION_TYPE ORDER BY 1""").fetchall():
        print("%-13s %5d" % row)
    dup = con.execute(f"""SELECT COUNT(*) FROM (SELECT ENTITY_ID FROM {SCHEMA}.INCOMING_TRUTH
                          GROUP BY ENTITY_ID HAVING COUNT(*) > 1)""").fetchval()
    print(f"loaded {len(recs)} incoming records; {dup} companies appear more than once")
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

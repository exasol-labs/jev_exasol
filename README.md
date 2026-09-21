# Jev + Exasol

<img width="720" height="406" alt="Scoring invoices with Jev inside Exasol" src="https://github.com/user-attachments/assets/92879a7e-fa3a-48f0-bd46-01e0cca1e634" />

Running [TypeSafe](https://typesafe.ai) **Jev** judgments inside Exasol as UDFs.

Jev answers a yes/no question about a piece of state and returns a *probability*
rather than a string, so the answer can be used directly in SQL — filtered,
thresholded, joined, aggregated. This repo wires the TypeSafe Python SDK into
Exasol through a custom Script Language Container (SLC) and uses it to score
10,000 invoices against a question you supply at call time.

```sql
EXECUTE SCRIPT TYPESAFE_LAB.REFRESH_AI_INVOICES(
    'Is `invoice.service_line` a service line whose own deliverable is
     artificial intelligence or machine learning work?');
```

returns the invoices that matched, one API call per row, ~200 rows/s across four
parallel UDF instances.

## Contents

| File | What it is |
|---|---|
| `exasol/udfs.sql` | Three demo UDFs — `JEV_CLASSIFY` (scalar, JSON out), `JEV_CLASSIFY_BATCH` (set, concurrent), `SLC_VERSIONS`. A port of `main.py`. |
| `exasol/jev_invoice_ai_score.sql` | The scoring UDF. Python SET script, takes the question as a parameter, one concurrent API call per row. |
| `exasol/refresh_ai_invoices.sql` | Lua orchestration script. Scores every invoice, rebuilds the result view, returns the matching rows. |
| `exasol/deploy.py` | Registers the language alias + API-key connection, installs `udfs.sql`. |
| `exasol/verify.py` | Smoke test: container contents, scalar UDF, set UDF. |
| `main.py` | The standalone SDK example the UDFs were ported from. Run this first to check your API key works. |
| `filter_portugal.py` | Unrelated local CSV helper. |

## How it works

```
BOOK_KEEPING.INVOICES  (10,000 rows)
        |
        |  GROUP BY MOD(ID_INVOICE, 4)   -> 4 parallel UDF instances
        v
TYPESAFE_LAB.JEV_INVOICE_AI_SCORE        -- Python SET UDF, runs in the SLC
        |  16 concurrent HTTPS calls per instance (64 total)
        |  -> api.typesafe.ai   system_one(state={invoice}, questions={Noul})
        v
TYPESAFE_LAB.INVOICE_SCORES  (ROW_ID, P_TRUE, ERROR)
        |  joined back on ROWID
        v
BOOK_KEEPING.MATCHED_INVOICES  (P_TRUE >= 0.5)
```

The question is free text and reaches the model as a `Noul`. It is asked about
one invoice at a time, presented as `invoice` with these keys:

```
id, issued_date, country, client, service_line, total, discount, tax,
invoice_status, balance, due_date
```

Refer to them directly in the question, for example
``'Is `invoice.balance` greater than zero?'``. Dates arrive as ISO strings,
money columns as numbers.

## Requirements

- An Exasol database you can reach, plus admin rights (`ALTER SYSTEM`). If you
  don't have one, [Exasol Personal](https://www.exasol.com/personal/) is free —
  it runs natively on macOS, under Docker/Podman on Linux and WSL, or deploys
  into your own cloud account.
- **Docker and WSL** (or Linux/macOS) to build the SLC — `exaslct` has no native
  Windows support.
- A TypeSafe API key, from [console.typesafe.ai](https://console.typesafe.ai).
- Python on the host with `pyexasol` and `python-dotenv` (plus `typesafe-sdk` if
  you want to run `main.py`).
- **UDFs need outbound HTTPS access** to `api.typesafe.ai`. That is the whole
  premise here; on a locked-down cluster none of this works.

## Setup

### 1. API key

Get one from the TypeSafe console at
**[console.typesafe.ai](https://console.typesafe.ai)** — sign in with Google or
an emailed code, then create a key.

```bash
echo 'TYPESAFE_API_KEY=sk-...' > .env      # gitignored
python main.py                             # confirms the key works
```

### 2. Build the Script Language Container

The stock containers do not have `typesafe-sdk`, so you need a custom one. From
a Linux/WSL shell:

```bash
pip install exasol-script-languages-container-tool
git clone https://github.com/exasol/script-languages-release.git
cd script-languages-release
```

Base it on `template-Exasol-all-python-3.12` and add one pip package to the
flavor's `packages.yml`, under `flavor_customization` → `install_pip_packages`:

```yaml
- name: flavor_customization
  phases:
  - name: install_pip_packages
    pip:
      packages:
      - name: typesafe-sdk
        version: ==0.7.0
        extras: []
```

Then build and upload:

```bash
exaslct export --flavor-path=flavors/<your-flavor> --export-path ./output

exaslct deploy --flavor-path=flavors/<your-flavor> \
    --bucketfs-host 127.0.0.1 --bucketfs-port 2581 \
    --bucketfs-user w --bucketfs-password "$BFS_PASSWORD" \
    --bucketfs-name bfsdefault --bucket default \
    --path-in-bucket slc --bucketfs-use-https 1 \
    --no-use-ssl-cert-validation
```

`--no-use-ssl-cert-validation` is needed whenever BucketFS presents a
self-signed certificate — without it the upload dies with
`CERTIFICATE_VERIFY_FAILED`. A warm-cache build takes roughly 25 minutes and
produces a ~770 MB container. The many `404 ... not in registry` lines are a
remote cache probe and are harmless.

`exaslct deploy` prints the container name it uploaded — you need it next.

### 3. Register the language and install the UDFs

```bash
python exasol/deploy.py --container typesafe-python-3.12-release-<HASH>
```

This appends `PYTHON3_TYPESAFE=...` to `SCRIPT_LANGUAGES` (system *and*
session), creates `CONNECTION TYPESAFE_API` holding the key from `.env`, and
installs `exasol/udfs.sql`. Point it elsewhere with `--dsn/--user/--password`
and `--bucketfs-name/--bucket/--path-in-bucket`; the defaults target a local
Docker Exasol at `127.0.0.1:9563`.

Keeping the key in a `CONNECTION` keeps it out of script text and query logs —
the UDFs read it back via `exa.get_connection("TYPESAFE_API")`.

### 4. Install the two single-statement scripts

`deploy.py` installs **only** `udfs.sql`. The other two files are each a single
`CREATE SCRIPT` whose body swallows anything appended to it, so they cannot be
split on `/` and must be executed whole, one file per statement:

```python
import pathlib, pyexasol
con = pyexasol.connect(dsn="127.0.0.1:9563", user="sys", password="exasol",
                       websocket_sslopt={"cert_reqs": 0}, autocommit=True)
for f in ["exasol/jev_invoice_ai_score.sql", "exasol/refresh_ai_invoices.sql"]:
    con.execute(pathlib.Path(f).read_text(encoding="utf-8"))
```

### 5. Check it

```bash
python exasol/verify.py
```

Expected: the container's library versions, then a scalar and a set UDF result.

### 6. Load the invoice data

**Not scripted — you supply this.** The pipeline expects:

```sql
CREATE SCHEMA IF NOT EXISTS BOOK_KEEPING;
CREATE TABLE BOOK_KEEPING.INVOICES (
    ID_INVOICE      DECIMAL(36,0),
    ISSUED_DATE     DATE,
    COUNTRY         VARCHAR(100),
    SERVICE         VARCHAR(100),
    TOTAL           DOUBLE,
    DISCOUNT        DOUBLE,
    TAX             DOUBLE,
    INVOICE_STATUS  VARCHAR(20),
    BALANCE         DOUBLE,
    DUE_DATE        DATE,
    CLIENT          VARCHAR(100)
);
```

Any invoice-shaped data works. The reference set is 10,000 rows with 100
distinct `ID_INVOICE` values and six `SERVICE` values.

## Running it

```sql
EXECUTE SCRIPT TYPESAFE_LAB.REFRESH_AI_INVOICES(
    'Is `invoice.service_line` a service line whose own deliverable is
     artificial intelligence or machine learning work?');
```

Rebuilds `TYPESAFE_LAB.INVOICE_SCORES` and `BOOK_KEEPING.MATCHED_INVOICES`,
then returns the matching invoices ordered by confidence. Both writes are
`CREATE OR REPLACE`, so a failed run leaves nothing half-written — just rerun.

Ask anything the invoice fields can answer:

```sql
EXECUTE SCRIPT TYPESAFE_LAB.REFRESH_AI_INVOICES('Is `invoice.balance` greater than zero?');
```

The question is passed to the UDF as a bound parameter, so apostrophes only
need the usual SQL doubling (`client''s`).

A failed row does not abort the run — it gets a NULL score and keeps the
message:

```sql
SELECT COUNT(ERROR) FROM TYPESAFE_LAB.INVOICE_SCORES;
```

### Tuning

- `GROUP BY MOD(ID_INVOICE, 4)` in `refresh_ai_invoices.sql` sets the number of
  parallel UDF instances — it is not an aggregation.
- `MAX_CONCURRENCY = 16` in `jev_invoice_ai_score.sql` is in-flight requests per
  instance.

Measured here: one instance saturates near 50 rows/s regardless of concurrency,
four instances reach ~200 rows/s, and much past ~64 total in flight crashes the
UDF VM.

## Troubleshooting

**`no definition found for language: PYTHON3_TYPESAFE`** — `SCRIPT_LANGUAGES` is
read once when a session starts, so `ALTER SYSTEM` only reaches sessions opened
after it ran. In clients like DbVisualizer a new tab reuses the existing
connection, so opening a tab is *not* enough. Diagnose with:

```sql
SELECT SYSTEM_VALUE, SESSION_VALUE FROM SYS.EXA_PARAMETERS
WHERE PARAMETER_NAME = 'SCRIPT_LANGUAGES';
```

If the alias is in `SYSTEM_VALUE` but not `SESSION_VALUE`, reconnect the client.

**Build fails in `build_deps`** — the flavor templates pin exact apt versions
that Ubuntu eventually supersedes. Check the non-wildcard pins with
`apt-cache madison` in an `ubuntu:24.04` container before building; far cheaper
than finding them one failed build at a time.

**`CERTIFICATE_VERIFY_FAILED` on upload** — add `--no-use-ssl-cert-validation`.

**Every row scores NULL with a connection error** — the UDF host cannot reach
`api.typesafe.ai`. Check egress from the cluster, not from your laptop.

## Known gaps

- No CSV import script for `BOOK_KEEPING.INVOICES`; step 6 is manual.
- The custom flavor lives outside this repo — only the one-package change is
  documented above.
- `ROWID` joins make the scores a snapshot: rows inserted after a run will not
  match until the next one.

## Verified against

Exasol 2026.1.0 (local Docker) · Python 3.12.3 · typesafe-sdk 0.7.0 ·
httpx2 2.13.0 · pydantic 2.13.5 — 10,000 rows scored, 0 errors, ~200 rows/s.

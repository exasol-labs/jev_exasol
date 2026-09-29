# Invoice classification with Jev

<img width="720" height="406" alt="Scoring invoices with Jev inside Exasol" src="https://github.com/user-attachments/assets/92879a7e-fa3a-48f0-bd46-01e0cca1e634" />

Ask a yes/no question in plain English about every invoice in an Exasol table,
and get back a calibrated probability per invoice — directly in SQL.

The yes/no answer comes from TypeSafe's `Noul` primitive. You can change the
code to ask more questions, or to use other primitives such as `Choice` (pick
one of several labels) or `Score` (rate on a scale). The questions are defined
in `exasol/jev_invoice_ai_score.sql`, and `exasol/udfs.sql` has working
examples of all three primitives. A new question or primitive also needs a new
column in the UDF's `EMITS` clause and in `exasol/refresh_ai_invoices.sql`.

```sql
EXECUTE SCRIPT TYPESAFE_LAB.REFRESH_AI_INVOICES(
    'Is `invoice.service_line` a service line whose own deliverable is
     artificial intelligence or machine learning work?');
```

This scores all 10,000 invoices in `BOOK_KEEPING.INVOICES` (one API call per
row) and returns the ones that matched, ordered by confidence.

All commands below are run from this folder (`usecases/invoice_classification`).

## Contents

| File                                       | What it is                                                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `main.py`                                  | Standalone TypeSafe SDK example. Run it first to check your API key works.                                               |
| `exasol/deploy.py`                         | Registers the language alias and the API-key connection, installs `udfs.sql`.                                            |
| `exasol/udfs.sql`                          | Two demo UDFs — `JEV_CLASSIFY` (scalar, JSON out) and `JEV_CLASSIFY_BATCH` (set, concurrent). Installed by `deploy.py`, called by `verify.py`. |
| `exasol/verify.py`                         | Smoke test: container contents, scalar UDF, set UDF.                                                                     |
| `exasol/jev_invoice_ai_score.sql`          | The scoring UDF. Python SET script, takes the question as a parameter, one concurrent API call per row.                  |
| `exasol/refresh_ai_invoices.sql`           | Lua orchestration script. Scores every invoice, rebuilds the result view, returns the matching rows.                     |
| `invoice_dataset/newest_invoices_data.csv` | The 10,000-row reference invoice set.                                                                                    |

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
- Python with `pyexasol`, `python-dotenv` and `typesafe-sdk`.
- [exapump](https://github.com/exasol-labs/exapump) to load the CSV, with a
  connection profile for your database (`exapump profile add default`).
- **UDFs need outbound HTTPS access** to `api.typesafe.ai`. On a locked-down
  cluster none of this works.

## Setup

### 1. API key

Get one from the TypeSafe console at
**[console.typesafe.ai](https://console.typesafe.ai)** — sign in with Google or
an emailed code, then create a key. Put it in a `.env` file in this folder
(it is gitignored):

```bash
echo 'TYPESAFE_API_KEY=sk-...' > .env
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

### 3. Register the language and install the demo UDFs

```bash
python exasol/deploy.py --container typesafe-python-3.12-release-<HASH>
```

This appends `PYTHON3_TYPESAFE=...` to `SCRIPT_LANGUAGES` (system _and_
session), creates `CONNECTION TYPESAFE_API` holding the key from `.env`, and
installs `exasol/udfs.sql`. Point it elsewhere with `--dsn/--user/--password`
and `--bucketfs-name/--bucket/--path-in-bucket`; the defaults target a local
Docker Exasol at `127.0.0.1:9563` with `sys`/`exasol`.

Keeping the key in a `CONNECTION` keeps it out of script text and query logs —
the UDFs read it back via `exa.get_connection("TYPESAFE_API")`.

### 4. Check it

```bash
python exasol/verify.py
```

Expected: the container's library versions, then a scalar and a set UDF result.

### 5. Install the invoice scripts

`deploy.py` installs **only** `udfs.sql`. The two invoice scripts are each a
single `CREATE SCRIPT` whose body swallows anything appended to it, so they
cannot be split on `/` and must be executed whole, one file per statement.
Adjust the connection details to match your database:

```python
import pathlib, pyexasol
con = pyexasol.connect(dsn="127.0.0.1:9563", user="sys", password="exasol",
                       websocket_sslopt={"cert_reqs": 0}, autocommit=True)
for f in ["exasol/jev_invoice_ai_score.sql", "exasol/refresh_ai_invoices.sql"]:
    con.execute(pathlib.Path(f).read_text(encoding="utf-8"))
```

### 6. Load the invoice data

Load the data with [exapump](https://github.com/exasol-labs/exapump). First
create the schema:

```bash
exapump sql "CREATE SCHEMA IF NOT EXISTS BOOK_KEEPING"
```

Then load the dataset. exapump creates `BOOK_KEEPING.INVOICES` itself, taking
the column names from the CSV header and the column types from the data:

```bash
exapump upload invoice_dataset/newest_invoices_data.csv --table BOOK_KEEPING.INVOICES
```

exapump should report `Imported 10000 rows`. If your database isn't your
default exapump profile, add `--profile <name>` right after `sql` and
`upload`.

The reference set is 10,000 rows with 100 distinct `ID_INVOICE` values and six
`SERVICE` values. You can use your own invoice data instead, but its CSV header
must use these uppercase column names:

```
ID_INVOICE,ISSUED_DATE,COUNTRY,SERVICE,TOTAL,DISCOUNT,TAX,INVOICE_STATUS,BALANCE,DUE_DATE,CLIENT
```

exapump uses the header exactly as written. A lowercase or camelCase header
creates case-sensitive columns such as `"issuedDate"`, and the scripts, which
use `ISSUED_DATE`, won't find them.

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

Keep the total in flight (instances × `MAX_CONCURRENCY`) at or below ~64 —
much past that crashed the UDF VM in testing.

## Troubleshooting

**`no definition found for language: PYTHON3_TYPESAFE`** — `SCRIPT_LANGUAGES` is
read once when a session starts, so `ALTER SYSTEM` only reaches sessions opened
after it ran. In clients like DbVisualizer a new tab reuses the existing
connection, so opening a tab is _not_ enough. Diagnose with:

```sql
SELECT SYSTEM_VALUE, SESSION_VALUE FROM SYS.EXA_PARAMETERS
WHERE PARAMETER_NAME = 'SCRIPT_LANGUAGES';
```

If the alias is in `SYSTEM_VALUE` but not `SESSION_VALUE`, reconnect the client.

**`TYPESAFE_API_KEY missing from .env`** — `deploy.py` reads `.env` from this
folder (`usecases/invoice_classification/.env`), not from the repo root.

**`object ISSUED_DATE not found`** — the table was loaded from a CSV whose
header is not uppercase. Fix the header, drop `BOOK_KEEPING.INVOICES`, and
upload again.

**`schema BOOK_KEEPING not found` on upload** — exapump creates the table but
not the schema. Run the `CREATE SCHEMA` command from step 6 first.

**Build fails in `build_deps`** — the flavor templates pin exact apt versions
that Ubuntu eventually supersedes. Check the non-wildcard pins with
`apt-cache madison` in an `ubuntu:24.04` container before building; far cheaper
than finding them one failed build at a time.

**`CERTIFICATE_VERIFY_FAILED` on upload** — add `--no-use-ssl-cert-validation`.

**Every row scores NULL with a connection error** — the UDF host cannot reach
`api.typesafe.ai`. Check egress from the cluster, not from your laptop.

## Known gaps

- The custom flavor lives outside this repo — only the one-package change is
  documented above.
- `ROWID` joins make the scores a snapshot: rows inserted after a run will not
  match until the next one.

## Verified against

Exasol 2026.1.0 (local Docker) · Python 3.12.3 · typesafe-sdk 0.7.0 ·
httpx2 2.13.0 · pydantic 2.13.5 — on the 10,000-row reference dataset.

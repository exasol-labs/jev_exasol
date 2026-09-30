# Entity resolution with Jev

Match messy company records (from a CRM, a vendor list, a web form) to the
official UK company register, and find the duplicates among them, directly in
SQL. Jev decides whether two records describe the same registered company and
explains its decision one field at a time.

The demo covers six kinds of variation. One of them is a German name for a
British company:

| Incoming record                          | Matched company                     | P_SAME | why                    |
| ---------------------------------------- | ----------------------------------- | -----: | ---------------------- |
| `Blau Sanitär und Heizung GmbH`          | BLUE PLUMBING AND HEATING LTD       |   0.84 | name 0.92, address 0.98 |
| `Baraset Propertties Limited`            | BARASET PROPERTIES LIMITED          |   0.94 | name 0.96, address 0.99 |
| `B.P.S. PLASTICS Limited Company`        | B.P.S. PLASTICS LIMITED             |   0.92 | name 0.96, address 0.98 |
| `Ball Mgmt Ltd.` + reformatted address   | BALL MANAGEMENT LTD                 |   0.90 | name 0.97, address 0.95 |
| `Branch Eng`, `WWW.BRANCHENG.CO.UK`      | BRANCH ENG LTD                      |   0.94 | website 0.99           |
| `Alma Y Luna`, VAT `554 4352 25`         | ALMA Y LUNA LTD (VAT GB554435225)   |   0.92 | VAT 0.97               |

It also has to reject look-alikes. `B.L.C.T. (PHC 15C) LIMITED` is not
`B.L.C.T. (PHC 15A) LIMITED`: the string baseline matched the two (name
similarity 0.92), and Jev scored the pair 0.14.

```sql
EXECUTE SCRIPT TYPESAFE_LAB.FIND_ENTITY_CANDIDATES();  -- SQL only, ~13 s
EXECUTE SCRIPT TYPESAFE_LAB.RESOLVE_ENTITIES();        -- 10,636 Jev calls, ~46 s
```

All commands below are run from this folder (`usecases/entity_relation`).

## Results

2,000 incoming records against 849,123 registered companies, compared with a
SQL string-matching baseline on the same candidate pairs. **Correct** means
the record was matched to its true company, or to nothing when it has no
company in the master.

| Variation       | Records | Candidate ceiling |       Jev | Baseline |
| --------------- | ------: | ----------------: | --------: | -------: |
| SPELLING        |     371 |             0.989 | **0.989** |    0.760 |
| LEGAL_SUFFIX    |     341 |             0.994 |     0.994 |    0.991 |
| MIXED           |     327 |             1.000 | **0.997** |    0.737 |
| ADDRESS         |     266 |             1.000 |     1.000 |    1.000 |
| VAT             |     202 |             1.000 |     1.000 |    1.000 |
| DOMAIN          |     198 |             1.000 |     1.000 |    1.000 |
| TRANSLATION     |      45 |             0.844 | **0.800** |    0.022 |
| NO_MATCH        |     250 |             1.000 |     0.880 | **0.940** |
| **All**         |   2,000 |             0.994 | **0.977** |    0.882 |

| Dedup within the incoming records | Jev       | Baseline  |
| --------------------------------- | --------- | --------- |
| Pair precision                    | 0.937     | **1.000** |
| Pair recall                       | **0.997** | 0.816     |

How to read this:

- **Jev wins where names change**: misspellings, several changes at once,
  and translations. Ordinary string matching does not survive these.
- **Exact keys are a tie**. Once a VAT number or website domain is
  normalised in SQL, the baseline finds it just as well. When a clean key
  exists, use it; Jev adds nothing there.
- **The baseline wins on NO_MATCH** (look-alikes of companies that are not
  in the master). Jev is more willing to call two records one company, which
  is also why its dedup precision is lower. Raising the threshold closes the
  gap, see [Choosing the threshold](#choosing-the-threshold).
- **Candidate ceiling** is the share of records whose true company made it
  into the candidate pairs at all. Jev only judges the pairs it is given, so
  7 of the 45 translations were already out of reach before any call was
  made. Candidate search is where embedding similarity helps.

All figures in this README come from the Companies House snapshot of
2026-09-01. Your numbers will differ slightly: the model is not bit-for-bit
deterministic, and Companies House only offers the latest monthly snapshot,
so you will almost certainly load a newer one with different records.

## How it works

```
Companies House CSV (850k rows)          translations.csv (45 hand-written)
        |  prepare_master.py                      |
        v                                         v
COMPANY_MASTER (849,123)  COMPANY_HOLDOUT (876) --> generate_incoming.py
  + made-up VAT_ID, WEBSITE                        |
        |                         INCOMING_RECORDS (2,000)   INCOMING_TRUTH
        |                                  |                 (answer key,
        v                                  v                  never sent)
FIND_ENTITY_CANDIDATES  -- SQL: normalise, block on shared VAT / domain /
        |                  postcode / street / first name word, rank by
        |                  name similarity + shared-key bonus, keep top 5
        |                  per record (+ top 3 dedup)
        v
CANDIDATE_PAIRS (8,892 master + 1,744 dedup)
        |  GROUP BY MOD(PAIR_ID, 4) -> 4 UDF instances x 16 in flight
        v
TYPESAFE_LAB.JEV_ENTITY_MATCH  -- one call per pair, up to 5 Nouls
        v
MATCH_SCORES -> PAIR_DECISIONS -> BEST_MATCH -> INCOMING_CLUSTERS
        v
MATCH_RESULTS, MATCH_EVALUATION, DEDUP_EVALUATION (views)
```

### Finding candidates

Jev judges pairs. It does not search. Checking every incoming record against
every company would mean 1.7 billion pairs, so the candidate step narrows
them down with exact SQL first. It takes about 13 seconds on 849k rows.

Both sides first get the same keys, in `MASTER_KEYS` and `INCOMING_KEYS`:

| Key             | Built from                                                                                                  |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| `NAME_NORM`     | Name in upper case, `&` as `AND`, punctuation removed, legal-form words (LTD, PLC, GMBH, SARL, BV, THE, UK, ...) dropped |
| `NAME_TOKEN1`   | First word of `NAME_NORM`                                                                                   |
| `POSTCODE_NORM` | Postcode without spaces. An incoming record with an empty postcode field uses the UK postcode in its address |
| `ADDRESS_KEY`   | First 12 letters and digits of the street address: `24B Kenilworth Road` becomes `24BKENILWORT`             |
| `VAT_DIGITS`    | Only the digits of the VAT number                                                                           |
| `DOMAIN_ROOT`   | Website without scheme, `www.`, `info@`, subdomain or path: `shop.brancheng.co.uk` becomes `brancheng.co.uk` |

A company is a candidate for an incoming record when the two share at least
one of `VAT_DIGITS`, `DOMAIN_ROOT`, `POSTCODE_NORM`, `ADDRESS_KEY` or
`NAME_TOKEN1` exactly. Each candidate is ranked by

```
  1 - EDIT_DISTANCE(a.NAME_NORM, b.NAME_NORM) / length of the longer name
+ 1    same VAT digits
+ 1    same domain
+ 0.5  same postcode
+ 0.5  same address key
```

and the top `MASTER_K` = 5 companies become `MASTER` pairs, ties going to the
lower company number. Duplicates are found the same way against the other
incoming records: the top `DEDUP_K` = 3 become `DEDUP` pairs, and a record is
only paired with higher `INCOMING_ID`s so each pair appears once. Country is
not used.

A true company that shares none of the keys, or is outranked by five others,
never reaches Jev. The candidate ceiling in the results is the share of
records where that did not happen.

### Asking Jev

Each pair reaches the model as `record_a` (incoming) and `record_b` (a master
company or another incoming record). Each record has `name`, `address`,
`country`, `website` and `vat_id`, and empty fields are left out. One call
asks up to five `Noul` questions:

| Column      | Question                                                            | Asked when                |
| ----------- | ------------------------------------------------------------------- | ------------------------- |
| `P_SAME`    | Do the records describe the same registered company?                 | always                    |
| `P_NAME`    | Do the names name the same company (spelling, translation, suffix)? | always                    |
| `P_ADDRESS` | Same premises?                                                      | both records have one     |
| `P_WEBSITE` | Same website domain?                                                | both records have one     |
| `P_VAT`     | Same VAT registration number, ignoring format?                      | both records have one     |

`P_SAME` is the decision. The other four explain it and do not feed into it.
Code already knows whether a field is present, so it never asks Jev about a
missing one.

`P_SAME`'s criteria say explicitly that **a shared address is not
evidence**. Accountants, formation agents and business centres register
hundreds of unrelated companies at one address. Before that sentence was
added, a shared address plus a loosely similar name was often read as a match
(dedup precision 0.62 instead of 0.94).

The baseline (`BASELINE_MATCH` in `PAIR_DECISIONS`) calls a pair a match when
the VAT digits are equal, OR the website domains are equal, OR the normalised
names have an `EDIT_DISTANCE` similarity of at least 0.85.

## The data

- **Master:** the Companies House *Basic Company Data* extract, part 1 of 7
  (companies whose names start with a digit, A or B), from
  [download.companieshouse.gov.uk](https://download.companieshouse.gov.uk/en_output.html).
  The register has **no VAT numbers or websites**. `prepare_master.py` makes
  them up (65% of companies get a VAT number, 70% a website), deterministic
  and unique, so the VAT and domain variations have something to match.
- **Held-out companies:** 0.1% of companies, chosen by a hash of the company
  number, are kept out of the master in `COMPANY_HOLDOUT`. The NO_MATCH
  records are built from them. They are real companies with real look-alikes
  in the master, but their true answer is "not in the master".
- **Incoming records:** `generate_incoming.py` builds 2,000 records with a
  fixed seed. Each has one variation type, and a matching record carries a
  website or VAT number only when that key *is* the variation. 520 companies
  appear more than once, which is what the dedup half of the demo finds.
- **Translations:** the 45 names in `data/translations.csv` were written by
  hand (German, French, Spanish, Dutch, Italian), with the matching foreign
  legal form.

## Contents

| File                          | What it is                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------- |
| `data/prepare_master.py`      | Loads the Companies House CSV into `COMPANY_MASTER` / `COMPANY_HOLDOUT`, adds VAT and website. |
| `data/translations.csv`       | 45 hand-written translated company names.                                                      |
| `data/generate_incoming.py`   | Builds and loads `INCOMING_RECORDS` and `INCOMING_TRUTH`; also writes them as CSVs.            |
| `exasol/install.py`           | Installs the three scripts below into `TYPESAFE_LAB`.                                          |
| `exasol/find_candidates.sql`  | Lua script `FIND_ENTITY_CANDIDATES`: key tables and `CANDIDATE_PAIRS`, returns candidate recall. |
| `exasol/jev_entity_match.sql` | Python SET UDF `JEV_ENTITY_MATCH`: one Jev call per pair.                                      |
| `exasol/resolve_entities.sql` | Lua script `RESOLVE_ENTITIES`: scores, decides, clusters, evaluates.                           |

## Requirements

The same setup as the [invoice classification](../invoice_classification/README.md)
use case: the custom Script Language Container registered as
`PYTHON3_TYPESAFE`, and `CONNECTION TYPESAFE_API` holding your API key. If
you have run that use case's `deploy.py`, both already exist.

You also need Python with `pyexasol`, part 1 of the Companies House extract
(a 69 MB zip, ~420 MB unzipped, see step 1 below), and room for ~850k rows
in the database.

## Setup

The scripts default to a local Docker Exasol at `127.0.0.1:9563` with
`sys`/`exasol`. Pass `--dsn/--user/--password` to point them elsewhere.

### 1. Download the Companies House data

Open [download.companieshouse.gov.uk/en_output.html](https://download.companieshouse.gov.uk/en_output.html)
and, under the multiple-files option, download **part 1 of 7**:
`BasicCompanyData-<date>-part1_7.zip`. Only this part is used, not the
single-file download. The page is replaced every month, so `<date>` will be
the latest snapshot, not the 2026-09-01 used here. Then unzip it:

```bash
curl -O https://download.companieshouse.gov.uk/BasicCompanyData-<date>-part1_7.zip
unzip BasicCompanyData-<date>-part1_7.zip
```

On Windows without `unzip`, use
`Expand-Archive BasicCompanyData-<date>-part1_7.zip .` in PowerShell.

### 2. Load the master (~1.5 min)

```bash
python data/prepare_master.py --csv path/to/BasicCompanyData-<date>-part1_7.csv
```

Expected: `loaded ... rows into ENTITY_RESOLUTION.COMPANY_MASTER` (about
850k) and `loaded ... rows into ENTITY_RESOLUTION.COMPANY_HOLDOUT` (about
0.1% of that). The 2026-09-01 snapshot gives exactly 849,123 and 876. It
creates the `ENTITY_RESOLUTION` schema if needed.

### 3. Generate the incoming records

```bash
python data/generate_incoming.py
```

Prints the count per variation type and
`loaded 2000 incoming records; ... companies appear more than once` (520
for the 2026-09-01 snapshot). It also overwrites `data/incoming_records.csv`
and `data/incoming_truth.csv`.

The 45 translated records are tied to specific company numbers in
`data/translations.csv`. If a newer snapshot no longer has one of them, this
step stops with `translations.csv companies missing from master`; see
[Troubleshooting](#troubleshooting).

### 4. Install the scripts

```bash
python exasol/install.py
```

## Running it

```sql
EXECUTE SCRIPT TYPESAFE_LAB.FIND_ENTITY_CANDIDATES();
```

No API calls. Rebuilds `MASTER_KEYS`, `INCOMING_KEYS` and `CANDIDATE_PAIRS`,
and returns the candidate recall per variation type. Check that number
before you spend any calls.

```sql
EXECUTE SCRIPT TYPESAFE_LAB.RESOLVE_ENTITIES();
```

Scores every candidate pair (10,636 calls, ~46 s on the local Docker
database), retries failed pairs once, and returns the results table above.
Run `FIND_ENTITY_CANDIDATES` again first whenever the input tables change.

The resolved records:

```sql
SELECT INCOMING_ID, RECORD_NAME, MATCHED_COMPANY_NAME,
       P_SAME, P_NAME, P_ADDRESS, P_WEBSITE, P_VAT, CLUSTER_ID
FROM ENTITY_RESOLUTION.MATCH_RESULTS
ORDER BY CLUSTER_ID, INCOMING_ID;
```

`MATCHED_COMPANY_NAME` is NULL when no candidate reached the threshold.
`CLUSTER_ID` groups the incoming records that Jev considers one company,
named after the lowest `INCOMING_ID` in the group. The three records
`Astoria Court Consultancy Ltd`, `ASTORIA COURT CONSULTING LTD` and
`Astoria Court Consulting Ltd.`, from two different source systems, share
cluster `IN-00015`.

The scores behind the results:

```sql
SELECT * FROM ENTITY_RESOLUTION.MATCH_EVALUATION;    -- per variation type
SELECT * FROM ENTITY_RESOLUTION.DEDUP_EVALUATION;    -- dedup precision / recall
SELECT * FROM ENTITY_RESOLUTION.PAIR_DECISIONS;      -- every pair, both methods
SELECT COUNT(ERROR) FROM ENTITY_RESOLUTION.MATCH_SCORES;  -- failed calls
```

### Choosing the threshold

`RESOLVE_ENTITIES` treats `P_SAME >= 0.5` as a match (`JEV_THRESHOLD` at the
top of the script). How you set it depends on which mistake costs more.
Wrongly merging two companies is usually worse than missing a duplicate.
These figures come from the stored scores of the run above, so changing the
threshold needs no new calls:

| Threshold | All records | NO_MATCH | Records with a true company |
| --------: | ----------: | -------: | --------------------------: |
|       0.5 |       0.977 |    0.880 |                       0.991 |
|       0.6 |       0.978 |    0.900 |                       0.989 |
|       0.7 |       0.975 |    0.944 |                       0.979 |
|       0.8 |       0.950 |    0.976 |                       0.946 |
|       0.9 |       0.788 |    1.000 |                       0.757 |

At 0.7 Jev equals the baseline on NO_MATCH (0.94) and still gets 0.975
overall. A threshold is only the simplest policy. Two others are sending
pairs between 0.5 and 0.8 to a person, or also requiring `P_NAME` to be high.

### Tuning

- `MASTER_K` / `DEDUP_K` at the top of `find_candidates.sql` set how many
  candidates each record gets (5 and 3). More candidates raise the ceiling
  and cost one call each.
- `GROUP BY MOD(PAIR_ID, 4)` in `resolve_entities.sql` and `MAX_CONCURRENCY = 16`
  in `jev_entity_match.sql` give 64 calls in flight. Keep the total at or
  below ~64, as measured in the invoice use case.

## Troubleshooting

**`no definition found for language: PYTHON3_TYPESAFE`**: the client session
predates the language registration. See the
[invoice README](../invoice_classification/README.md#troubleshooting).

**`translations.csv companies missing from master`**: your Companies House
extract differs from 2026-09-01 part 1. Replace the missing company numbers in
`data/translations.csv` with companies from your file.

**`syntax error, unexpected ..._`** when editing the scripts: you used a
reserved word as an identifier (`BLOCKED` and `METHOD` both are). Check it
with `SELECT * FROM EXA_SQL_KEYWORDS WHERE RESERVED AND KEYWORD = '...'`.

**`VM crashed`** while testing the UDF: this happened once during
development, on a query that ran fine on retry and has not recurred. If it
keeps happening, first reduce the in-flight total described under Tuning.

## Known gaps

- VAT numbers and websites are synthetic, and so are all the variations. The
  numbers above measure Jev on messiness this generator produces, not on a
  real CRM export.
- 45 translations is a small sample. Treat 0.800 as an indication, not a
  benchmark.
- The candidate step is string-based, so it misses translated names at busy
  registered-office addresses. Multilingual embeddings would raise the
  ceiling there, with Jev still making the decision.
- `P_SAME` is a single yes/no. The
  [entity alignment cookbook](https://docs.typesafe.ai/cookbooks/entity_alignment.md)
  uses a three-level `Score` (different / related, possibly the same / same)
  so that uncertain pairs go to a person.

## Verified against

Exasol 2026.1.0 (local Docker) · Python 3.12.3 · typesafe-sdk 0.7.0 ·
jev-1.13.0 · Companies House Basic Company Data 2026-09-01, part 1 of 7.

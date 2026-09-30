-- Asks Jev whether two company records describe the same registered company.
--
-- One API call per candidate pair, with up to five yes/no questions in it:
--
--   P_SAME      the decision: same registered company?
--   P_NAME      do the names name the same company (spelling, translation, suffix)?
--   P_ADDRESS   same premises?                    -- asked only if both have an address
--   P_WEBSITE   same website domain?              -- asked only if both have a website
--   P_VAT       same VAT registration number?     -- asked only if both have a VAT number
--
-- Whether a field is present is a fact code already knows, so a question
-- about a missing field is never sent and its column stays NULL. The four
-- field questions explain P_SAME; they do not feed into it.
--
-- The pair reaches the model as `record_a` and `record_b`, each with the keys
-- name, address, country, website, vat_id (empty ones left out).
--
-- Must be the ONLY statement in this file; see find_candidates.sql.
--
-- Requires:
--   * language alias PYTHON3_TYPESAFE
--   * CONNECTION TYPESAFE_API (see usecases/invoice_classification/exasol/deploy.py)

CREATE OR REPLACE PYTHON3_TYPESAFE SET SCRIPT TYPESAFE_LAB.JEV_ENTITY_MATCH(
    pair_id DECIMAL(18,0),
    a_name VARCHAR(300), a_address VARCHAR(4000), a_country VARCHAR(100),
    a_website VARCHAR(300), a_vat VARCHAR(30),
    b_name VARCHAR(300), b_address VARCHAR(4000), b_country VARCHAR(100),
    b_website VARCHAR(300), b_vat VARCHAR(30)
) EMITS (
    pair_id DECIMAL(18,0),
    p_same DOUBLE,
    p_name DOUBLE,
    p_address DOUBLE,
    p_website DOUBLE,
    p_vat DOUBLE,
    error VARCHAR(2000)
) AS
import asyncio
from typesafe_sdk import AsyncTypeSafeClient, Noul, NoulCriteria

# Same setting as the invoice use case: four instances x 16 in flight = 64,
# the most this database handled without crashing the UDF VM.
MAX_CONCURRENCY = 16

SAME = Noul(
    instructions="Do `record_a` and `record_b` describe the same registered company?",
    criteria=NoulCriteria(
        true="One and the same legal entity, even if its name is misspelt, abbreviated, "
             "translated into another language or given a different legal-form suffix "
             "(Ltd, Limited, GmbH, SARL, S.L., B.V.), and even if the address, website or "
             "VAT number is written in a different format.",
        # The last sentence matters: in the UK registry hundreds of unrelated
        # companies share one registered address, and without it a shared
        # address plus a loosely similar name was read as a match.
        false="Two different legal entities, including companies with similar names, "
              "and related but separate companies such as a parent and its subsidiary. "
              "Sharing an address is not evidence of being the same company: accountants, "
              "formation agents and business centres register many unrelated companies "
              "at one address, so the names must refer to the same business.",
    ),
)
FIELD_QUESTIONS = {
    "name": Noul(instructions="Do `record_a.name` and `record_b.name` name the same company, "
                              "allowing for misspellings, abbreviations, translation and a "
                              "different legal-form suffix?"),
    "address": Noul(instructions="Do `record_a.address` and `record_b.address` describe the same "
                                 "premises, allowing for abbreviations, missing parts and "
                                 "different formatting?"),
    "website": Noul(instructions="Do `record_a.website` and `record_b.website` belong to the same "
                                 "website domain?"),
    "vat_id": Noul(instructions="Is `record_a.vat_id` the same VAT registration number as "
                                "`record_b.vat_id`, ignoring spaces, punctuation and the GB "
                                "country prefix?"),
}
FIELDS = ("name", "address", "country", "website", "vat_id")
ASKED_IF_BOTH_PRESENT = ("address", "website", "vat_id")


def _record(values):
    return {k: v for k, v in zip(FIELDS, values) if v is not None}


def _questions(a, b):
    questions = {"same": SAME, "name": FIELD_QUESTIONS["name"]}
    for field in ASKED_IF_BOTH_PRESENT:
        if field in a and field in b:
            questions[field] = FIELD_QUESTIONS[field]
    return questions


async def _score_all(conn, pairs):
    semaphore = asyncio.Semaphore(MAX_CONCURRENCY)

    async with AsyncTypeSafeClient(api_key=conn.password, base_url=conn.address) as client:

        async def one(pair_id, a, b):
            async with semaphore:
                try:
                    response = await client.system_one(
                        state={"record_a": a, "record_b": b},
                        questions=_questions(a, b),
                    )
                except Exception as exc:
                    # One bad pair must not lose the rest of the group.
                    return (pair_id, None, None, None, None, None,
                            "%s: %s" % (type(exc).__name__, str(exc)[:1900]))
            nouls = {k: v.noul for k, v in response.nouls.items()}
            return (pair_id, nouls["same"], nouls["name"], nouls.get("address"),
                    nouls.get("website"), nouls.get("vat_id"), None)

        return await asyncio.gather(*(one(*p) for p in pairs))


def run(ctx):
    pairs = []
    while True:
        a = _record((ctx.a_name, ctx.a_address, ctx.a_country, ctx.a_website, ctx.a_vat))
        b = _record((ctx.b_name, ctx.b_address, ctx.b_country, ctx.b_website, ctx.b_vat))
        pairs.append((ctx.pair_id, a, b))
        if not ctx.next():
            break

    conn = exa.get_connection("TYPESAFE_API")
    for result in asyncio.run(_score_all(conn, pairs)):
        ctx.emit(*result)

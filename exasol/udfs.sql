-- TypeSafe / Jev UDFs for Exasol.
-- Port of main.py: the same three questions (billing / tone / urgency),
-- answered by typesafe-sdk running inside a custom Script Language Container.
--
-- Requires:
--   * SLC deployed and registered under the language alias PYTHON3_TYPESAFE
--   * CONNECTION TYPESAFE_API holding the API key (see deploy.py)
--
-- Statements are separated by a line containing only "/".

CREATE SCHEMA IF NOT EXISTS TYPESAFE_LAB
/

-- Scalar: one document in, one JSON document out.
-- Closest to main.py; costs one API round trip per row.
CREATE OR REPLACE PYTHON3_TYPESAFE SCALAR SCRIPT TYPESAFE_LAB.JEV_CLASSIFY(
    document VARCHAR(2000000)
) RETURNS VARCHAR(2000000) AS
import json
from typesafe_sdk import TypeSafeClient, Choice, Noul, Score

QUESTIONS = {
    "billing": Noul(instructions="Is this ticket about databases?"),
    "tone": Choice(
        instructions="What is the customer's tone?",
        criteria={"calm": None, "frustrated": None, "angry": None},
    ),
    "urgency": Score(
        instructions="How urgent is this ticket?",
        criteria=["can wait", "this week", "today"],
    ),
}

# Reused across rows: the UDF process stays alive for the whole scan,
# so this keeps the HTTPS connection pool warm instead of rebuilding it per row.
_client = None


def _client_once():
    global _client
    if _client is None:
        conn = exa.get_connection("TYPESAFE_API")
        _client = TypeSafeClient(api_key=conn.password, base_url=conn.address)
    return _client


def run(ctx):
    if ctx.document is None:
        return None

    response = _client_once().system_one(
        state={"document": ctx.document},
        questions=QUESTIONS,
    )

    tone = response.choices["tone"]
    urgency = response.scores["urgency"]

    return json.dumps({
        "model": response.model,
        "request_id": response.request_id,
        "input_tokens": response.usage.input_tokens,
        "output_tokens": response.usage.output_tokens,
        "billing": response.nouls["billing"].noul,
        "tone": tone.choice,
        "tone_confidence": tone.confidence,
        "tone_probabilities": tone.probabilities,
        "urgency": urgency.score,
        "urgency_confidence": urgency.confidence,
        # legend/probabilities are keyed by int level; JSON keys must be strings.
        "urgency_legend": {str(k): v for k, v in urgency.legend.items()},
        "urgency_probabilities": {str(k): v for k, v in urgency.probabilities.items()},
    })
/

-- Set: consumes a whole group, fires the requests concurrently, emits typed columns.
-- system_one takes one state per call, so the win here is concurrency, not a batch endpoint.
CREATE OR REPLACE PYTHON3_TYPESAFE SET SCRIPT TYPESAFE_LAB.JEV_CLASSIFY_BATCH(
    id VARCHAR(256),
    document VARCHAR(2000000)
) EMITS (
    id VARCHAR(256),
    billing DOUBLE,
    tone VARCHAR(64),
    tone_confidence DOUBLE,
    urgency DOUBLE,
    urgency_confidence DOUBLE,
    error VARCHAR(2000)
) AS
import asyncio
from typesafe_sdk import AsyncTypeSafeClient, Choice, Noul, Score

# In-flight requests per UDF instance. Exasol already runs one instance per node,
# so the effective cluster-wide concurrency is this times the node count.
MAX_CONCURRENCY = 8

QUESTIONS = {
    "billing": Noul(instructions="Is this ticket about databases?"),
    "tone": Choice(
        instructions="What is the customer's tone?",
        criteria={"calm": None, "frustrated": None, "angry": None},
    ),
    "urgency": Score(
        instructions="How urgent is this ticket?",
        criteria=["can wait", "this week", "today"],
    ),
}

EMPTY = (None, None, None, None, None)


async def _classify_all(conn, rows):
    semaphore = asyncio.Semaphore(MAX_CONCURRENCY)

    async with AsyncTypeSafeClient(api_key=conn.password, base_url=conn.address) as client:

        async def one(row_id, document):
            if document is None:
                return (row_id,) + EMPTY + ("null document",)
            async with semaphore:
                try:
                    response = await client.system_one(
                        state={"document": document},
                        questions=QUESTIONS,
                    )
                except Exception as exc:
                    # One bad row must not lose the rest of the group.
                    return (row_id,) + EMPTY + ("%s: %s" % (type(exc).__name__, str(exc)[:1900]),)

            tone = response.choices["tone"]
            urgency = response.scores["urgency"]
            return (
                row_id,
                response.nouls["billing"].noul,
                tone.choice,
                tone.confidence,
                urgency.score,
                urgency.confidence,
                None,
            )

        # gather preserves input order, so emitted rows line up with the group.
        return await asyncio.gather(*(one(r, d) for r, d in rows))


def run(ctx):
    rows = []
    while True:
        rows.append((ctx.id, ctx.document))
        if not ctx.next():
            break

    conn = exa.get_connection("TYPESAFE_API")
    for result in asyncio.run(_classify_all(conn, rows)):
        ctx.emit(*result)
/

-- Scores one invoice per API call against a caller-supplied yes/no question.
--
-- Deliberately one round trip per row. A question usually turns on one or two
-- fields, so scoring the distinct values of those fields would need far fewer
-- calls -- this UDF exists to demonstrate throughput.
--
-- The question is free text, asked about a single invoice, which the model
-- sees as `invoice` with these keys:
--
--   id, issued_date, country, client, service_line, total, discount, tax,
--   invoice_status, balance, due_date
--
-- Dates arrive as ISO strings, money columns as numbers. Refer to the keys
-- directly, e.g.
--
--   'Is `invoice.service_line` a service line whose own deliverable is
--    artificial intelligence or machine learning work?'
--
-- Must be the ONLY statement in this file: CREATE SCRIPT ... AS consumes
-- everything that follows as the script body, so anything appended here is
-- silently swallowed into the Python source instead of being executed.
--
-- Requires:
--   * language alias PYTHON3_TYPESAFE
--   * CONNECTION TYPESAFE_API (see deploy.py)

CREATE OR REPLACE PYTHON3_TYPESAFE SET SCRIPT TYPESAFE_LAB.JEV_INVOICE_AI_SCORE(
    question VARCHAR(2000),
    row_id DECIMAL(36,0),
    id_invoice DECIMAL(36,0),
    issued_date DATE,
    country VARCHAR(100),
    client VARCHAR(100),
    service VARCHAR(100),
    total DOUBLE,
    discount DOUBLE,
    tax DOUBLE,
    invoice_status VARCHAR(20),
    balance DOUBLE,
    due_date DATE
) EMITS (
    row_id DECIMAL(36,0),
    p_true DOUBLE,
    error VARCHAR(2000)
) AS
import asyncio
from typesafe_sdk import AsyncTypeSafeClient, Noul

# In-flight requests per UDF instance. The caller runs four instances
# (GROUP BY MOD(ID_INVOICE, 4)), so this is 64 concurrent requests overall.
# Measured on this database: one instance saturates near 50 rows/s whatever
# this is set to, four instances reach ~130 rows/s, and anything past ~64
# total in flight crashes the UDF VM.
MAX_CONCURRENCY = 16


def _iso(value):
    # DATE columns arrive as datetime.date, which is not JSON serialisable.
    return value.isoformat() if value is not None else None


async def _score_all(conn, question, rows):
    semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
    questions = {"answer": Noul(instructions=question)}

    async with AsyncTypeSafeClient(api_key=conn.password, base_url=conn.address) as client:

        async def one(row_id, invoice):
            async with semaphore:
                try:
                    response = await client.system_one(
                        state={"invoice": invoice},
                        questions=questions,
                    )
                except Exception as exc:
                    # One bad row must not lose the rest of the group.
                    return (row_id, None, "%s: %s" % (type(exc).__name__, str(exc)[:1900]))
            return (row_id, response.nouls["answer"].noul, None)

        return await asyncio.gather(*(one(r, inv) for r, inv in rows))


def run(ctx):
    # Read before the loop moves the iterator; the question is the same on
    # every row of the group.
    question = ctx.question

    rows = []
    while True:
        rows.append((ctx.row_id, {
            "id": int(ctx.id_invoice),
            "issued_date": _iso(ctx.issued_date),
            "country": ctx.country,
            "client": ctx.client,
            "service_line": ctx.service,
            "total": ctx.total,
            "discount": ctx.discount,
            "tax": ctx.tax,
            "invoice_status": ctx.invoice_status,
            "balance": ctx.balance,
            "due_date": _iso(ctx.due_date),
        }))
        if not ctx.next():
            break

    conn = exa.get_connection("TYPESAFE_API")
    for result in asyncio.run(_score_all(conn, question, rows)):
        ctx.emit(*result)

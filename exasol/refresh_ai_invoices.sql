-- Rebuilds BOOK_KEEPING.MATCHED_INVOICES from scratch:
--   1. scores every invoice with Jev against QUESTION (one API call per row)
--   2. points the view at the fresh scores
-- and returns the matching invoices.
--
--   EXECUTE SCRIPT TYPESAFE_LAB.REFRESH_AI_INVOICES(
--       'Is `invoice.service_line` a service line whose own deliverable is
--        artificial intelligence or machine learning work?');
--
-- The question is free text; see jev_invoice_ai_score.sql for the invoice
-- fields it may refer to. It is passed to the UDF as a bound parameter, so
-- nothing in it needs escaping beyond the usual doubling of ' in the call.
--
-- Rows that failed to score are not in the result. To count them:
--   SELECT COUNT(ERROR) FROM TYPESAFE_LAB.INVOICE_SCORES;
--
-- Both statements are CREATE OR REPLACE, so a failed run leaves nothing
-- half-written -- just run it again.
--
-- Must be the ONLY statement in this file; see jev_invoice_ai_score.sql.
--
-- Requires TYPESAFE_LAB.JEV_INVOICE_AI_SCORE to be installed already.

CREATE OR REPLACE SCRIPT TYPESAFE_LAB.REFRESH_AI_INVOICES(question) RETURNS TABLE AS
    -- GROUP BY MOD(...) is not an aggregation: the number of distinct group
    -- values is the number of parallel UDF instances Exasol starts. Four
    -- buckets of ~2500 rows was the fastest stable setting measured here.
    --
    -- :q is substituted as a quoted constant, so an apostrophe in the
    -- question cannot break out of the statement.
    query([[
        CREATE OR REPLACE TABLE TYPESAFE_LAB.INVOICE_SCORES AS
        SELECT TYPESAFE_LAB.JEV_INVOICE_AI_SCORE(
                   :q, ROWID, ID_INVOICE, ISSUED_DATE, COUNTRY, CLIENT,
                   SERVICE, TOTAL, DISCOUNT, TAX, INVOICE_STATUS, BALANCE,
                   DUE_DATE)
        FROM BOOK_KEEPING.INVOICES
        GROUP BY MOD(ID_INVOICE, 4)
    ]], {q = question})

    -- Joined on ROWID because ID_INVOICE is NOT unique here: 10000 rows share
    -- only 100 distinct ids, so joining on it would fan out roughly 100:1.
    -- ROWID is stable only until the table is reorganised, which makes these
    -- scores a snapshot -- rows inserted later simply will not match.
    query([[
        CREATE OR REPLACE VIEW BOOK_KEEPING.MATCHED_INVOICES AS
        SELECT i.ID_INVOICE, i.ISSUED_DATE, i.COUNTRY, i.SERVICE, i.TOTAL,
               i.DISCOUNT, i.TAX, i.INVOICE_STATUS, i.BALANCE, i.DUE_DATE,
               i.CLIENT, s.P_TRUE
        FROM BOOK_KEEPING.INVOICES i
        JOIN TYPESAFE_LAB.INVOICE_SCORES s
          ON CAST(i.ROWID AS DECIMAL(36,0)) = s.ROW_ID
        WHERE s.P_TRUE >= 0.5
    ]])

    local res = query([[
        SELECT ID_INVOICE, ISSUED_DATE, COUNTRY, SERVICE, TOTAL, DISCOUNT, TAX,
               INVOICE_STATUS, BALANCE, DUE_DATE, CLIENT, P_TRUE
        FROM BOOK_KEEPING.MATCHED_INVOICES
        ORDER BY P_TRUE DESC, ID_INVOICE
    ]])

    -- exit() rejects a query result directly ("expecting table as script
    -- return value"), so the rows are copied into a plain Lua table.
    local rows = {}
    for i = 1, #res do
        local r = res[i]
        rows[i] = {r[1], r[2], r[3], r[4], r[5], r[6],
                   r[7], r[8], r[9], r[10], r[11], r[12]}
    end

    exit(rows,
         "ID_INVOICE DECIMAL(36,0), ISSUED_DATE DATE, COUNTRY VARCHAR(100), "
         .. "SERVICE VARCHAR(100), TOTAL DOUBLE, DISCOUNT DOUBLE, TAX DOUBLE, "
         .. "INVOICE_STATUS VARCHAR(20), BALANCE DOUBLE, DUE_DATE DATE, "
         .. "CLIENT VARCHAR(100), P_TRUE DOUBLE")

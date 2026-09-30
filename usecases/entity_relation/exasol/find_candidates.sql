-- Picks the pairs worth asking Jev about. Pure SQL, no API calls.
--
--   EXECUTE SCRIPT TYPESAFE_LAB.FIND_ENTITY_CANDIDATES();
--
-- Jev judges a pair; it does not search. Comparing 2,000 incoming records
-- with 849k companies would be 1.7 billion pairs, so this script narrows it
-- to a handful of candidates per record with cheap, exact SQL:
--
--   1. MASTER_KEYS / INCOMING_KEYS: normalised name (upper case, punctuation
--      and legal-form words such as LTD, GMBH, S.L. removed), first name word,
--      postcode without spaces (taken from the address if the field is empty),
--      the first 12 letters/digits of the street address, VAT digits, and the
--      bare website domain (no https, www, shop., info@).
--   2. Any company sharing a VAT number, domain, postcode, street address
--      start or first name word with an incoming record is a candidate. Each
--      is ranked by name similarity (EDIT_DISTANCE) plus a bonus per shared key.
--   3. CANDIDATE_PAIRS keeps the top MASTER_K companies per record
--      (PAIR_KIND 'MASTER') and the top DEDUP_K other incoming records
--      (PAIR_KIND 'DEDUP'), with the fields Jev will see for both sides.
--
-- Returns, per variation type, the share of records whose true company made
-- it into the candidates. A match missed here cannot be found by Jev.
--
-- Must be the ONLY statement in this file: CREATE SCRIPT ... AS consumes
-- everything that follows as the script body.

CREATE OR REPLACE SCRIPT TYPESAFE_LAB.FIND_ENTITY_CANDIDATES() RETURNS TABLE AS
    local MASTER_K = 5
    local DEDUP_K = 3

    local function name_norm(col)
        return [[TRIM(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
            REPLACE(UPPER(]] .. col .. [[), '&', ' AND '), '[.'']', ''), '[^\p{L}\p{N}]+', ' '),
            '\b(LIMITED|LTD|PLC|LLP|LP|CIC|CO|COMPANY|THE|UK|GMBH|AG|SA|SAS|SARL|SL|SRL|BV|NV)\b', ''),
            ' +', ' '))]]
    end

    local function domain_root(col)
        return [[REGEXP_SUBSTR(REGEXP_REPLACE(LOWER(]] .. col .. [[),
            '^(https?://)?([^@/]*@)?(www\.)?([^/]+).*$', '\4'), '[^.]+\.(co\.uk|[^.]+)$')]]
    end

    -- NULL || 'x' is 'x' in Exasol, so missing parts leave runs of ", " to tidy up.
    local function tidy(expr)
        return [[REGEXP_REPLACE(REGEXP_REPLACE(]] .. expr .. [[, '(, )+', ', '), '^(, )+|(, )+$', '')]]
    end

    -- "24B Kenilworth Road, Bridge Of Allan" and "24B KENILWORTH ROAD" -> 24BKENILWORT
    local function address_key(col)
        return [[SUBSTR(REGEXP_REPLACE(UPPER(]] .. col .. [[), '[^A-Z0-9]', ''), 1, 12)]]
    end

    local POSTCODE_IN_TEXT = [['\b[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}\b']]

    query([[
        CREATE OR REPLACE TABLE ENTITY_RESOLUTION.MASTER_KEYS AS
        SELECT COMPANY_NUMBER,
               COMPANY_NAME,
               NAME_NORM,
               REGEXP_SUBSTR(NAME_NORM, '^\S+')              AS NAME_TOKEN1,
               REPLACE(UPPER(POSTCODE), ' ', '')             AS POSTCODE_NORM,
               ]] .. address_key("ADDRESS_LINE1") .. [[      AS ADDRESS_KEY,
               NULLIF(REGEXP_REPLACE(VAT_ID, '[^0-9]', ''), '') AS VAT_DIGITS,
               ]] .. domain_root("WEBSITE") .. [[           AS DOMAIN_ROOT,
               ]] .. tidy("ADDRESS_LINE1 || ', ' || ADDRESS_LINE2 || ', ' || POST_TOWN || ', ' || POSTCODE") .. [[ AS FULL_ADDRESS,
               COUNTRY, WEBSITE, VAT_ID
        FROM (SELECT m.*, ]] .. name_norm("COMPANY_NAME") .. [[ AS NAME_NORM
              FROM ENTITY_RESOLUTION.COMPANY_MASTER m)
    ]])

    query([[
        CREATE OR REPLACE TABLE ENTITY_RESOLUTION.INCOMING_KEYS AS
        SELECT INCOMING_ID,
               RECORD_NAME,
               NAME_NORM,
               REGEXP_SUBSTR(NAME_NORM, '^\S+')              AS NAME_TOKEN1,
               COALESCE(REPLACE(UPPER(POSTCODE), ' ', ''),
                        REPLACE(REGEXP_SUBSTR(UPPER(ADDRESS), ]] .. POSTCODE_IN_TEXT .. [[), ' ', ''))
                                                             AS POSTCODE_NORM,
               ]] .. address_key("ADDRESS") .. [[            AS ADDRESS_KEY,
               NULLIF(REGEXP_REPLACE(VAT_ID, '[^0-9]', ''), '') AS VAT_DIGITS,
               ]] .. domain_root("WEBSITE") .. [[           AS DOMAIN_ROOT,
               ]] .. tidy("ADDRESS || ', ' || POSTCODE") .. [[ AS FULL_ADDRESS,
               COUNTRY, WEBSITE, VAT_ID
        FROM (SELECT r.*, ]] .. name_norm("RECORD_NAME") .. [[ AS NAME_NORM
              FROM ENTITY_RESOLUTION.INCOMING_RECORDS r)
    ]])

    -- One candidate query per pair kind; only the right-hand table and the
    -- id comparison differ. B_KEYS is MASTER_KEYS or INCOMING_KEYS.
    local function candidates(kind, b_table, b_id, b_name, k, extra_join)
        return [[
        SELECT ']] .. kind .. [[' AS PAIR_KIND, A_ID, B_ID, NAME_SIM, VAT_EQUAL, DOMAIN_EQUAL,
               POSTCODE_EQUAL, CANDIDATE_RANK,
               A_NAME, A_ADDRESS, A_COUNTRY, A_WEBSITE, A_VAT,
               B_NAME, B_ADDRESS, B_COUNTRY, B_WEBSITE, B_VAT
        FROM (
            SELECT a.INCOMING_ID AS A_ID, b.]] .. b_id .. [[ AS B_ID,
                   CAST(1 - EDIT_DISTANCE(a.NAME_NORM, b.NAME_NORM)
                        / GREATEST(LENGTH(a.NAME_NORM), LENGTH(b.NAME_NORM), 1) AS DOUBLE) AS NAME_SIM,
                   NVL(a.VAT_DIGITS = b.VAT_DIGITS, FALSE)       AS VAT_EQUAL,
                   NVL(a.DOMAIN_ROOT = b.DOMAIN_ROOT, FALSE)     AS DOMAIN_EQUAL,
                   NVL(a.POSTCODE_NORM = b.POSTCODE_NORM, FALSE) AS POSTCODE_EQUAL,
                   a.RECORD_NAME AS A_NAME, a.FULL_ADDRESS AS A_ADDRESS, a.COUNTRY AS A_COUNTRY,
                   a.WEBSITE AS A_WEBSITE, a.VAT_ID AS A_VAT,
                   b.]] .. b_name .. [[ AS B_NAME, b.FULL_ADDRESS AS B_ADDRESS, b.COUNTRY AS B_COUNTRY,
                   b.WEBSITE AS B_WEBSITE, b.VAT_ID AS B_VAT,
                   ROW_NUMBER() OVER (
                       PARTITION BY a.INCOMING_ID
                       ORDER BY CAST(1 - EDIT_DISTANCE(a.NAME_NORM, b.NAME_NORM)
                                     / GREATEST(LENGTH(a.NAME_NORM), LENGTH(b.NAME_NORM), 1) AS DOUBLE)
                                + CASE WHEN a.VAT_DIGITS = b.VAT_DIGITS THEN 1 ELSE 0 END
                                + CASE WHEN a.DOMAIN_ROOT = b.DOMAIN_ROOT THEN 1 ELSE 0 END
                                + CASE WHEN a.POSTCODE_NORM = b.POSTCODE_NORM THEN 0.5 ELSE 0 END
                                + CASE WHEN a.ADDRESS_KEY = b.ADDRESS_KEY THEN 0.5 ELSE 0 END DESC,
                                b.]] .. b_id .. [[) AS CANDIDATE_RANK
            FROM (SELECT a.INCOMING_ID AS AID, b.]] .. b_id .. [[ AS BID
                  FROM ENTITY_RESOLUTION.INCOMING_KEYS a JOIN ]] .. b_table .. [[ b ON a.VAT_DIGITS = b.VAT_DIGITS
                  UNION
                  SELECT a.INCOMING_ID, b.]] .. b_id .. [[ FROM ENTITY_RESOLUTION.INCOMING_KEYS a
                  JOIN ]] .. b_table .. [[ b ON a.DOMAIN_ROOT = b.DOMAIN_ROOT
                  UNION
                  SELECT a.INCOMING_ID, b.]] .. b_id .. [[ FROM ENTITY_RESOLUTION.INCOMING_KEYS a
                  JOIN ]] .. b_table .. [[ b ON a.POSTCODE_NORM = b.POSTCODE_NORM
                  UNION
                  SELECT a.INCOMING_ID, b.]] .. b_id .. [[ FROM ENTITY_RESOLUTION.INCOMING_KEYS a
                  JOIN ]] .. b_table .. [[ b ON a.ADDRESS_KEY = b.ADDRESS_KEY
                  UNION
                  SELECT a.INCOMING_ID, b.]] .. b_id .. [[ FROM ENTITY_RESOLUTION.INCOMING_KEYS a
                  JOIN ]] .. b_table .. [[ b ON a.NAME_TOKEN1 = b.NAME_TOKEN1) blk
            JOIN ENTITY_RESOLUTION.INCOMING_KEYS a ON a.INCOMING_ID = blk.AID
            JOIN ]] .. b_table .. [[ b ON b.]] .. b_id .. [[ = blk.BID
            ]] .. extra_join .. [[
        ) WHERE CANDIDATE_RANK <= ]] .. k
    end

    query([[
        CREATE OR REPLACE TABLE ENTITY_RESOLUTION.CANDIDATE_PAIRS AS
        SELECT CAST(ROW_NUMBER() OVER (ORDER BY PAIR_KIND DESC, A_ID, CANDIDATE_RANK) AS DECIMAL(18,0)) AS PAIR_ID, c.*
        FROM (]] .. candidates("MASTER", "ENTITY_RESOLUTION.MASTER_KEYS", "COMPANY_NUMBER",
                               "COMPANY_NAME", MASTER_K, "") .. [[
              UNION ALL
              ]] .. candidates("DEDUP", "ENTITY_RESOLUTION.INCOMING_KEYS", "INCOMING_ID",
                               "RECORD_NAME", DEDUP_K, "WHERE a.INCOMING_ID < b.INCOMING_ID") .. [[
        ) c
    ]])

    local res = query([[
        SELECT NVL(VARIATION_TYPE, 'ALL'),
               COUNT(*),
               ROUND(AVG(CASE WHEN TRUE_COMPANY_NUMBER IS NOT NULL THEN HIT END), 3),
               SUM(PAIRS)
        FROM (SELECT t.INCOMING_ID, t.VARIATION_TYPE, t.TRUE_COMPANY_NUMBER,
                     MAX(CASE WHEN c.B_ID = t.TRUE_COMPANY_NUMBER THEN 1 ELSE 0 END) AS HIT,
                     COUNT(c.B_ID) AS PAIRS
              FROM ENTITY_RESOLUTION.INCOMING_TRUTH t
              LEFT JOIN ENTITY_RESOLUTION.CANDIDATE_PAIRS c
                ON c.PAIR_KIND = 'MASTER' AND c.A_ID = t.INCOMING_ID
              GROUP BY t.INCOMING_ID, t.VARIATION_TYPE, t.TRUE_COMPANY_NUMBER)
        GROUP BY GROUPING SETS ((VARIATION_TYPE), ())
        ORDER BY GROUPING(VARIATION_TYPE), 1
    ]])

    -- exit() rejects a query result directly, so the rows are copied.
    local rows = {}
    for i = 1, #res do
        rows[i] = {res[i][1], res[i][2], res[i][3], res[i][4]}
    end
    local dedup = query([[
        SELECT COUNT(*) FROM ENTITY_RESOLUTION.CANDIDATE_PAIRS WHERE PAIR_KIND = 'DEDUP'
    ]])
    rows[#rows + 1] = {"DEDUP", NULL, NULL, dedup[1][1]}

    -- NO_MATCH has no true company, so its CANDIDATE_RECALL is NULL.
    exit(rows, "VARIATION_TYPE VARCHAR(20), RECORDS DECIMAL(18,0), "
               .. "CANDIDATE_RECALL DOUBLE, PAIRS DECIMAL(18,0)")

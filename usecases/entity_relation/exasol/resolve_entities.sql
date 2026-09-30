-- Scores every candidate pair with Jev, resolves the records, and reports
-- how Jev and a SQL string-matching baseline did against the answer key.
--
--   EXECUTE SCRIPT TYPESAFE_LAB.FIND_ENTITY_CANDIDATES();   -- first, no API calls
--   EXECUTE SCRIPT TYPESAFE_LAB.RESOLVE_ENTITIES();         -- one API call per pair
--
-- Steps:
--   1. MATCH_SCORES    JEV_ENTITY_MATCH on every row of CANDIDATE_PAIRS.
--                      Pairs that failed are retried once.
--   2. PAIR_DECISIONS  per pair: JEV_MATCH (P_SAME >= 0.5) and BASELINE_MATCH
--                      (same VAT digits, OR same website domain, OR name
--                      similarity >= 0.85 by EDIT_DISTANCE after normalising).
--   3. BEST_MATCH      per incoming record, the master company each method
--                      picks: Jev's highest P_SAME among its matches, the
--                      baseline's VAT > domain > name-similarity order. None
--                      if no candidate matched.
--   4. INCOMING_CLUSTERS  duplicates within the incoming records, per method:
--                      connected components over matching DEDUP pairs plus
--                      "both matched the same master company".
--   5. Views MATCH_RESULTS (the resolved records), MATCH_EVALUATION and
--      DEDUP_EVALUATION (scores against INCOMING_TRUTH).
--
-- Returns one row per metric: master-match accuracy per variation type, then
-- dedup pair precision and recall.
--
-- Must be the ONLY statement in this file; see find_candidates.sql.
--
-- Requires TYPESAFE_LAB.JEV_ENTITY_MATCH and a fresh CANDIDATE_PAIRS.

CREATE OR REPLACE SCRIPT TYPESAFE_LAB.RESOLVE_ENTITIES() RETURNS TABLE AS
    local JEV_THRESHOLD = 0.5
    local BASELINE_NAME_SIM = 0.85

    -- GROUP BY MOD(...) is not an aggregation: it starts four parallel UDF
    -- instances, the setting the invoice use case measured as fastest.
    local SCORE = [[
        SELECT TYPESAFE_LAB.JEV_ENTITY_MATCH(
                   PAIR_ID, A_NAME, A_ADDRESS, A_COUNTRY, A_WEBSITE, A_VAT,
                   B_NAME, B_ADDRESS, B_COUNTRY, B_WEBSITE, B_VAT)
        FROM ENTITY_RESOLUTION.CANDIDATE_PAIRS ]]

    -- 1. Score, then retry the failures once (rate limits, timeouts).
    query("CREATE OR REPLACE TABLE ENTITY_RESOLUTION.MATCH_SCORES AS " .. SCORE
          .. " GROUP BY MOD(PAIR_ID, 4)")

    -- CAST to DOUBLE: a DECIMAL arrives in Lua as a decimal object, not a number.
    local failed = query([[SELECT CAST(COUNT(*) AS DOUBLE) FROM ENTITY_RESOLUTION.MATCH_SCORES
                           WHERE ERROR IS NOT NULL]])[1][1]
    if failed > 0 then
        query("CREATE OR REPLACE TABLE ENTITY_RESOLUTION.MATCH_RETRY AS " .. SCORE
              .. [[ WHERE PAIR_ID IN (SELECT PAIR_ID FROM ENTITY_RESOLUTION.MATCH_SCORES
                                      WHERE ERROR IS NOT NULL)
                    GROUP BY MOD(PAIR_ID, 4)]])
        query([[
            MERGE INTO ENTITY_RESOLUTION.MATCH_SCORES s
            USING ENTITY_RESOLUTION.MATCH_RETRY r ON s.PAIR_ID = r.PAIR_ID
            WHEN MATCHED THEN UPDATE SET
                P_SAME = r.P_SAME, P_NAME = r.P_NAME, P_ADDRESS = r.P_ADDRESS,
                P_WEBSITE = r.P_WEBSITE, P_VAT = r.P_VAT, ERROR = r.ERROR
        ]])
        query("DROP TABLE ENTITY_RESOLUTION.MATCH_RETRY")
    end

    -- 2. Per-pair decisions for both methods.
    query([[
        CREATE OR REPLACE TABLE ENTITY_RESOLUTION.PAIR_DECISIONS AS
        SELECT c.PAIR_ID, c.PAIR_KIND, c.A_ID, c.B_ID, c.CANDIDATE_RANK,
               c.NAME_SIM, c.VAT_EQUAL, c.DOMAIN_EQUAL, c.POSTCODE_EQUAL,
               s.P_SAME, s.P_NAME, s.P_ADDRESS, s.P_WEBSITE, s.P_VAT, s.ERROR,
               NVL(s.P_SAME >= :jt, FALSE)                                AS JEV_MATCH,
               (c.VAT_EQUAL OR c.DOMAIN_EQUAL OR c.NAME_SIM >= :bt)       AS BASELINE_MATCH
        FROM ENTITY_RESOLUTION.CANDIDATE_PAIRS c
        LEFT JOIN ENTITY_RESOLUTION.MATCH_SCORES s ON s.PAIR_ID = c.PAIR_ID
    ]], {jt = JEV_THRESHOLD, bt = BASELINE_NAME_SIM})

    -- 3. One master company (or none) per incoming record, per method.
    query([[
        CREATE OR REPLACE TABLE ENTITY_RESOLUTION.BEST_MATCH AS
        SELECT r.INCOMING_ID,
               j.B_ID    AS JEV_COMPANY_NUMBER,
               j.P_SAME  AS JEV_P_SAME,
               b.B_ID    AS BASELINE_COMPANY_NUMBER
        FROM ENTITY_RESOLUTION.INCOMING_RECORDS r
        LEFT JOIN (SELECT A_ID, B_ID, P_SAME,
                          ROW_NUMBER() OVER (PARTITION BY A_ID ORDER BY P_SAME DESC, B_ID) AS RN
                   FROM ENTITY_RESOLUTION.PAIR_DECISIONS
                   WHERE PAIR_KIND = 'MASTER' AND JEV_MATCH) j
          ON j.A_ID = r.INCOMING_ID AND j.RN = 1
        LEFT JOIN (SELECT A_ID, B_ID,
                          ROW_NUMBER() OVER (
                              PARTITION BY A_ID
                              ORDER BY CASE WHEN VAT_EQUAL THEN 1 ELSE 0 END DESC,
                                       CASE WHEN DOMAIN_EQUAL THEN 1 ELSE 0 END DESC,
                                       NAME_SIM DESC, B_ID) AS RN
                   FROM ENTITY_RESOLUTION.PAIR_DECISIONS
                   WHERE PAIR_KIND = 'MASTER' AND BASELINE_MATCH) b
          ON b.A_ID = r.INCOMING_ID AND b.RN = 1
    ]])

    -- 4. Clusters of incoming records that are the same company. Master
    -- companies join the graph as 'M:<number>' nodes, so two records matched
    -- to the same company land in one cluster. Each node repeatedly takes the
    -- smallest label among its neighbours until nothing changes; 'IN-...' sorts
    -- before 'M:...', so a cluster is named after its lowest incoming id.
    query([[CREATE OR REPLACE TABLE ENTITY_RESOLUTION.INCOMING_CLUSTERS (
                MATCHER VARCHAR(10), INCOMING_ID VARCHAR(10), CLUSTER_ID VARCHAR(12))]])

    local function cluster(method, match_column, company_column)
        query([[
            CREATE OR REPLACE TABLE ENTITY_RESOLUTION.CLUSTER_EDGES AS
            SELECT X, Y FROM (
                SELECT A_ID AS X, B_ID AS Y FROM ENTITY_RESOLUTION.PAIR_DECISIONS
                WHERE PAIR_KIND = 'DEDUP' AND ]] .. match_column .. [[
                UNION ALL
                SELECT INCOMING_ID, 'M:' || ]] .. company_column .. [[
                FROM ENTITY_RESOLUTION.BEST_MATCH WHERE ]] .. company_column .. [[ IS NOT NULL)
            UNION ALL
            SELECT Y, X FROM (
                SELECT A_ID AS X, B_ID AS Y FROM ENTITY_RESOLUTION.PAIR_DECISIONS
                WHERE PAIR_KIND = 'DEDUP' AND ]] .. match_column .. [[
                UNION ALL
                SELECT INCOMING_ID, 'M:' || ]] .. company_column .. [[
                FROM ENTITY_RESOLUTION.BEST_MATCH WHERE ]] .. company_column .. [[ IS NOT NULL)
        ]])
        query([[
            CREATE OR REPLACE TABLE ENTITY_RESOLUTION.CLUSTER_LABELS AS
            SELECT NODE, NODE AS LABEL FROM (
                SELECT INCOMING_ID AS NODE FROM ENTITY_RESOLUTION.INCOMING_RECORDS
                UNION SELECT X FROM ENTITY_RESOLUTION.CLUSTER_EDGES)
        ]])
        for _ = 1, 100 do
            query([[
                CREATE OR REPLACE TABLE ENTITY_RESOLUTION.CLUSTER_NEXT AS
                SELECT l.NODE, LEAST(l.LABEL, NVL(MIN(n.LABEL), l.LABEL)) AS LABEL
                FROM ENTITY_RESOLUTION.CLUSTER_LABELS l
                LEFT JOIN ENTITY_RESOLUTION.CLUSTER_EDGES e ON e.X = l.NODE
                LEFT JOIN ENTITY_RESOLUTION.CLUSTER_LABELS n ON n.NODE = e.Y
                GROUP BY l.NODE, l.LABEL
            ]])
            local changed = query([[
                SELECT CAST(COUNT(*) AS DOUBLE)
                FROM ENTITY_RESOLUTION.CLUSTER_NEXT x
                JOIN ENTITY_RESOLUTION.CLUSTER_LABELS l ON l.NODE = x.NODE
                WHERE x.LABEL <> l.LABEL
            ]])[1][1]
            query([[CREATE OR REPLACE TABLE ENTITY_RESOLUTION.CLUSTER_LABELS AS
                    SELECT * FROM ENTITY_RESOLUTION.CLUSTER_NEXT]])
            if changed == 0 then break end
        end
        query([[
            INSERT INTO ENTITY_RESOLUTION.INCOMING_CLUSTERS
            SELECT :m, NODE, LABEL FROM ENTITY_RESOLUTION.CLUSTER_LABELS WHERE NODE LIKE 'IN-%'
        ]], {m = method})
    end

    cluster("JEV", "JEV_MATCH", "JEV_COMPANY_NUMBER")
    cluster("BASELINE", "BASELINE_MATCH", "BASELINE_COMPANY_NUMBER")
    query("DROP TABLE ENTITY_RESOLUTION.CLUSTER_EDGES")
    query("DROP TABLE ENTITY_RESOLUTION.CLUSTER_LABELS")
    query("DROP TABLE ENTITY_RESOLUTION.CLUSTER_NEXT")

    -- 5. The resolved records, with Jev's per-field answers as the explanation.
    query([[
        CREATE OR REPLACE VIEW ENTITY_RESOLUTION.MATCH_RESULTS AS
        SELECT r.INCOMING_ID, r.SOURCE_SYSTEM, r.RECORD_NAME, r.ADDRESS, r.POSTCODE,
               r.WEBSITE, r.VAT_ID,
               m.COMPANY_NUMBER AS MATCHED_COMPANY_NUMBER,
               m.COMPANY_NAME   AS MATCHED_COMPANY_NAME,
               d.P_SAME, d.P_NAME, d.P_ADDRESS, d.P_WEBSITE, d.P_VAT,
               k.CLUSTER_ID
        FROM ENTITY_RESOLUTION.INCOMING_RECORDS r
        JOIN ENTITY_RESOLUTION.BEST_MATCH bm ON bm.INCOMING_ID = r.INCOMING_ID
        LEFT JOIN ENTITY_RESOLUTION.COMPANY_MASTER m ON m.COMPANY_NUMBER = bm.JEV_COMPANY_NUMBER
        LEFT JOIN ENTITY_RESOLUTION.PAIR_DECISIONS d
          ON d.PAIR_KIND = 'MASTER' AND d.A_ID = r.INCOMING_ID AND d.B_ID = bm.JEV_COMPANY_NUMBER
        LEFT JOIN ENTITY_RESOLUTION.INCOMING_CLUSTERS k
          ON k.MATCHER = 'JEV' AND k.INCOMING_ID = r.INCOMING_ID
    ]])

    -- A record is right when the method picked its true company, or picked
    -- nothing for a NO_MATCH record. CANDIDATE_CEILING is the best any method
    -- could do given the candidates FIND_ENTITY_CANDIDATES produced.
    query([[
        CREATE OR REPLACE VIEW ENTITY_RESOLUTION.MATCH_EVALUATION AS
        SELECT NVL(t.VARIATION_TYPE, 'ALL') AS VARIATION_TYPE,
               COUNT(*) AS RECORDS,
               ROUND(AVG(CASE WHEN t.TRUE_COMPANY_NUMBER IS NULL OR h.A_ID IS NOT NULL
                              THEN 1 ELSE 0 END), 3) AS CANDIDATE_CEILING,
               ROUND(AVG(CASE WHEN NVL(b.JEV_COMPANY_NUMBER, '-') = NVL(t.TRUE_COMPANY_NUMBER, '-')
                              THEN 1 ELSE 0 END), 3) AS JEV_ACCURACY,
               ROUND(AVG(CASE WHEN NVL(b.BASELINE_COMPANY_NUMBER, '-') = NVL(t.TRUE_COMPANY_NUMBER, '-')
                              THEN 1 ELSE 0 END), 3) AS BASELINE_ACCURACY
        FROM ENTITY_RESOLUTION.INCOMING_TRUTH t
        JOIN ENTITY_RESOLUTION.BEST_MATCH b ON b.INCOMING_ID = t.INCOMING_ID
        LEFT JOIN (SELECT DISTINCT A_ID, B_ID FROM ENTITY_RESOLUTION.CANDIDATE_PAIRS
                   WHERE PAIR_KIND = 'MASTER') h
          ON h.A_ID = t.INCOMING_ID AND h.B_ID = t.TRUE_COMPANY_NUMBER
        GROUP BY GROUPING SETS ((t.VARIATION_TYPE), ())
    ]])

    -- Pairwise: of all pairs of incoming records put in one cluster, how many
    -- are truly the same company (precision), and of all truly-same pairs,
    -- how many share a cluster (recall). n records in a group make n(n-1)/2 pairs.
    query([[
        CREATE OR REPLACE VIEW ENTITY_RESOLUTION.DEDUP_EVALUATION AS
        WITH labelled AS (
            SELECT k.MATCHER, k.CLUSTER_ID, t.ENTITY_ID
            FROM ENTITY_RESOLUTION.INCOMING_CLUSTERS k
            JOIN ENTITY_RESOLUTION.INCOMING_TRUTH t ON t.INCOMING_ID = k.INCOMING_ID
        ), predicted AS (
            SELECT MATCHER, SUM(N * (N - 1) / 2) AS PAIRS
            FROM (SELECT MATCHER, CLUSTER_ID, COUNT(*) AS N FROM labelled GROUP BY MATCHER, CLUSTER_ID)
            GROUP BY MATCHER
        ), correct AS (
            SELECT MATCHER, SUM(N * (N - 1) / 2) AS PAIRS
            FROM (SELECT MATCHER, CLUSTER_ID, ENTITY_ID, COUNT(*) AS N
                  FROM labelled GROUP BY MATCHER, CLUSTER_ID, ENTITY_ID)
            GROUP BY MATCHER
        ), truth AS (
            SELECT SUM(N * (N - 1) / 2) AS PAIRS
            FROM (SELECT ENTITY_ID, COUNT(*) AS N FROM ENTITY_RESOLUTION.INCOMING_TRUTH GROUP BY ENTITY_ID)
        )
        SELECT p.MATCHER,
               t.PAIRS AS TRUE_DUPLICATE_PAIRS,
               p.PAIRS AS PREDICTED_PAIRS,
               c.PAIRS AS CORRECT_PAIRS,
               ROUND(c.PAIRS / NULLIF(p.PAIRS, 0), 3) AS PAIR_PRECISION,
               ROUND(c.PAIRS / t.PAIRS, 3) AS PAIR_RECALL
        FROM predicted p JOIN correct c ON c.MATCHER = p.MATCHER CROSS JOIN truth t
    ]])

    local res = query([[
        SELECT 'match accuracy: ' || VARIATION_TYPE, RECORDS, CANDIDATE_CEILING,
               JEV_ACCURACY, BASELINE_ACCURACY, CASE WHEN VARIATION_TYPE = 'ALL' THEN 1 ELSE 0 END AS O
        FROM ENTITY_RESOLUTION.MATCH_EVALUATION
        UNION ALL
        SELECT 'dedup pair precision', NULL, NULL,
               MAX(CASE WHEN MATCHER = 'JEV' THEN PAIR_PRECISION END),
               MAX(CASE WHEN MATCHER = 'BASELINE' THEN PAIR_PRECISION END), 2
        FROM ENTITY_RESOLUTION.DEDUP_EVALUATION
        UNION ALL
        SELECT 'dedup pair recall', NULL, NULL,
               MAX(CASE WHEN MATCHER = 'JEV' THEN PAIR_RECALL END),
               MAX(CASE WHEN MATCHER = 'BASELINE' THEN PAIR_RECALL END), 3
        FROM ENTITY_RESOLUTION.DEDUP_EVALUATION
        ORDER BY 6, 1
    ]])

    -- exit() rejects a query result directly, so the rows are copied.
    local rows = {}
    for i = 1, #res do
        rows[i] = {res[i][1], res[i][2], res[i][3], res[i][4], res[i][5]}
    end
    exit(rows, "METRIC VARCHAR(60), RECORDS DECIMAL(18,0), CANDIDATE_CEILING DOUBLE, "
               .. "JEV DOUBLE, BASELINE DOUBLE")

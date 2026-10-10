-- =====================================================================================
--  Omni search access path. Run as MERIDIAN_TRANSFORMER after the first
--      dbt build -s omni_search --target prod
--  Re-run it after any --full-refresh of omni_search (a replace drops the path).
--
--  Enterprise edition. Search Optimization is not on Standard.
--  Equality search optimization does NOT accelerate "part of an id".
--  CONTAINS / ILIKE '%fragment%' needs the SUBSTRING method. Perf lab 07 measures
--  the difference on the 100M-row table; this script turns it on for the real index.
-- =====================================================================================
USE ROLE MERIDIAN_TRANSFORMER;
USE WAREHOUSE WH_TRANSFORM_XS;

-- What the build will cost before you commit to it. Read the estimate on camera.
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS(
    'MERIDIAN_ANALYTICS.MARTS.OMNI_SEARCH',
    'SUBSTRING(search_text)'
);

ALTER TABLE MERIDIAN_ANALYTICS.MARTS.OMNI_SEARCH
    ADD SEARCH OPTIMIZATION ON SUBSTRING(search_text);

-- Background build. Wait until search_optimization_progress = 100 before the timed demo.
SHOW TABLES LIKE 'OMNI_SEARCH' IN SCHEMA MERIDIAN_ANALYTICS.MARTS;

-- Demo. Four characters minimum: a shorter fragment matches too much of the bank,
-- and it is the rule the app enforces. No function around search_text.
SET fragment = '0001';
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
ALTER SESSION SET QUERY_TAG = 'omni_search_demo';

SELECT entity_type, match_on, entity_id, search_text, occurred_on, summary, source_model
FROM MERIDIAN_ANALYTICS.MARTS.OMNI_SEARCH
WHERE CONTAINS(search_text, $fragment)
ORDER BY IFF(search_text = $fragment, 0, 1), LENGTH(search_text), occurred_on DESC NULLS LAST
LIMIT 50;

-- Same SQL, four logins. The text matches; the rows must not.
-- A customer sees only identifiers on their own customer_id.

-- While the access path exists it bills maintenance credits on every merge into the table.
-- Drop it if you are done with the episode:
-- ALTER TABLE MERIDIAN_ANALYTICS.MARTS.OMNI_SEARCH DROP SEARCH OPTIMIZATION;

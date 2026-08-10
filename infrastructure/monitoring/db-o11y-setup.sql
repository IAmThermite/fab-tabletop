-- Grafana Cloud database observability — monitoring role for one database.
--
-- Run once per database you want to appear in Grafana, as a superuser:
--
--   psql -U fabtabletop -d fabtabletop \
--        -v db_o11y_password="$(cat /dev/stdin)" \
--        -f db-o11y-setup.sql
--
-- Idempotent: re-running rotates the password and re-applies the grants.
--
-- The server-level settings this depends on (shared_preload_libraries,
-- compute_query_id, pg_stat_statements.track, track_activity_query_size) are
-- start-up flags and live in infrastructure/fly/postgres.toml, not here.
--
-- Full runbook: infrastructure/monitoring/README.md § 4.

\set ON_ERROR_STOP on

-- psql does not interpolate `:variables` inside dollar-quoted strings, so the
-- password can never be handled inside a DO block — hence the \gset + \if dance
-- instead of the more obvious `DO $$ ... format(...) ... $$`.
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db-o11y') AS create_o11y_role \gset

\if :create_o11y_role
CREATE ROLE "db-o11y" LOGIN PASSWORD :'db_o11y_password';
\else
ALTER ROLE "db-o11y" LOGIN PASSWORD :'db_o11y_password';
\endif

-- pg_monitor is the umbrella role (it already contains pg_read_all_stats, but
-- Grafana's docs name both, so grant both and keep the intent obvious):
--   * pg_monitor        — pg_stat_activity without the query text being masked,
--                         pg_stat_*, and the pg_*_size() functions.
--   * pg_read_all_stats — the statistics views the query_details collector reads.
GRANT pg_monitor TO "db-o11y";
GRANT pg_read_all_stats TO "db-o11y";

-- schema_details and explain_plans need to read the actual tables. The docs offer
-- per-schema `GRANT USAGE` + `GRANT SELECT ON ALL TABLES`, but those only cover
-- tables that exist at grant time — every later migration would add a table the
-- collector silently can't see. pg_read_all_data (PG14+) is a standing read-only
-- grant across all present and future schemas and tables, so it can't drift.
GRANT pg_read_all_data TO "db-o11y";

-- CONNECT is granted to PUBLIC by default; being explicit means the setup still
-- works on a database where that default has been revoked.
DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), 'db-o11y');
END
$$;

-- Per-database: the extension's views only exist where it has been created.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Keep the collector's own polling out of the statistics it collects — otherwise
-- the top-queries panels fill up with db-o11y's own pg_stat_statements reads.
ALTER ROLE "db-o11y" SET pg_stat_statements.track = 'none';

-- Verification — every row should read `ok`.
\echo ''
\echo 'Verification:'
SELECT
  'pg_stat_statements extension' AS check,
  CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
       THEN 'ok' ELSE 'MISSING' END AS status
UNION ALL
SELECT 'shared_preload_libraries',
       CASE WHEN current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%'
            THEN 'ok' ELSE 'MISSING — restart Postgres with the flag' END
UNION ALL
SELECT 'compute_query_id',
       CASE WHEN current_setting('compute_query_id') = 'on'
            THEN 'ok' ELSE 'expected on, got ' || current_setting('compute_query_id') END
UNION ALL
SELECT 'pg_stat_statements.track',
       CASE WHEN current_setting('pg_stat_statements.track') = 'all'
            THEN 'ok' ELSE 'expected all, got ' || current_setting('pg_stat_statements.track') END
UNION ALL
-- current_setting() renders this one with its unit ("4kB" on PG18, a bare byte
-- count on older majors), so it can't be cast to int directly — pg_size_bytes
-- parses both forms.
SELECT 'track_activity_query_size',
       CASE WHEN pg_size_bytes(current_setting('track_activity_query_size')) >= 4096
            THEN 'ok' ELSE 'expected >= 4096, got ' || current_setting('track_activity_query_size') END
UNION ALL
SELECT 'db-o11y role memberships',
       CASE WHEN (SELECT count(*) FROM pg_auth_members m
                    JOIN pg_roles r ON r.oid = m.roleid
                    JOIN pg_roles g ON g.oid = m.member
                   WHERE g.rolname = 'db-o11y'
                     AND r.rolname IN ('pg_monitor', 'pg_read_all_stats', 'pg_read_all_data')) = 3
            THEN 'ok' ELSE 'MISSING one of pg_monitor/pg_read_all_stats/pg_read_all_data' END;

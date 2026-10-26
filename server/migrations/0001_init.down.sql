-- Drop in reverse FK dependency order

DROP INDEX IF EXISTS idx_run_levels_run_id;
DROP INDEX IF EXISTS idx_hits_run_id;
DROP INDEX IF EXISTS idx_hits_run_level_id;
DROP INDEX IF EXISTS idx_hit_metrics_run_level_id;
DROP INDEX IF EXISTS idx_runs_review_status;
DROP INDEX IF EXISTS idx_runs_client_uuid;
DROP INDEX IF EXISTS idx_runs_leaderboard_by_mode_and_bucket;

DROP TABLE IF EXISTS input_events;
DROP TABLE IF EXISTS hits;
DROP TABLE IF EXISTS hit_metrics;
DROP TABLE IF EXISTS run_levels;
DROP TABLE IF EXISTS runs;
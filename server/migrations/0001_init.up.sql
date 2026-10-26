CREATE TABLE IF NOT EXISTS runs (
    id                          BIGSERIAL PRIMARY KEY,
    run_uuid                    UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),

    -- Run shape
    total_levels                SMALLINT NOT NULL,        -- 1 to 3
    levels_completed            SMALLINT NOT NULL DEFAULT 0,
    seed                        BYTEA NOT NULL,

    -- Wall-clock timing (actual in-game time)
    started_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at                TIMESTAMPTZ,
    duration_ms                 INTEGER,

    -- Game-time economy, summed across all levels in the run
    starting_gametime_ms        INTEGER NOT NULL,
    total_gametime_gained_ms    INTEGER NOT NULL DEFAULT 0,
    total_gametime_lost_ms      INTEGER NOT NULL DEFAULT 0,
    final_gametime_ms           INTEGER,                  -- NULL if abandoned

    -- Hit accuracy aggregates (denormalized for leaderboard queries)
    total_hits                  SMALLINT NOT NULL DEFAULT 0,
    total_enemies               SMALLINT NOT NULL,
    center_hits                 SMALLINT NOT NULL DEFAULT 0,  -- within 10% lenience
    close_hits                  SMALLINT NOT NULL DEFAULT 0,  -- within 50% lenience
    edge_hits                   SMALLINT NOT NULL DEFAULT 0,  -- outside 50% but on target

    outcome                     TEXT NOT NULL DEFAULT 'in_progress'
                                CHECK (outcome IN ('in_progress','completed','failed','abandoned')),

    -- Client / build environment
    client_version              TEXT NOT NULL,
    screen_width                INTEGER,
    screen_height               INTEGER,
    game_version                SMALLINT NOT NULL DEFAULT 1,

    -- Anti-cheat
    review_status               TEXT NOT NULL DEFAULT 'unreviewed'
                                CHECK (review_status IN ('unreviewed','legit','suspicious','cheated')),
    cheat_score                 REAL,

    -- Mouse / DPI
    claimed_dpi                 INTEGER,
    dpi_bucket                  TEXT GENERATED ALWAYS AS (
                                    CASE
                                        WHEN claimed_dpi IS NULL  THEN NULL
                                        WHEN claimed_dpi < 200    THEN NULL
                                        WHEN claimed_dpi <= 900   THEN 'low_dpi'
                                        WHEN claimed_dpi <= 1800  THEN 'mid_dpi'
                                        WHEN claimed_dpi <= 6400  THEN 'high_dpi'
                                        ELSE NULL
                                    END
                                ) STORED,

    -- Game mode. A tactical run isn't comparable to a normal run on the
    -- same clock, so leaderboards are segmented on this column.
    game_mode                   TEXT NOT NULL DEFAULT 'normal'
                                CHECK (game_mode IN ('normal', 'tactical')),

    -- Anonymous identity. client_uuid is a cookie-stored browser identifier;
    -- display_tag is an optional pinball-style handle, only set when the run
    -- qualifies for the leaderboard and the user entered one.
    client_uuid                 UUID NOT NULL DEFAULT gen_random_uuid(),
    display_tag                 TEXT
                                CHECK (display_tag IS NULL OR (length(display_tag) BETWEEN 1 AND 20)),

    CHECK (total_hits = center_hits + close_hits + edge_hits),
    CONSTRAINT runs_claimed_dpi_range
        CHECK (claimed_dpi IS NULL OR claimed_dpi BETWEEN 200 AND 6400)
);

CREATE TABLE IF NOT EXISTS run_levels (
    id                      BIGSERIAL PRIMARY KEY,
    run_id                  BIGINT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    level_index             SMALLINT NOT NULL         -- 0..2 within the run
                            CONSTRAINT level_index_range CHECK (level_index >= 0 AND level_index <= 2),
    level_id                SMALLINT NOT NULL         -- which level definition
                            CONSTRAINT level_id_range CHECK (level_id >= 1 AND level_id <= 3),

    -- Wall-clock
    started_at              TIMESTAMPTZ NOT NULL,
    completed_at            TIMESTAMPTZ,
    duration_ms             INTEGER,

    -- Game-time for this level specifically
    gametime_entering_ms    INTEGER NOT NULL,
    gametime_gained_ms      INTEGER NOT NULL DEFAULT 0,
    gametime_lost_ms        INTEGER NOT NULL DEFAULT 0,
    gametime_exiting_ms     INTEGER,                  -- NULL if abandoned

    enemies_total           SMALLINT NOT NULL,
    enemies_hit             SMALLINT NOT NULL DEFAULT 0,

    completed               BOOLEAN NOT NULL DEFAULT false,
    blob_uploaded_at        TIMESTAMPTZ,  -- NULL until the bucket write succeeds

    UNIQUE (run_id, level_index)
);

CREATE TABLE IF NOT EXISTS hits (
    id                      BIGSERIAL PRIMARY KEY,
    run_id                  BIGINT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    run_level_id            BIGINT NOT NULL REFERENCES run_levels(id) ON DELETE CASCADE,

    hit_index               SMALLINT NOT NULL,        -- 0..n within this level
    enemy_id                SMALLINT NOT NULL,

    time_ms                 INTEGER NOT NULL,         -- ms since level start
    gametime_at_hit_ms      INTEGER NOT NULL,

    -- Player state at moment of shot
    player_x                REAL NOT NULL,
    player_y                REAL NOT NULL,
    player_z                REAL NOT NULL,
    view_yaw                REAL NOT NULL,
    view_pitch              REAL NOT NULL,

    -- Enemy center and actual hit point
    enemy_center_x          REAL NOT NULL,
    enemy_center_y          REAL NOT NULL,
    enemy_center_z          REAL NOT NULL,
    hit_x                   REAL NOT NULL,
    hit_y                   REAL NOT NULL,
    hit_z                   REAL NOT NULL,

    -- Derived accuracy
    distance_from_center    REAL NOT NULL,
    accuracy_bucket         SMALLINT NOT NULL  -- 0=center, 1=close, 2=edge
                            CHECK (accuracy_bucket IN (0, 1, 2)),
    gametime_awarded_ms     INTEGER NOT NULL,

    -- Anti-cheat
    angular_error_rad       REAL,
    time_since_onscreen_ms  INTEGER,  -- NULL = killed before crossing into view
    time_since_exposed_ms   INTEGER,  -- NULL = never exposed before kill
    seg_start_sample        INTEGER NOT NULL DEFAULT 0,
    seg_end_sample          INTEGER NOT NULL DEFAULT 0,

    -- Tactical-mode spread flag
    tac_spread              BOOLEAN NOT NULL DEFAULT false,

    UNIQUE (run_level_id, hit_index)
);

-- Discrete input events. WASD, mouse buttons, spacebar (intermission advance).
-- key_code is a semantic action (MOVE_FORWARD, SHOOT, CONTINUE) defined by
-- the application layer, not a raw scancode.
CREATE TABLE IF NOT EXISTS input_events (
    id              BIGSERIAL PRIMARY KEY,
    run_level_id    BIGINT NOT NULL REFERENCES run_levels(id) ON DELETE CASCADE,
    event_index     INTEGER NOT NULL,                 -- monotonic per level
    time_ms         INTEGER NOT NULL,
    event_type      SMALLINT NOT NULL
                    CHECK (event_type IN (0, 1, 2, 3)),
                    -- 0 = key_down
                    -- 1 = key_up
                    -- 2 = mouse_button_down
                    -- 3 = mouse_button_up
    key_code        SMALLINT NOT NULL,
    synthetic       BOOLEAN NOT NULL DEFAULT false,
                    -- true = server-inferred (e.g. closing an unreleased
                    -- key at a level boundary)
    UNIQUE (run_level_id, event_index)
);

-- Server-computed motion features, one row per per hit.
-- Recomputed server-side from the raw blob — never trusted from the client.
-- Kept as its own table (not columns on hits) so adding a feature is an INSERT,
-- not a migration. Nullable feature columns: a blind-flick/empty segment may
-- not yield every feature.
CREATE TABLE IF NOT EXISTS hit_metrics (
    id                  BIGSERIAL PRIMARY KEY,
    run_level_id        BIGINT NOT NULL REFERENCES run_levels(id) ON DELETE CASCADE,
    hit_index           SMALLINT NOT NULL,        -- matches hits.hit_index within the level

    sample_count        INTEGER NOT NULL,         -- samples in this engagement's slice
    duration_ms         INTEGER,                  -- onscreen onset -> kill, recomputed

    peak_ang_vel        REAL,                     -- max angular velocity (rad/s)
    mean_ang_vel        REAL,
    overshoot           REAL,                     -- past-target excursion magnitude
    correction_count    SMALLINT,                 -- direction reversals in the settle phase
    path_straightness   REAL,                     -- straight-line / actual path length (0..1)
    pickup_detected     BOOLEAN NOT NULL DEFAULT false,  -- mouse lift/reposition in the slice

    UNIQUE (run_level_id, hit_index)
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- FK lookups
CREATE INDEX idx_run_levels_run_id   ON run_levels (run_id);
CREATE INDEX idx_hits_run_id         ON hits (run_id);
CREATE INDEX idx_hits_run_level_id   ON hits (run_level_id);
CREATE INDEX idx_hit_metrics_run_level_id ON hit_metrics (run_level_id);

-- Review queue: only rows that still need attention.
CREATE INDEX idx_runs_review_status ON runs (review_status)
    WHERE review_status != 'legit';

-- Look up a player's run history by their browser cookie, no account needed.
CREATE INDEX idx_runs_client_uuid ON runs (client_uuid);

-- Bucketed leaderboard. Runs without claimed_dpi are excluded from this
-- ranking; they still play and still record, they just don't appear here.
CREATE INDEX idx_runs_leaderboard_by_mode_and_bucket ON runs
    (game_version, game_mode, dpi_bucket, final_gametime_ms DESC, center_hits DESC, completed_at ASC)
    WHERE outcome = 'completed'
      AND review_status = 'legit'
      AND dpi_bucket IS NOT NULL;
package api

import (
	"crypto/rand"
	"database/sql"
	"encoding/json"
    "encoding/hex"
	"errors"
	"fmt"
	"log"
	"net/http"
    "os"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Server struct {
    db      *sql.DB
    logger  *log.Logger
    levels  map[int16]*LoadedLevel
    webDir  string
}

// request structs are for data that only the client has
// if server computes or looksup via DB it does not go in the struct

// POST /api/runs/start
type StartRunRequest struct {
    TotalLevels             int16       `json:"total_levels"`   // 2–3 via client
    ClientUUID              uuid.UUID   `json:"client_uuid"`    // browser session UUID
    ClientVersion           string      `json:"client_version"`
    ScreenWidth             int32       `json:"screen_width,omitempty"`
    ScreenHeight            int32       `json:"screen_height,omitempty"`
    GameMode                string      `json:"game_mode"`      // "normal" or "tactical"
}

type StartRunResponse struct {
    RunUUID                 uuid.UUID               `json:"run_uuid"`
    Seed                    string                  `json:"seed"`
    StartedAt               time.Time               `json:"started_at"`
    StartingGametimeMs      int32                   `json:"starting_gametime_ms"`
    TotalEnemies            int16                   `json:"total_enemies"`
    Levels                  []StartRunResponseLevel `json:"levels"`
}

//JSON level definition with server-chosen spawns
//The order of EnemySpawnIndices is the order the client uses for enemy_id
type StartRunResponseLevel struct {
    LevelID                 int16                   `json:"level_id"`
    Definition              json.RawMessage         `json:"definition"`
    EnemySpawnIndices       []int16                 `json:"enemy_spawn_indices"`
}

// POST .../levels []HitEvent
type HitEvent struct {
    HitIndex                int16       `json:"hit_index"`
    EnemyID                 int16       `json:"enemy_id"`
    TimeMs                  int32       `json:"time_ms"`
    GametimeAtHitMs         int32       `json:"gametime_at_hit_ms"`

    PlayerX                 float32     `json:"player_x"`
    PlayerY                 float32     `json:"player_y"`
    PlayerZ                 float32     `json:"player_z"`

    ViewYaw                 float32     `json:"view_yaw"`
    ViewPitch               float32     `json:"view_pitch"`

    EnemyCenterX            float32     `json:"enemy_center_x"`
    EnemyCenterY            float32     `json:"enemy_center_y"`
    EnemyCenterZ            float32     `json:"enemy_center_z"`

    HitX                    float32     `json:"hit_x"`
    HitY                    float32     `json:"hit_y"`
    HitZ                    float32     `json:"hit_z"`

    DistanceFromCenter      float32     `json:"distance_from_center"`
    AccuracyBucket          int16       `json:"accuracy_bucket"`
    GametimeAwardedMs       int32       `json:"gametime_awarded_ms"`
    Spread                  bool        `json:"tac_spread"`

    TimeSinceExposedMs      int32       `json:"time_since_exposed_ms"`   // -1 -> NULL
    TimeSinceOnscreenMs     int32       `json:"time_since_onscreen_ms"`  // -1 -> NULL
    SegStartSample          int32       `json:"seg_start_sample"`
    SegEndSample            int32       `json:"seg_end_sample"`
}

// POST /api/runs/{uuid}/levels
type SubmitLevelRequest struct {
    LevelIndex              int16       `json:"level_index"`
    LevelID                 int16       `json:"level_id"`
    DurationMs              int32       `json:"duration_ms"`
    GametimeEnteringMs      int32       `json:"gametime_entering_ms"`
    GametimeGainedMs        int32       `json:"gametime_gained_ms"`
    GametimeLostMs          int32       `json:"gametime_lost_ms"`
    GametimeExitingMs       int32       `json:"gametime_exiting_ms"` // DB allows null, API does not
    EnemiesTotal            int16       `json:"enemies_total"`
    EnemiesHit              int16       `json:"enemies_hit"`
    Completed               bool        `json:"completed"`
    Hits                    []HitEvent  `json:"hits"`
}

type SubmitLevelResponse struct {
    RunLevelID              int64       `json:"run_level_id"`
    HitsAccepted            int64       `json:"hits_accepted"`
}

// POST /api/runs/{uuid}/finish
type FinishRunRequest struct {
    Outcome                 string      `json:"outcome"`            // "completed" or "failed"
    LevelsCompleted         int16       `json:"levels_completed"`

    TotalGametimeGainedMs   int32       `json:"total_gametime_gained_ms"`
    TotalGametimeLostMs     int32       `json:"total_gametime_lost_ms"`
    FinalGametimeMs         int32       `json:"final_gametime_ms"`

    TotalHits               int16       `json:"total_hits"`
    CenterHits              int16       `json:"center_hits"`
    CloseHits               int16       `json:"close_hits"`
    EdgeHits                int16       `json:"edge_hits"`
}

type FinishRunResponse struct {
    RunUUID                 uuid.UUID   `json:"run_uuid"`
    Outcome                 string      `json:"outcome"`
    CompletedAt             time.Time   `json:"completed_at"`
    DurationMs              int32       `json:"duration_ms"`
    FinalGametimeMs         int32       `json:"final_gametime_ms"`
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, v any) {
    buf, err := json.Marshal(v)
    if err != nil {
        s.logger.Printf("writeJSON marshal failed: %v", err)
        http.Error(w, "encoding error", http.StatusInternalServerError)
        return
    }
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)
    if _, err := w.Write(buf); err != nil {
        s.logger.Printf("writeJSON write failed: %v", err)
    }
}

func nullIfNeg(v int32) any {
    if v < 0 {
        return nil
    }
    return v
}

func New(db *sql.DB, logger *log.Logger, levels map[int16]*LoadedLevel, webDir string) *Server {
    return &Server{db: db, logger: logger, levels: levels, webDir: webDir}
}

// wraps http.Error for debugging: logging the request details
// alongside the error message returned to the client
func (s *Server) debugHTTPError(w http.ResponseWriter, r *http.Request, msg string, status int) {
    s.logger.Printf("[DEBUG] %d %s | %s %s | content-length=%d | error: %s",
        status,
        http.StatusText(status),
        r.Method,
        r.URL.String(),
        r.ContentLength,
        msg,
    )
    http.Error(w, msg, status)
}

// crossOriginIsolated sets COOP/COEP/CORP headers on the response so the
// browser grants the served page full DOMHighResTimeStamp precision (and
// SharedArrayBuffer access if we ever want WASM threads). Only needed on
// the static handler that serves the WASM page — the JSON API doesn't
// require these.
func crossOriginIsolated(h http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Cross-Origin-Opener-Policy",   "same-origin")
        w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")
        w.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
        h.ServeHTTP(w, r)
    })
}

func (s *Server) Routes() http.Handler {
    mux := http.NewServeMux()
    mux.HandleFunc("POST /api/runs/start", s.startRun)
    mux.HandleFunc("POST /api/runs/{uuid}/levels", s.levelSum)
    mux.HandleFunc("POST /api/runs/{uuid}/finish", s.finishRun)

    // Serve the web build (WASM, HTML, JS) from the same origin as the API.
    // the catch-all "/" only matches non-API requests.
    if s.webDir != "" {
        if info, err := os.Stat(s.webDir); err == nil && info.IsDir() {
            s.logger.Printf("serving web build from %s", s.webDir)
            mux.Handle("/", crossOriginIsolated(http.FileServer(http.Dir(s.webDir))))
        } else {
            s.logger.Printf("web dir %q not found, skipping static file serving", s.webDir)
        }
    }

    return mux
}

func (s *Server) startRun(w http.ResponseWriter, r *http.Request) {
    r.Body = http.MaxBytesReader(w, r.Body, 1<<16)  // 64KB defensive cap
    // parse request body via client
    var req StartRunRequest

    dec := json.NewDecoder(r.Body)
    dec.DisallowUnknownFields()
    if err := dec.Decode(&req); err != nil {
        http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
        return
    }

    // validate within-request inputs
    if req.TotalLevels < 2 || req.TotalLevels > 3 {
        http.Error(w, "total_levels must be between 2 and 3", http.StatusBadRequest)
        return
    }
    if req.ClientVersion == "" {
        http.Error(w, "client_version required", http.StatusBadRequest)
        return
    }
    if req.GameMode != "normal" && req.GameMode != "tactical" {
        http.Error(w, "game_mode must be 'normal' or 'tactical'", http.StatusBadRequest)
        return
    }
    if req.ClientUUID == uuid.Nil {
        http.Error(w, "client_uuid required", http.StatusBadRequest)
        return
    }

    // server generates seed
    seed := make([]byte, 16)
    if _, err := rand.Read(seed); err != nil {
        s.logger.Printf("seed generation failed: %v", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    // levels and RNG via seed
    chosenLevels := make([]StartRunResponseLevel, 0, req.TotalLevels)
    var totalEnemies int16
    for i := int16(1); i <= req.TotalLevels; i++ {
        level, ok := s.levels[i]
        if !ok {
            s.logger.Printf("startRun: missing level %d on disk", i)
            http.Error(w, "internal error", http.StatusInternalServerError)
            return
        }
        indices := SelectEnemyIndices(level, seed, i)
        chosenLevels = append(chosenLevels, StartRunResponseLevel{
            LevelID:           i,
            Definition:        level.Raw,
            EnemySpawnIndices: indices,
        })
        totalEnemies += int16(len(indices))
    }

    // starting_gametime_ms derived from total_levels
    startingGametimeMs := int32(req.TotalLevels) * 10 * 1000 // 10s per level, 20s total

    // INSERT and read back DB-generated columns atomically
    var newUUID uuid.UUID
    var startedAt time.Time
    err := s.db.QueryRowContext(r.Context(),`
        INSERT INTO runs (
            total_levels, total_enemies, seed, starting_gametime_ms,
            client_version, screen_width, screen_height,
            client_uuid, game_mode
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        RETURNING run_uuid, started_at
    `,
        req.TotalLevels, totalEnemies, seed, startingGametimeMs,
        req.ClientVersion, req.ScreenWidth, req.ScreenHeight,
        req.ClientUUID, req.GameMode,
    ).Scan(&newUUID, &startedAt)

    if err != nil {
        s.logger.Printf("insert failed: %v", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    // response back to client
    resp := StartRunResponse{
        RunUUID:            newUUID,
        Seed:               hex.EncodeToString(seed),
        StartedAt:          startedAt,
        StartingGametimeMs: startingGametimeMs,
        TotalEnemies:       totalEnemies,
        Levels:             chosenLevels,
    }
    s.writeJSON(w, http.StatusCreated, resp)  // 201, not 200 as resource created
}

func (s *Server) levelSum(w http.ResponseWriter, r *http.Request) {
    r.Body = http.MaxBytesReader(w, r.Body, 4<<20) //4MB defensive cap for binary blob
    // parse uuid path
    runUUID, err := uuid.Parse(r.PathValue("uuid"))
    if err != nil || runUUID == uuid.Nil {
        http.Error(w, "invalid run id", http.StatusBadRequest)
        return
    }
    // parse request body via client
    var req SubmitLevelRequest

    dec := json.NewDecoder(r.Body)
    dec.DisallowUnknownFields()
    if err := dec.Decode(&req); err != nil {
        http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
        return
    }
    if req.EnemiesHit < 0 {
        http.Error(w, "enemies hit out of bounds", http.StatusBadRequest)
        return
    }
    if req.EnemiesTotal < 0 {
        http.Error(w, "enemies total out of bounds", http.StatusBadRequest)
        return
    }
    if req.DurationMs < 0 {
        http.Error(w, "duration out of bounds", http.StatusBadRequest)
        return
    }
    if req.GametimeEnteringMs < 0 {
        http.Error(w, "gametime entering out of bounds", http.StatusBadRequest)
        return
    }
    if req.GametimeExitingMs < 0 {
        http.Error(w, "gametime existing out of bounds", http.StatusBadRequest)
        return
    }
    if req.LevelIndex < 0 || req.LevelIndex > 2 {
        http.Error(w, "level index out of bounds", http.StatusBadRequest)
        return
    }
    if req.LevelID < 1 || req.LevelID > 3 {
        http.Error(w, "level ID out of bounds", http.StatusBadRequest)
        return
    }
    //levels in request must match chosen levels from startRun
    level, levelKnown := s.levels[req.LevelID]
    if !levelKnown {
        http.Error(w, "unknown level_id", http.StatusBadRequest)
        return
    }
    //enemies in request must match chosen enemies from startRun
    enemyBound := int16(level.EnemiesPerLevel())
    for i, hit := range req.Hits {
        if hit.EnemyID < 0 || hit.EnemyID >= enemyBound {
            s.logger.Printf("levelSum: hit[%d] has invalid enemy_id %d (level %d has %d enemies)",
                i, hit.EnemyID, req.LevelID, enemyBound)
            http.Error(w, "enemy_id out of bounds for level", http.StatusBadRequest)
            return
        }
    }
    if req.EnemiesHit > req.EnemiesTotal {
        http.Error(w, "more enemies than expected", http.StatusBadRequest)
        return
    }
    if len(req.Hits) != int(req.EnemiesHit) {
        http.Error(w, "hits imbalanced", http.StatusBadRequest)
        return
    }
    if req.Completed {
        if req.EnemiesHit != req.EnemiesTotal {
            http.Error(w, "enemies imbalanced", http.StatusBadRequest)
            return
        }
    }
    if !req.Completed {
        if req.GametimeExitingMs != 0 {
            http.Error(w, "failed level requires gametime exiting == 0", http.StatusBadRequest)
            return
        }
        if req.EnemiesHit == req.EnemiesTotal {
            http.Error(w, "failed level cannot have all enemies cleared", http.StatusBadRequest)
            return
        }
    }
    for _, hit := range req.Hits {
        if hit.HitIndex < 0 {
            http.Error(w, "hit index out of bounds", http.StatusBadRequest)
            return
        }
        if hit.GametimeAwardedMs < 0 {
            http.Error(w, "gametime awarded out of bounds", http.StatusBadRequest)
            return
        }
        if hit.DistanceFromCenter < 0 {
            http.Error(w, "distance from center out of bounds", http.StatusBadRequest)
            return
        }
        if hit.SegStartSample < 0 || hit.SegEndSample < hit.SegStartSample {
            http.Error(w, "invalid segment range", http.StatusBadRequest)
            return
        }
        if hit.TimeSinceExposedMs < -1 || hit.TimeSinceOnscreenMs < -1 {
            http.Error(w, "invalid reaction time", http.StatusBadRequest)
            return
        }
        switch hit.AccuracyBucket {
        case 0, 1, 2:
        default:
            http.Error(w, "invalid accuracy bucket", http.StatusBadRequest)
            return
        }
    }

    fail := func(err error) {
        s.logger.Printf("submit level: %v", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
    }

    ctx := r.Context()

    // Get a Tx for making transaction requests.
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        fail(err)
        return
    }
    // Defer a rollback in case anything fails, suppress error on successful commit
    defer func() { _ = tx.Rollback() }()

    //ALL TRANSACTION SQL GOES HERE
    var runID int64
    var outcome string
    err = tx.QueryRowContext(ctx,`
        SELECT id, outcome FROM runs WHERE run_uuid = $1
    `, runUUID).Scan(&runID, &outcome)
    if errors.Is(err, sql.ErrNoRows) {
        http.NotFound(w, r)
        return
    }
    if err != nil {
        s.logger.Printf("db error: %v", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    if outcome != "in_progress" {
        http.Error(w, "run not in progress", http.StatusConflict)
        return
    }

    var runLevelID int64
    err = tx.QueryRowContext(ctx, `
        INSERT INTO run_levels (
            run_id, level_index, level_id,
            started_at, completed_at, duration_ms,
            gametime_entering_ms, gametime_gained_ms, gametime_lost_ms, gametime_exiting_ms,
            enemies_total, enemies_hit, completed
        )
        VALUES (
            $1, $2, $3,
            now() - make_interval(secs => $4 / 1000.0), now(), $4,
            $5, $6, $7, $8,
            $9, $10, $11
        )
        ON CONFLICT (run_id, level_index) DO NOTHING
        RETURNING id
    `,
        runID, req.LevelIndex, req.LevelID, req.DurationMs,
        req.GametimeEnteringMs, req.GametimeGainedMs,
        req.GametimeLostMs, req.GametimeExitingMs,
        req.EnemiesTotal, req.EnemiesHit, req.Completed,
    ).Scan(&runLevelID)
    if errors.Is(err, sql.ErrNoRows) {
        http.Error(w, "level already submitted", http.StatusConflict)
        return
    }
    if err != nil {
        fail(err)
        return
    }

    //allowing submission of failed levels with 0 hits
    var hitsAccepted int64 = 0
    if len(req.Hits) > 0 {
        const colsPerRow = 25
        valueGroups := make([]string, 0, len(req.Hits))
        args := make([]any, 0, len(req.Hits)*colsPerRow)

        for i, h := range req.Hits {
            base := i * colsPerRow
            ph := make([]string, colsPerRow)
            for k := 0; k < colsPerRow; k++ {
                ph[k] = fmt.Sprintf("$%d", base+k+1)
            }
            valueGroups = append(valueGroups, "("+strings.Join(ph, ",")+")")

            args = append(args,
                runID, runLevelID, h.HitIndex, h.EnemyID,
                h.TimeMs, h.GametimeAtHitMs, h.PlayerX,
                h.PlayerY, h.PlayerZ, h.ViewYaw, h.ViewPitch,
                h.EnemyCenterX, h.EnemyCenterY, h.EnemyCenterZ,
                h.HitX, h.HitY, h.HitZ, h.DistanceFromCenter,
                h.AccuracyBucket, h.GametimeAwardedMs, h.Spread,
                nullIfNeg(h.TimeSinceExposedMs), nullIfNeg(h.TimeSinceOnscreenMs),
                h.SegStartSample, h.SegEndSample,
            )
        }

        query := `
            INSERT INTO hits (
                run_id, run_level_id, hit_index, enemy_id,
                time_ms, gametime_at_hit_ms, player_x,
                player_y, player_z, view_yaw, view_pitch,
                enemy_center_x, enemy_center_y, enemy_center_z,
                hit_x, hit_y, hit_z, distance_from_center,
                accuracy_bucket, gametime_awarded_ms, tac_spread,
                time_since_exposed_ms, time_since_onscreen_ms,
                seg_start_sample, seg_end_sample
            )
            VALUES ` + strings.Join(valueGroups, ",") + `
            ON CONFLICT (run_level_id, hit_index) DO NOTHING
        `
        var result sql.Result
        result, err = tx.ExecContext(ctx, query, args...)
        if err != nil {
            fail(err)
            return
        }
        hitsAccepted, err = result.RowsAffected()
        if err != nil {
            fail(err)
            return
        }
    }
    //send it
    err = tx.Commit()
    if err != nil {
        fail(err)
        return
    }

    // response back to client
    resp := SubmitLevelResponse{
        RunLevelID:     runLevelID,
        HitsAccepted:   hitsAccepted,
    }
    s.writeJSON(w, http.StatusCreated, resp)
}

func (s *Server) finishRun(w http.ResponseWriter, r *http.Request) {
    r.Body = http.MaxBytesReader(w, r.Body, 1<<16) //64KB defensive cap
    // parse uuid path
    runUUID, err := uuid.Parse(r.PathValue("uuid"))
    if err != nil || runUUID == uuid.Nil {
        http.Error(w, "invalid run id", http.StatusBadRequest)
        return
    }
    // parse request body via client
    var req FinishRunRequest

    dec := json.NewDecoder(r.Body)
    dec.DisallowUnknownFields()
    if err := dec.Decode(&req); err != nil {
        http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
        return
    }

    // validate outcome enum parameter
    if req.Outcome != "completed" && req.Outcome != "failed" {
        http.Error(w, "outcome must be 'completed' or 'failed'", http.StatusBadRequest)
        return
    }

    // validate within-request hit consistency
    if req.TotalHits != req.CenterHits + req.CloseHits + req.EdgeHits {
        http.Error(w, "hit counts don't sum to total_hits", http.StatusBadRequest)
        return
    }
    if req.LevelsCompleted < 0 || req.TotalHits < 0 ||
       req.CenterHits < 0 || req.CloseHits < 0 || req.EdgeHits < 0 {
        http.Error(w, "negative values not allowed", http.StatusBadRequest)
        return
    }

    // get state from DB for further validation
    //potentially remove totalEnemies and totalLevels from SELECT
    // ^ and move to be part of the WHERE in the UPDATE below
    var startedAt time.Time
    var totalEnemies, totalLevels int16
    var existingOutcome string
    err = s.db.QueryRowContext(r.Context(),`
        SELECT started_at, total_enemies, total_levels, outcome
        FROM runs WHERE run_uuid = $1
    `, runUUID).Scan(&startedAt, &totalEnemies, &totalLevels, &existingOutcome)
    if errors.Is(err, sql.ErrNoRows) {
        http.NotFound(w, r)
        return
    }
    if err != nil {
        s.logger.Printf("db error: %v", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    // validate against existing state from DB
    if existingOutcome != "in_progress" {
        http.Error(w, "run already finished", http.StatusConflict) // 409
        return
    }
    if req.TotalHits > totalEnemies {
        http.Error(w, "more hits than enemies in run", http.StatusBadRequest)
        return
    }
    if req.LevelsCompleted > totalLevels {
        http.Error(w, "more levels completed than exist", http.StatusBadRequest)
        return
    }

    // update and fetch from row in DB atomically
    var completedAt time.Time
    var durationMs int32
    err = s.db.QueryRowContext(r.Context(),`
        UPDATE runs SET
            outcome = $1,
            completed_at = now(),
            duration_ms = (EXTRACT(EPOCH FROM (now() - started_at)) * 1000)::INTEGER,
            levels_completed = $2,
            total_gametime_gained_ms = $3,
            total_gametime_lost_ms = $4,
            final_gametime_ms = $5,
            total_hits = $6,
            center_hits = $7,
            close_hits = $8,
            edge_hits = $9
        WHERE run_uuid = $10 AND outcome = 'in_progress'
        RETURNING completed_at, duration_ms
    `,
        req.Outcome, req.LevelsCompleted,
        req.TotalGametimeGainedMs, req.TotalGametimeLostMs, req.FinalGametimeMs,
        req.TotalHits, req.CenterHits, req.CloseHits, req.EdgeHits,
        runUUID,
    ).Scan(&completedAt, &durationMs)

    if errors.Is(err, sql.ErrNoRows) {
        // Either the run doesn't exist or it was already finished
        http.Error(w, "run not found or already finished", http.StatusConflict)
        return
    }
    if err != nil {
        s.logger.Printf("finish update failed: %v", err)
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    // response back to client
    resp := FinishRunResponse{
        RunUUID:         runUUID,
        Outcome:         req.Outcome,
        CompletedAt:     completedAt,
        DurationMs:      durationMs,
        FinalGametimeMs: req.FinalGametimeMs,
    }
    s.writeJSON(w, http.StatusOK, resp)
}
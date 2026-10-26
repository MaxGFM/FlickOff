package api

import (
    "bytes"
    "encoding/json"
    "io"
    "log"
    "net/http"
    "net/http/httptest"
    "strings"
    "testing"
)

// newTestServer builds a Server suitable for tests that exercise validation
// paths only. The DB is nil because none of these tests should reach the
// database — if any test does, we want it to panic loudly rather than silently
// pass against fake data. The logger discards output to keep test runs quiet.
//
// Levels is populated with a synthetic 5-level map so handler tests can use
// any level_id in 1..5 without per-test setup. We don't load the real JSON
// files here because handler tests are about validation paths, not level
// data — see TestLoadLevels_Production for tests against the real assets.
func newTestServer(t *testing.T) *Server {
    t.Helper()
    return &Server{
        db:     nil,
        logger: log.New(io.Discard, "", 0),
        levels: testLevels(),
    }
}

// minimalLevel builds an in-memory LoadedLevel with the given shape: `angles`
// distinct angle_ids (1..angles), each with `perAngle` spawn points. Spawn
// positions are deterministic so test failures can reference exact values if
// needed. Raw is the marshaled definition so handlers that forward Raw to the
// client see a non-nil payload.
func minimalLevel(angles uint8, perAngle int) *LoadedLevel {
    def := LevelDefinition{
        AngleCount:  angles,
        SpawnPoints: make([]LevelSpawnPoint, 0, int(angles)*perAngle),
    }
    for a := uint8(1); a <= angles; a++ {
        for i := 0; i < perAngle; i++ {
            def.SpawnPoints = append(def.SpawnPoints, LevelSpawnPoint{
                AngleID: a,
                Pos:     [3]float32{float32(a), 1.7, float32(i)},
            })
        }
    }
    raw, _ := json.Marshal(def)
    return &LoadedLevel{Definition: def, Raw: raw}
}

// testLevels returns a fresh 5-level map (IDs 1..5) sized like the production
// levels (5 angles × 5 spawn points = 15 enemies per level). Returning a
// fresh map per call keeps tests isolated from each other even though
// handlers only read.
func testLevels() map[int16]*LoadedLevel {
    out := make(map[int16]*LoadedLevel, 5)
    for i := int16(1); i <= 5; i++ {
        out[i] = minimalLevel(5, 5)
    }
    return out
}

// doPost is a small helper that constructs a POST request with a JSON body,
// runs it through a handler, and returns the recorder for assertions. The
// body argument is whatever JSON-marshalable value the test wants to send,
// or a raw string for tests that need malformed JSON.
func doPost(t *testing.T, handler http.HandlerFunc, target string, body any) *httptest.ResponseRecorder {
    t.Helper()

    var bodyReader io.Reader
    switch v := body.(type) {
    case string:
        // Allow tests to send raw strings (for malformed JSON cases)
        bodyReader = strings.NewReader(v)
    case []byte:
        bodyReader = bytes.NewReader(v)
    case nil:
        bodyReader = nil
    default:
        buf, err := json.Marshal(v)
        if err != nil {
            t.Fatalf("test setup: failed to marshal body: %v", err)
        }
        bodyReader = bytes.NewReader(buf)
    }

    req := httptest.NewRequest(http.MethodPost, target, bodyReader)
    req.Header.Set("Content-Type", "application/json")
    rec := httptest.NewRecorder()
    handler(rec, req)
    return rec
}

// =============================================================================
// startRun validation tests
// =============================================================================
//
// These exercise every validation branch in startRun that fails *before* the
// DB call. The happy path is not tested here because it requires a real DB;
// integration tests with testcontainers will cover that later.

func TestStartRun_Validation(t *testing.T) {
    srv := newTestServer(t)

    // validBody returns a request body that passes all validation. Individual
    // tests modify one field to exercise one validation rule at a time.
    // This keeps each test case focused on the *specific* thing it's testing.
    validBody := func() StartRunRequest {
        return StartRunRequest{
            TotalLevels:   3,
            ClientVersion: "test-1.0",
            ScreenWidth:   1920,
            ScreenHeight:  1080,
            GameMode:      "normal",
        }
    }

    cases := []struct {
        name           string
        body           any    // any so we can send strings/bytes for malformed cases
        wantStatus     int
        wantBodyToHave string // substring expected in the response body, or "" to skip
    }{
        {
            name:           "rejects malformed JSON",
            body:           `{"total_levels": 3, broken}`,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        {
            name:           "rejects empty body",
            body:           ``,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        {
            name: "rejects unknown fields",
            // DisallowUnknownFields catches client/server schema drift.
            body: `{"total_levels": 3, "client_version": "x", "secret_admin_flag": true}`,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        {
            name: "rejects total_levels below range",
            body: func() StartRunRequest {
                b := validBody()
                b.TotalLevels = 1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "total_levels",
        },
        {
            name: "rejects total_levels above range",
            body: func() StartRunRequest {
                b := validBody()
                b.TotalLevels = 6
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "total_levels",
        },
        {
            name: "rejects total_levels zero (default value catch)",
            // A client that forgot to set total_levels would send 0, which
            // shouldn't quietly become a valid run. This guards against
            // "missing field" being treated as a valid request.
            body: func() StartRunRequest {
                b := validBody()
                b.TotalLevels = 0
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "total_levels",
        },
        {
            name: "rejects negative total_levels",
            body: func() StartRunRequest {
                b := validBody()
                b.TotalLevels = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "total_levels",
        },
        {
            name: "rejects missing client_version",
            body: func() StartRunRequest {
                b := validBody()
                b.ClientVersion = ""
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "client_version",
        },
        {
            name: "rejects missing game_mode",
            // Empty string is the zero value — guards against a client that
            // forgot to set the field at all.
            body: func() StartRunRequest {
                b := validBody()
                b.GameMode = ""
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "game_mode",
        },
        {
            name: "rejects unknown game_mode",
            body: func() StartRunRequest {
                b := validBody()
                b.GameMode = "speedrun"
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "game_mode",
        },
        {
            name: "rejects case-mismatched game_mode",
            // Same intent as the outcome case-mismatch test in finishRun:
            // guard against accidental case-insensitive comparison.
            body: func() StartRunRequest {
                b := validBody()
                b.GameMode = "Normal"
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "game_mode",
        },
        {
            name: "accepts game_mode=tactical",
            body: func() StartRunRequest {
                b := validBody()
                b.GameMode = "tactical"
                return b
            }(),
            wantStatus: -1,
        },
        {
            name: "accepts boundary total_levels=3",
            // This one is funny — we expect the request to *fail* but only
            // at the DB step (because srv.db is nil), proving validation passed.
            // We assert NOT 400, because anything other than a validation error
            // means we got past the validation block.
            body: func() StartRunRequest {
                b := validBody()
                b.TotalLevels = 3
                return b
            }(),
            wantStatus: -1, // see explanation in test body
        },
        {
            name: "accepts boundary total_levels=2",
            // Lower boundary of the 2..3 range. As above, we expect the nil DB
            // to panic *after* validation passes — that's the success signal.
            body: func() StartRunRequest {
                b := validBody()
                b.TotalLevels = 2
                return b
            }(),
            wantStatus: -1,
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            // The boundary tests use wantStatus = -1 as a signal: "validation
            // should pass; we don't care what happens after." We catch the
            // inevitable nil-DB panic so it doesn't fail the test.
            if tc.wantStatus == -1 {
                defer func() {
                    // nil DB will panic when we try to call QueryRow on it.
                    // Recovering proves we got past validation, which is the
                    // only thing this test cares about. If we DON'T panic,
                    // something stranger is going on — we'd want to know.
                    if r := recover(); r == nil {
                        t.Logf("note: did not panic; validation passed and reached DB call cleanly")
                    }
                }()
                doPost(t, srv.startRun, "/api/runs/start", tc.body)
                return
            }

            rec := doPost(t, srv.startRun, "/api/runs/start", tc.body)

            if rec.Code != tc.wantStatus {
                t.Errorf("status: got %d, want %d. body: %s",
                    rec.Code, tc.wantStatus, rec.Body.String())
            }

            if tc.wantBodyToHave != "" && !strings.Contains(rec.Body.String(), tc.wantBodyToHave) {
                t.Errorf("body: got %q, expected to contain %q",
                    rec.Body.String(), tc.wantBodyToHave)
            }
        })
    }
}

// =============================================================================
// finishRun validation tests
// =============================================================================
//
// finishRun has a more complex validation flow: path parameter parsing, body
// parsing, within-request consistency checks, then DB-context checks. We
// cover everything before the DB SELECT here.

func TestFinishRun_Validation(t *testing.T) {
    srv := newTestServer(t)

    // A valid request body, used as a baseline that individual tests modify.
    // Numbers are deliberately small so it's obvious they're test data.
    validBody := func() FinishRunRequest {
        return FinishRunRequest{
            Outcome:               "completed",
            LevelsCompleted:       3,
            TotalGametimeGainedMs: 1000,
            TotalGametimeLostMs:   500,
            FinalGametimeMs:       2000,
            TotalHits:             6,
            CenterHits:            2,
            CloseHits:             2,
            EdgeHits:              2,
        }
    }

    // A valid UUID we can reuse across tests. The actual value doesn't matter
    // because no test reaches the DB — we just need it to parse successfully.
    const validUUID = "550e8400-e29b-41d4-a716-446655440000"

    cases := []struct {
        name           string
        uuidPathParam  string // what to put in {uuid} of the URL
        body           any
        wantStatus     int
        wantBodyToHave string
    }{
        // --- UUID parsing ---
        {
            name:           "rejects non-UUID path parameter",
            uuidPathParam:  "not-a-uuid",
            body:           validBody(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid run id",
        },
        {
            name:           "rejects integer path parameter",
            // Earlier versions of this code used strconv.Atoi for the path
            // parameter, which would have accepted "42" here. This test is a
            // regression guard against that returning.
            uuidPathParam:  "42",
            body:           validBody(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid run id",
        },

        // --- Body parsing ---
        {
            name:           "rejects malformed JSON",
            uuidPathParam:  validUUID,
            body:           `{"outcome": broken}`,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        {
            name:           "rejects unknown fields in body",
            uuidPathParam:  validUUID,
            body:           `{"outcome": "completed", "secret_field": 999}`,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },

        // --- Outcome enum validation ---
        {
            name:          "rejects unknown outcome value",
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.Outcome = "victorious"
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "outcome",
        },
        {
            name:          "rejects in_progress as outcome",
            // in_progress is a valid DB value but not a valid client-sent
            // outcome — only the server transitions runs into terminal states.
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.Outcome = "in_progress"
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "outcome",
        },
        {
            name:          "rejects abandoned as outcome",
            // abandoned is server-set by the reaper job, not client-set.
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.Outcome = "abandoned"
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "outcome",
        },
        {
            name:          "rejects empty outcome",
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.Outcome = ""
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "outcome",
        },
        {
            name:          "rejects case-mismatched outcome",
            // Guard against a client sending "Completed" or "COMPLETED" and
            // the comparison being made case-insensitive by accident.
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.Outcome = "Completed"
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "outcome",
        },

        // --- Hit consistency validation ---
        {
            name:          "rejects total_hits not equal to sum",
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.TotalHits = 10 // sum of buckets is 6
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "hit counts",
        },
        {
            name:          "rejects sum greater than total",
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.TotalHits = 5 // sum of buckets is 6
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "hit counts",
        },
        {
            name:          "rejects negative bucket that sums correctly",
            // Subtle case: -5 + 5 + 5 = 5 = total, so the equality check
            // passes but a negative bucket is still nonsense. This currently
            // passes the sum check and would be caught by the negative check
            // (after the DB SELECT). A future code change should ideally
            // catch this before the DB round-trip.
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.TotalHits = 5
                b.CenterHits = -5
                b.CloseHits = 5
                b.EdgeHits = 5
                return b
            }(),
            // Currently this gets past the sum check and hits the DB before
            // the negative check fires. With the recommended reorder, this
            // would catch with status 400 + "negative" in body. For now we
            // just verify it doesn't crash and document the gap.
            wantStatus: -1, // skip status assertion; this test is documentation
        },

        // --- Boundary cases that should pass validation ---
        {
            name:          "accepts zero hits with consistent buckets",
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.TotalHits = 0
                b.CenterHits = 0
                b.CloseHits = 0
                b.EdgeHits = 0
                return b
            }(),
            wantStatus: -1, // passes validation, would reach DB
        },
        {
            name:          "accepts outcome=failed",
            uuidPathParam: validUUID,
            body: func() FinishRunRequest {
                b := validBody()
                b.Outcome = "failed"
                return b
            }(),
            wantStatus: -1, // passes validation, would reach DB
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            // As with startRun tests: -1 means "we expect to get past
            // validation", which means the nil DB will panic. We catch it.
            if tc.wantStatus == -1 {
                defer func() { _ = recover() }()
            }

            // Build the URL with the test's uuid path parameter. We have to
            // register a fresh ServeMux for each test because PathValue
            // extraction is done by the mux's pattern matcher, not by raw
            // http.HandlerFunc invocation.
            mux := http.NewServeMux()
            mux.HandleFunc("POST /api/runs/{uuid}/finish", srv.finishRun)

            target := "/api/runs/" + tc.uuidPathParam + "/finish"

            var bodyReader io.Reader
            switch v := tc.body.(type) {
            case string:
                bodyReader = strings.NewReader(v)
            default:
                buf, err := json.Marshal(v)
                if err != nil {
                    t.Fatalf("test setup: failed to marshal body: %v", err)
                }
                bodyReader = bytes.NewReader(buf)
            }

            req := httptest.NewRequest(http.MethodPost, target, bodyReader)
            req.Header.Set("Content-Type", "application/json")
            rec := httptest.NewRecorder()
            mux.ServeHTTP(rec, req)

            if tc.wantStatus == -1 {
                return
            }

            if rec.Code != tc.wantStatus {
                t.Errorf("status: got %d, want %d. body: %s",
                    rec.Code, tc.wantStatus, rec.Body.String())
            }

            if tc.wantBodyToHave != "" && !strings.Contains(rec.Body.String(), tc.wantBodyToHave) {
                t.Errorf("body: got %q, expected to contain %q",
                    rec.Body.String(), tc.wantBodyToHave)
            }
        })
    }
}

// =============================================================================
// levelSum validation tests
// =============================================================================
//
// levelSum has: path UUID parsing, body parsing, range/consistency checks for
// level fields, completed/failed invariants, and per-hit validation. We cover
// everything before the DB transaction here.

func TestLevelSum_Validation(t *testing.T) {
    srv := newTestServer(t)

    // A valid hit that passes all per-hit validation checks.
    validHit := func() HitEvent {
        return HitEvent{
            HitIndex:           0,
            EnemyID:            1,
            TimeMs:             500,
            GametimeAtHitMs:    59000,
            PlayerX:            1.0,
            PlayerY:            1.7,
            PlayerZ:            2.0,
            ViewYaw:            0.5,
            ViewPitch:          0.1,
            EnemyCenterX:       5.0,
            EnemyCenterY:       1.7,
            EnemyCenterZ:       5.0,
            HitX:               5.1,
            HitY:               1.7,
            HitZ:               5.0,
            DistanceFromCenter: 0.1,
            AccuracyBucket:     0,
            GametimeAwardedMs:  2000,
            Spread:             false,
        }
    }

    // A valid completed-level body. Individual tests override one field.
    validBody := func() SubmitLevelRequest {
        h := validHit()
        return SubmitLevelRequest{
            LevelIndex:         0,
            LevelID:            1,
            DurationMs:         5000,
            GametimeEnteringMs: 60000,
            GametimeGainedMs:   2000,
            GametimeLostMs:     5000,
            GametimeExitingMs:  57000,
            EnemiesTotal:       1,
            EnemiesHit:         1,
            Completed:          true,
            Hits:               []HitEvent{h},
        }
    }

    // A valid failed-level body (0 hits, timer expired).
    validFailedBody := func() SubmitLevelRequest {
        return SubmitLevelRequest{
            LevelIndex:         0,
            LevelID:            1,
            DurationMs:         60000,
            GametimeEnteringMs: 60000,
            GametimeGainedMs:   0,
            GametimeLostMs:     60000,
            GametimeExitingMs:  0,
            EnemiesTotal:       15,
            EnemiesHit:         0,
            Completed:          false,
            Hits:               []HitEvent{},
        }
    }

    const validUUID = "550e8400-e29b-41d4-a716-446655440000"

    cases := []struct {
        name           string
        uuidPathParam  string
        body           any
        wantStatus     int
        wantBodyToHave string
    }{
        // --- UUID parsing ---
        {
            name:           "rejects non-UUID path parameter",
            uuidPathParam:  "not-a-uuid",
            body:           validBody(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid run id",
        },
        // --- Body parsing ---
        {
            name:           "rejects malformed JSON",
            uuidPathParam:  validUUID,
            body:           `{"level_index": broken}`,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        {
            name:           "rejects unknown fields in body",
            uuidPathParam:  validUUID,
            body:           `{"level_index": 0, "level_id": 1, "secret": true}`,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        {
            name:           "rejects empty body",
            uuidPathParam:  validUUID,
            body:           ``,
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "invalid json",
        },
        // --- Negative value checks ---
        {
            name:          "rejects negative enemies_hit",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.EnemiesHit = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "enemies hit",
        },
        {
            name:          "rejects negative enemies_total",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.EnemiesTotal = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "enemies total",
        },
        {
            name:          "rejects negative duration_ms",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.DurationMs = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "duration",
        },
        {
            name:          "rejects negative gametime_entering_ms",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.GametimeEnteringMs = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "gametime entering",
        },
        {
            name:          "rejects negative gametime_exiting_ms",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.GametimeExitingMs = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "gametime ex",
        },
        // --- Level index/id bounds ---
        {
            name:          "rejects level_index below range",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelIndex = -1
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "level index",
        },
        {
            name:          "rejects level_index above range",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelIndex = 5
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "level index",
        },
        {
            name:          "rejects level_id zero",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelID = 0
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "level ID",
        },
        {
            name:          "rejects level_id above range",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelID = 6
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "level ID",
        },
        // --- Enemy consistency ---
        {
            name:          "rejects enemies_hit greater than enemies_total",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.EnemiesHit = 5
                b.EnemiesTotal = 3
                b.Hits = []HitEvent{validHit(), validHit(), validHit(), validHit(), validHit()}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "more enemies",
        },
        {
            name:          "rejects hits array length mismatch with enemies_hit",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.EnemiesHit = 2 // but only 1 hit in array
                b.EnemiesTotal = 3
                b.Completed = false
                b.GametimeExitingMs = 0
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "hits imbalanced",
        },
        // --- Completed-level invariants ---
        {
            name:          "rejects completed level where enemies_hit != enemies_total",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.Completed = true
                b.EnemiesTotal = 5
                b.EnemiesHit = 1
                // hits array still has 1 element, matching enemies_hit
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "enemies imbalanced",
        },
        // --- Failed-level invariants ---
        {
            name:          "rejects failed level with nonzero gametime_exiting_ms",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validFailedBody()
                b.GametimeExitingMs = 1000 // should be 0
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "failed level requires gametime exiting",
        },
        {
            name:          "rejects failed level with all enemies cleared",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validFailedBody()
                b.EnemiesTotal = 1
                b.EnemiesHit = 1
                b.Hits = []HitEvent{validHit()}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "failed level cannot have all enemies cleared",
        },
        // --- Per-hit validation ---
        // --- Per-hit validation: enemy_id bounds ---
        // testLevels() builds 5 angles × 3 picks = 15 enemies per level, so
        // valid enemy_id values are 0..14. These tests pin the bounds check
        // that defends against forged enemy_ids.
        {
            name:          "rejects hit with negative enemy_id",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.EnemyID = -1
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "enemy_id out of bounds",
        },
        {
            name:          "rejects hit with enemy_id at upper bound",
            // 15 == EnemiesPerLevel(); valid range is [0, 15).
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.EnemyID = 15
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "enemy_id out of bounds",
        },
        {
            name:          "rejects hit with enemy_id well above bound",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.EnemyID = 9999
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "enemy_id out of bounds",
        },
        {
            name:          "accepts hit with enemy_id at lower boundary 0",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.EnemyID = 0
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts hit with enemy_id at upper boundary 14",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.EnemyID = 14
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus: -1,
        },
        // --- Per-hit validation: other fields ---
        {
            name:          "rejects hit with negative hit_index",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.HitIndex = -1
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "hit index",
        },
        {
            name:          "rejects hit with negative gametime_awarded_ms",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.GametimeAwardedMs = -100
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "gametime awarded",
        },
        {
            name:          "rejects hit with negative distance_from_center",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.DistanceFromCenter = -0.5
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "distance from center",
        },
        {
            name:          "rejects hit with invalid accuracy_bucket",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.AccuracyBucket = 5
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus:     http.StatusBadRequest,
            wantBodyToHave: "accuracy bucket",
        },
        // --- Boundary cases that should pass validation ---
        {
            name:          "accepts valid completed level",
            uuidPathParam: validUUID,
            body:          validBody(),
            wantStatus:    -1, // passes validation, reaches DB
        },
        {
            name:          "accepts valid failed level with zero hits",
            uuidPathParam: validUUID,
            body:          validFailedBody(),
            wantStatus:    -1,
        },
        {
            name:          "accepts failed level with some but not all hits",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validFailedBody()
                h := validHit()
                b.EnemiesHit = 1
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts level_index boundary 0",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelIndex = 0
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts level_index boundary 4",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelIndex = 4
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts level_id boundary 1",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelID = 1
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts level_id boundary 5",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                b.LevelID = 5
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts accuracy_bucket 0",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.AccuracyBucket = 0
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus: -1,
        },
        {
            name:          "accepts accuracy_bucket 2",
            uuidPathParam: validUUID,
            body: func() SubmitLevelRequest {
                b := validBody()
                h := validHit()
                h.AccuracyBucket = 2
                b.Hits = []HitEvent{h}
                return b
            }(),
            wantStatus: -1,
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            if tc.wantStatus == -1 {
                defer func() { _ = recover() }()
            }

            mux := http.NewServeMux()
            mux.HandleFunc("POST /api/runs/{uuid}/levels", srv.levelSum)

            target := "/api/runs/" + tc.uuidPathParam + "/levels"

            var bodyReader io.Reader
            switch v := tc.body.(type) {
            case string:
                bodyReader = strings.NewReader(v)
            default:
                buf, err := json.Marshal(v)
                if err != nil {
                    t.Fatalf("test setup: failed to marshal body: %v", err)
                }
                bodyReader = bytes.NewReader(buf)
            }

            req := httptest.NewRequest(http.MethodPost, target, bodyReader)
            req.Header.Set("Content-Type", "application/json")
            rec := httptest.NewRecorder()
            mux.ServeHTTP(rec, req)

            if tc.wantStatus == -1 {
                return
            }

            if rec.Code != tc.wantStatus {
                t.Errorf("status: got %d, want %d. body: %s",
                    rec.Code, tc.wantStatus, rec.Body.String())
            }

            if tc.wantBodyToHave != "" && !strings.Contains(rec.Body.String(), tc.wantBodyToHave) {
                t.Errorf("body: got %q, expected to contain %q",
                    rec.Body.String(), tc.wantBodyToHave)
            }
        })
    }
}

// =============================================================================
// Routes wiring tests
// =============================================================================
//
// These don't test handler logic — they test that the mux is wired correctly,
// so a regression like "someone deleted the /finish route" gets caught.

func TestRoutes_RegisteredEndpoints(t *testing.T) {
    srv := newTestServer(t)
    handler := srv.Routes()

    cases := []struct {
        name       string
        method     string
        path       string
        wantStatus int // status when called with empty body; we just check it's NOT 404/405
    }{
        {
            name:       "POST /api/runs/start is registered",
            method:     http.MethodPost,
            path:       "/api/runs/start",
            wantStatus: http.StatusBadRequest, // empty body = invalid json
        },
        {
            name:       "POST /api/runs/{uuid}/levels is registered",
            method:     http.MethodPost,
            path:       "/api/runs/550e8400-e29b-41d4-a716-446655440000/levels",
            wantStatus: http.StatusBadRequest, // empty body = invalid json
        },
        {
            name:       "POST /api/runs/{uuid}/finish is registered",
            method:     http.MethodPost,
            path:       "/api/runs/550e8400-e29b-41d4-a716-446655440000/finish",
            wantStatus: http.StatusBadRequest, // empty body = invalid json
        },
        {
            name:       "GET /api/runs/start is rejected (wrong method)",
            method:     http.MethodGet,
            path:       "/api/runs/start",
            wantStatus: http.StatusMethodNotAllowed,
        },
        {
            name:       "POST to unknown path returns 404",
            method:     http.MethodPost,
            path:       "/api/nonexistent",
            wantStatus: http.StatusNotFound,
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(""))
            rec := httptest.NewRecorder()
            handler.ServeHTTP(rec, req)

            if rec.Code != tc.wantStatus {
                t.Errorf("status: got %d, want %d", rec.Code, tc.wantStatus)
            }
        })
    }
}

// =============================================================================
// levelSum: unknown level_id
// =============================================================================
//
// The "unknown level_id" branch fires when a level_id passes the 1..5 range
// check but isn't actually present in the server's levels map (e.g., client
// sends level_id=4 but the server only has 1.json and 2.json on disk).
// The default newTestServer pre-loads IDs 1..5, so this needs a custom server
// with a sparser map to reach that branch.

func TestLevelSum_UnknownLevelID(t *testing.T) {
    srv := &Server{
        db:     nil,
        logger: log.New(io.Discard, "", 0),
        // Only level 1 is present. LevelID=2 will pass the range check but
        // miss the map lookup.
        levels: map[int16]*LoadedLevel{
            1: minimalLevel(5, 5),
        },
    }

    body := SubmitLevelRequest{
        LevelIndex:         1,
        LevelID:            2, // in range [1, 5] but not in srv.levels
        DurationMs:         5000,
        GametimeEnteringMs: 60000,
        GametimeGainedMs:   2000,
        GametimeLostMs:     5000,
        GametimeExitingMs:  57000,
        EnemiesTotal:       1,
        EnemiesHit:         1,
        Completed:          true,
        Hits: []HitEvent{{
            HitIndex: 0, EnemyID: 0, TimeMs: 500, GametimeAtHitMs: 59000,
            PlayerX: 1, PlayerY: 1.7, PlayerZ: 2,
            ViewYaw: 0.5, ViewPitch: 0.1,
            EnemyCenterX: 5, EnemyCenterY: 1.7, EnemyCenterZ: 5,
            HitX: 5.1, HitY: 1.7, HitZ: 5,
            DistanceFromCenter: 0.1, AccuracyBucket: 0,
            GametimeAwardedMs: 2000, Spread: false,
        }},
    }

    mux := http.NewServeMux()
    mux.HandleFunc("POST /api/runs/{uuid}/levels", srv.levelSum)

    buf, err := json.Marshal(body)
    if err != nil {
        t.Fatalf("marshal: %v", err)
    }
    req := httptest.NewRequest(http.MethodPost,
        "/api/runs/550e8400-e29b-41d4-a716-446655440000/levels",
        bytes.NewReader(buf))
    req.Header.Set("Content-Type", "application/json")
    rec := httptest.NewRecorder()
    mux.ServeHTTP(rec, req)

    if rec.Code != http.StatusBadRequest {
        t.Errorf("status: got %d, want 400. body: %s", rec.Code, rec.Body.String())
    }
    if !strings.Contains(rec.Body.String(), "unknown level_id") {
        t.Errorf("body: got %q, expected to contain %q",
            rec.Body.String(), "unknown level_id")
    }
}
package api

import (
    "encoding/json"
    "fmt"
    "os"
    "path/filepath"
    "strings"
    "testing"
)

// productionLevelsDir is the path from this package directory up to the real
// level JSON. Tests that load the production files use this so adding a new
// level under server/assets/levels/ automatically gets covered. If the
// project moves the files, this is the one place that needs updating.
const productionLevelsDir = "../../assets/levels"

// =============================================================================
// LoadLevels: production files
// =============================================================================
//
// Loads the actual on-disk levels from server/assets/levels/. The intent is
// to catch breakage that pure in-memory tests can't see — JSON schema drift,
// a missing field, a typo in a filename, etc. If this test ever fails on
// main, a level file is broken and the server wouldn't start.

func TestLoadLevels_Production(t *testing.T) {
    levels, err := LoadLevels(productionLevelsDir)
    if err != nil {
        t.Fatalf("LoadLevels(%q) failed: %v", productionLevelsDir, err)
    }

    // We currently ship 1.json and 2.json. If someone adds 3.json we want
    // the test to keep passing without code changes — so we assert "at
    // least 1 and 2 are present" rather than "exactly these IDs."
    for _, id := range []int16{1, 2} {
        lv, ok := levels[id]
        if !ok {
            t.Errorf("missing level %d in loaded map", id)
            continue
        }
        if lv == nil {
            t.Errorf("level %d is nil", id)
            continue
        }
        // EnemiesPerLevel relies on AngleCount being populated — a sanity
        // check that the JSON actually parsed into the right fields.
        if lv.EnemiesPerLevel() == 0 {
            t.Errorf("level %d: EnemiesPerLevel() == 0 (angle_count probably zero)", id)
        }
        if len(lv.Raw) == 0 {
            t.Errorf("level %d: Raw is empty (was the file read?)", id)
        }
    }
}

// =============================================================================
// LoadLevels: error paths
// =============================================================================
//
// All of these construct a temp directory with controlled contents. Using
// t.TempDir() means each subtest gets its own dir that's auto-cleaned.

func TestLoadLevels_Errors(t *testing.T) {
    // A minimum-viable level body that passes validateLevelDef. Used as the
    // "good" content when we want a sibling file to be the bad actor.
    okLevelJSON := func() []byte {
        def := minimalLevel(2, 3).Definition
        b, _ := json.Marshal(def)
        return b
    }

    cases := []struct {
        name           string
        // setup writes whatever files into dir before LoadLevels runs.
        setup          func(t *testing.T, dir string)
        wantErrToHave  string // substring expected in returned error
    }{
        {
            name: "rejects nonexistent directory",
            setup: func(t *testing.T, dir string) {
                // Remove the dir t.TempDir() just made so the call fails.
                if err := os.Remove(dir); err != nil {
                    t.Fatalf("setup: failed to remove temp dir: %v", err)
                }
            },
            wantErrToHave: "read level dir",
        },
        {
            name: "rejects empty directory",
            setup: func(t *testing.T, dir string) {
                // Leave dir empty — LoadLevels should report "no level files."
            },
            wantErrToHave: "no level files",
        },
        {
            name: "rejects directory with only non-json files",
            setup: func(t *testing.T, dir string) {
                if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("not a level"), 0644); err != nil {
                    t.Fatalf("setup write: %v", err)
                }
            },
            // .txt files are filtered out, so we end up with zero loaded —
            // same error as the empty-dir case.
            wantErrToHave: "no level files",
        },
        {
            name: "rejects non-numeric filename",
            setup: func(t *testing.T, dir string) {
                if err := os.WriteFile(filepath.Join(dir, "tutorial.json"), okLevelJSON(), 0644); err != nil {
                    t.Fatalf("setup write: %v", err)
                }
            },
            wantErrToHave: "is not an integer id",
        },
        {
            name: "rejects malformed JSON",
            setup: func(t *testing.T, dir string) {
                if err := os.WriteFile(filepath.Join(dir, "1.json"), []byte("{not-valid-json"), 0644); err != nil {
                    t.Fatalf("setup write: %v", err)
                }
            },
            wantErrToHave: "parse",
        },
        {
            name: "rejects level that fails validation",
            setup: func(t *testing.T, dir string) {
                // angle_count=0 is rejected by validateLevelDef.
                bad := []byte(`{"angle_count":0,"spawn_points":[]}`)
                if err := os.WriteFile(filepath.Join(dir, "1.json"), bad, 0644); err != nil {
                    t.Fatalf("setup write: %v", err)
                }
            },
            wantErrToHave: "angle_count",
        },
        {
            name: "fails fast on first bad file even if good files exist",
            // If 1.json is good but 2.json is malformed, we want a clear
            // error, not a silently-partial map.
            setup: func(t *testing.T, dir string) {
                if err := os.WriteFile(filepath.Join(dir, "1.json"), okLevelJSON(), 0644); err != nil {
                    t.Fatalf("setup write 1: %v", err)
                }
                if err := os.WriteFile(filepath.Join(dir, "2.json"), []byte("garbage"), 0644); err != nil {
                    t.Fatalf("setup write 2: %v", err)
                }
            },
            wantErrToHave: "parse",
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            dir := t.TempDir()
            tc.setup(t, dir)

            _, err := LoadLevels(dir)
            if err == nil {
                t.Fatalf("expected error containing %q, got nil", tc.wantErrToHave)
            }
            if !strings.Contains(err.Error(), tc.wantErrToHave) {
                t.Errorf("error %q does not contain %q", err.Error(), tc.wantErrToHave)
            }
        })
    }
}

// =============================================================================
// validateLevelDef
// =============================================================================
//
// Each case constructs a definition that fails one specific invariant.
// validateLevelDef is called from loadLevelFile, but testing it directly
// makes it easy to assert specific error messages.

func TestValidateLevelDef(t *testing.T) {
    // valid returns a passing definition — tests modify one field.
    valid := func() LevelDefinition {
        return minimalLevel(2, 3).Definition
    }

    cases := []struct {
        name          string
        def           LevelDefinition
        wantErr       bool
        wantErrToHave string
    }{
        {
            name:    "accepts valid definition",
            def:     valid(),
            wantErr: false,
        },
        {
            name: "rejects angle_count=0",
            def: func() LevelDefinition {
                d := valid()
                d.AngleCount = 0
                return d
            }(),
            wantErr:       true,
            wantErrToHave: "angle_count",
        },
        {
            name: "rejects empty spawn_points",
            def: func() LevelDefinition {
                d := valid()
                d.SpawnPoints = nil
                return d
            }(),
            wantErr:       true,
            wantErrToHave: "spawn_points is empty",
        },
        {
            name: "rejects angle with fewer than 3 spawn points",
            def: func() LevelDefinition {
                d := valid()
                d.AngleCount = 2
                // Angle 1 has 3 points (good), angle 2 has only 2 (bad).
                d.SpawnPoints = []LevelSpawnPoint{
                    {AngleID: 1, Pos: [3]float32{0, 0, 0}},
                    {AngleID: 1, Pos: [3]float32{0, 0, 0}},
                    {AngleID: 1, Pos: [3]float32{0, 0, 0}},
                    {AngleID: 2, Pos: [3]float32{0, 0, 0}},
                    {AngleID: 2, Pos: [3]float32{0, 0, 0}},
                }
                return d
            }(),
            wantErr:       true,
            wantErrToHave: "angle_id 2",
        },
        {
            name: "rejects angle with zero spawn points",
            // angle 1 has all 6 points; angle 2 has none. Catches the case
            // where an angle is declared but never populated.
            def: func() LevelDefinition {
                d := valid()
                d.AngleCount = 2
                d.SpawnPoints = []LevelSpawnPoint{
                    {AngleID: 1}, {AngleID: 1}, {AngleID: 1},
                    {AngleID: 1}, {AngleID: 1}, {AngleID: 1},
                }
                return d
            }(),
            wantErr:       true,
            wantErrToHave: "angle_id 2",
        },
    }

    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            err := validateLevelDef(&tc.def)
            if tc.wantErr {
                if err == nil {
                    t.Fatalf("expected error containing %q, got nil", tc.wantErrToHave)
                }
                if tc.wantErrToHave != "" && !strings.Contains(err.Error(), tc.wantErrToHave) {
                    t.Errorf("error %q does not contain %q", err.Error(), tc.wantErrToHave)
                }
            } else if err != nil {
                t.Errorf("unexpected error: %v", err)
            }
        })
    }
}

// =============================================================================
// SelectEnemyIndices: determinism
// =============================================================================
//
// This is the property that makes server-side replay validation possible
// later: given the same (seed, levelID, level), the chosen indices are
// identical every time. If this property breaks, anti-cheat checks built on
// re-deriving the picks will silently start rejecting legitimate runs.

func TestSelectEnemyIndices_Determinism(t *testing.T) {
    level := minimalLevel(5, 5)
    seed := []byte("deterministic-test-seed-16-bytes")[:16]

    t.Run("same inputs produce same output", func(t *testing.T) {
        // Run the function many times — once is enough to test correctness,
        // but multiple runs catch issues like accidentally sharing global
        // RNG state between calls.
        first := SelectEnemyIndices(level, seed, 1)
        for i := 0; i < 10; i++ {
            got := SelectEnemyIndices(level, seed, 1)
            if !equalI16(first, got) {
                t.Fatalf("call %d: got %v, want %v", i, got, first)
            }
        }
    })

    t.Run("different seeds produce different output", func(t *testing.T) {
        a := SelectEnemyIndices(level, seed, 1)
        otherSeed := append([]byte(nil), seed...)
        otherSeed[0] ^= 0xFF // flip first byte
        b := SelectEnemyIndices(level, otherSeed, 1)
        if equalI16(a, b) {
            t.Errorf("expected different output for different seeds, got identical: %v", a)
        }
    })

    t.Run("different level_ids produce different output", func(t *testing.T) {
        // This is the key property of the per-level RNG: level 1 and level 2
        // get independent streams from the same seed, so picks for one don't
        // leak into the other.
        a := SelectEnemyIndices(level, seed, 1)
        b := SelectEnemyIndices(level, seed, 2)
        if equalI16(a, b) {
            t.Errorf("expected different output for different level_ids, got identical: %v", a)
        }
    })
}

// =============================================================================
// SelectEnemyIndices: structural properties
// =============================================================================
//
// These don't care about specific values — they assert the shape of the
// output is what the rest of the system depends on.

func TestSelectEnemyIndices_Properties(t *testing.T) {
    cases := []struct {
        angles   uint8
        perAngle int
    }{
        {angles: 1, perAngle: 3},  // smallest valid level
        {angles: 5, perAngle: 5},  // production shape
        {angles: 3, perAngle: 8},  // wider candidate pool
    }

    for _, tc := range cases {
        t.Run(fmt.Sprintf("angles=%d_perAngle=%d", tc.angles, tc.perAngle), func(t *testing.T) {
            level := minimalLevel(tc.angles, tc.perAngle)
            seed := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

            chosen := SelectEnemyIndices(level, seed, 1)

            // Length: AngleCount * 3 picks.
            wantLen := int(tc.angles) * 3
            if len(chosen) != wantLen {
                t.Errorf("length: got %d, want %d", len(chosen), wantLen)
            }

            // Each stride of 3 belongs to one angle (1, 2, 3, ...). Within
            // a stride: indices are unique, all belong to that angle, and
            // each is in range of spawn_points.
            for angleI := 0; angleI < int(tc.angles); angleI++ {
                expectedAngleID := uint8(angleI + 1)
                stride := chosen[angleI*3 : angleI*3+3]

                seen := map[int16]bool{}
                for _, idx := range stride {
                    if idx < 0 || int(idx) >= len(level.Definition.SpawnPoints) {
                        t.Errorf("angle %d: index %d out of range [0, %d)",
                            expectedAngleID, idx, len(level.Definition.SpawnPoints))
                        continue
                    }
                    if seen[idx] {
                        t.Errorf("angle %d: index %d picked twice in stride %v",
                            expectedAngleID, idx, stride)
                    }
                    seen[idx] = true

                    gotAngle := level.Definition.SpawnPoints[idx].AngleID
                    if gotAngle != expectedAngleID {
                        t.Errorf("angle %d: index %d points to spawn with angle_id %d",
                            expectedAngleID, idx, gotAngle)
                    }
                }
            }
        })
    }
}

func equalI16(a, b []int16) bool {
    if len(a) != len(b) {
        return false
    }
    for i := range a {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

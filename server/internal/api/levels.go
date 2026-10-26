package api

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// LevelDefinition mirrors the JSON shape on disk
type LevelDefinition struct {
    Solids       	[]LevelSolid      `json:"solids"`
    PlayerSpawn  	LevelSpawn        `json:"player_spawn"`
    AngleCount   	uint8             `json:"angle_count"`
    SpawnPoints  	[]LevelSpawnPoint `json:"spawn_points"`
    SunDir1      	[3]float32        `json:"sun_dir1"`
    SunColor1    	[3]float32        `json:"sun_color1"`
    SunDir2      	[3]float32        `json:"sun_dir2"`
    SunColor2    	[3]float32        `json:"sun_color2"`
    Ambient      	[3]float32        `json:"ambient"`
    ClearColor   	[4]uint8          `json:"clear_color"`
    EnemyGlow    	[4]uint8          `json:"enemy_glow"`
}

//kind e.g. Box, Cylinder, Sphere
//Box uses size, cylinder+sphere use radius, cylinder-only uses height
type LevelSolid struct {
    Kind      		string     `json:"kind"`
    Pos       		[3]float32 `json:"pos"`
    Size      		[3]float32 `json:"size,omitempty"`
    Radius    		float32    `json:"radius,omitempty"`
    Height    		float32    `json:"height,omitempty"`
    Color     		[4]uint8   `json:"color"`
    Collision 		bool       `json:"collision"`
}

type LevelSpawn struct {
    Pos   			[3]float32 `json:"pos"`
    Yaw   			float32    `json:"yaw"`
    Pitch 			float32    `json:"pitch"`
}

type LevelSpawnPoint struct {
    AngleID 		uint8      `json:"angle_id"`
    Pos     		[3]float32 `json:"pos"`
}

// LoadedLevel pairs the parsed definition (for spawn-index selection) with
// the original raw bytes (forwarded to the client unchanged). Storing the
// raw bytes lets the on-disk JSON evolve fields without server churn — as
// long as the fields the server cares about (spawn_points, angle_count) are
// present, anything else passes through untouched.
type LoadedLevel struct {
    Definition 		LevelDefinition
    Raw        		json.RawMessage
}

// EnemiesPerLevel returns how many enemies this level has at runtime. 
// The rule is 3 picked per angle, to change that rule this function must change
func (l *LoadedLevel) EnemiesPerLevel() int {
    return int(l.Definition.AngleCount) * 3
}

// LoadLevels reads every "{N}.json" file in dir and returns a map keyed by
// the integer N, parsed and validated. Returns an error on the first file
// that fails to load — server should not start with broken level data.
func LoadLevels(dir string) (map[int16]*LoadedLevel, error) {
    entries, err := os.ReadDir(dir)
    if err != nil {
        return nil, fmt.Errorf("read level dir %q: %w", dir, err)
    }

    levels := make(map[int16]*LoadedLevel)
    for _, e := range entries {
        if e.IsDir() {
            continue
        }
        name := e.Name()
        if !strings.HasSuffix(name, ".json") {
            continue
        }
        // Filename is the level_id; reject anything that doesn't parse.
        idStr := strings.TrimSuffix(name, ".json")
        id, err := strconv.ParseInt(idStr, 10, 16)
        if err != nil {
            return nil, fmt.Errorf("level filename %q is not an integer id", name)
        }

        path := filepath.Join(dir, name)
        loaded, err := loadLevelFile(path)
        if err != nil {
            return nil, fmt.Errorf("load %s: %w", path, err)
        }
        levels[int16(id)] = loaded
    }
    if len(levels) == 0 {
        return nil, fmt.Errorf("no level files found in %s", dir)
    }
    return levels, nil
}

func loadLevelFile(path string) (*LoadedLevel, error) {
    raw, err := os.ReadFile(path)
    if err != nil {
        return nil, err
    }
    var def LevelDefinition
    if err := json.Unmarshal(raw, &def); err != nil {
        return nil, fmt.Errorf("parse: %w", err)
    }
    if err := validateLevelDef(&def); err != nil {
        return nil, err
    }
    return &LoadedLevel{Definition: def, Raw: json.RawMessage(raw)}, nil
}

// fail fast is level is incorrectly defined from JSON
func validateLevelDef(def *LevelDefinition) error {
    if def.AngleCount == 0 {
        return fmt.Errorf("angle_count must be >= 1")
    }
    if len(def.SpawnPoints) == 0 {
        return fmt.Errorf("spawn_points is empty")
    }
    // Every angle 1..AngleCount must have at least 3 candidates.
    counts := make(map[uint8]int)
    for _, sp := range def.SpawnPoints {
        counts[sp.AngleID]++
    }
    for a := uint8(1); a <= def.AngleCount; a++ {
        if counts[a] < 3 {
            return fmt.Errorf("angle_id %d has %d spawn points (need >= 3)", a, counts[a])
        }
    }
    return nil
}

// SelectEnemyIndices picks 3 spawn-point indices per angle, deterministically from (seed, levelID).
// indices [0,3) belong to angle 1, [3,6) to angle 2, etc.
// The order matches what the client uses for enemy_id, so enemy_id == position in this slice.
func SelectEnemyIndices(level *LoadedLevel, seed []byte, levelID int16) []int16 {
    rng := levelRNG(seed, levelID)

    // Group candidate indices by angle_id once. Map iteration order doesn't
    // matter because we walk angle_ids in numeric order below.
    byAngle := make(map[uint8][]int)
    for i, sp := range level.Definition.SpawnPoints {
        byAngle[sp.AngleID] = append(byAngle[sp.AngleID], i)
    }

    chosen := make([]int16, 0, level.EnemiesPerLevel())
    for angleID := uint8(1); angleID <= level.Definition.AngleCount; angleID++ {
        // Copy the candidate slice so concurrent /runs/start calls don't race on the shared slice.
        indices := append([]int(nil), byAngle[angleID]...)
        rng.Shuffle(len(indices), func(i, j int) { indices[i], indices[j] = indices[j], indices[i] })
        for k := 0; k < 3; k++ {
            chosen = append(chosen, int16(indices[k]))
        }
    }
    return chosen
}

// levelRNG derives a per-level PCG generator from the run's seed and a level id
// SHA-256 keeps the per-level streams independent
func levelRNG(seed []byte, levelID int16) *rand.Rand {
    h := sha256.New()
    h.Write(seed)
    var lid [2]byte
    binary.LittleEndian.PutUint16(lid[:], uint16(levelID))
    h.Write(lid[:])
    sum := h.Sum(nil)
    s1 := binary.LittleEndian.Uint64(sum[:8])
    s2 := binary.LittleEndian.Uint64(sum[8:16])
    return rand.New(rand.NewPCG(s1, s2))
}
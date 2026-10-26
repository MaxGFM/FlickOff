package game

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

Level_Definition :: struct {
    solids      : []Solid,
    player_spawn: Spawn,
    spawn_points: []Spawn_Point,
    angle_count : u8,           // how many distinct angle_ids this level has (1..angle_count)
    sun_dir1    : rl.Vector3,   // toward the sun
    sun_color1  : rl.Vector3,
    sun_dir2    : rl.Vector3,
    sun_color2  : rl.Vector3,
    ambient     : rl.Vector3,
    clear_color : rl.Color,     // clear background color
    enemy_glow  : rl.Color,     // neon
}

Level :: struct {
    level_def   : Level_Definition,
    solids      : []Solid,
    enemies     : []Enemy,
    spawn       : Spawn,
    hits        : [dynamic]Hit,
    start_time  : f64,          // start time for the level
    begin_time  : i32,
    time_gain   : i32,
    time_lost   : i32,
}

Box :: struct {
    pos  		: rl.Vector3,
    size  		: rl.Vector3,
    color  		: rl.Color,
    collision 	: bool,
}

Cylinder :: struct {
    pos  		: rl.Vector3,   // base center, different from box
    radius  	: f32,
    height 		: f32,
    color  		: rl.Color,
    collision	: bool,
}

Solid :: union { Box, Cylinder }

Spawn :: struct {
    pos         : rl.Vector3,
    yaw         : f32,
    pitch       : f32,
}

Spawn_Point :: struct {
    angle_id    : u8,
    pos         : rl.Vector3,
}

Enemy :: struct {
    pos    		: rl.Vector3,   //this is the center (spawn sphere from center using radius)
    radius      : f32,
    color       : rl.Color,
    active      : bool,
    visible  	: bool,         // for run timer
    last_frame  : int,
    exposed_since_ms  : i32,    // -1 = not currently exposed; onset of line-of-sight
    onscreen_since_ms : i32,    // -1 = not currently on-screen; onset of FOV+LOS (flick clock)
    seg_start_sample  : int,    // len(mouse_samples) captured at on-screen onset
}

// JSON conversion structs
Solid_JSON :: struct {
    kind      : string,
    pos       : [3]f32,
    size      : [3]f32,
    radius    : f32,
    height    : f32,
    color     : [4]u8,
    collision : bool,
}

Spawn_JSON :: struct {
    pos   : [3]f32,
    yaw   : f32,
    pitch : f32,
}

Spawn_Point_JSON :: struct {
    angle_id : u8,
    pos      : [3]f32,
}

Level_JSON :: struct {
    solids       : []Solid_JSON,
    player_spawn : Spawn_JSON,
    angle_count  : u8,
    spawn_points : []Spawn_Point_JSON,
    sun_dir1     : [3]f32,
    sun_color1   : [3]f32,
    sun_dir2     : [3]f32,
    sun_color2   : [3]f32,
    ambient      : [3]f32,
    clear_color  : [4]u8,
    enemy_glow   : [4]u8,
}

// The current level definition
Run_Level :: struct {
    level_id            : i16,
    definition          : Level_Definition,
    enemy_spawn_indices : []i16,
}

// ---------------------------------------------------------------------------
// JSON → live struct conversion
// ---------------------------------------------------------------------------

to_vec3 :: proc(a: [3]f32) -> rl.Vector3 {
    return rl.Vector3{a[0], a[1], a[2]}
}

to_color :: proc(c: [4]u8) -> rl.Color {
    return rl.Color{c[0], c[1], c[2], c[3]}
}

solid_from_json :: proc(s: Solid_JSON) -> Solid {
    switch s.kind {
    case "box":
        return Box{
            pos       = to_vec3(s.pos),
            size      = to_vec3(s.size),
            color     = to_color(s.color),
            collision = s.collision,
        }
    case "cylinder":
        return Cylinder{
            pos       = to_vec3(s.pos),
            radius    = s.radius,
            height    = s.height,
            color     = to_color(s.color),
            collision = s.collision,
        }
    case:
        return Box{}
    }
}

// Builds a heap-allocated Level_Definition from the parsed JSON DTO.
// solids and spawn_points slices are owned by the returned struct
level_def_from_json :: proc(j: Level_JSON) -> Level_Definition {
    solids := make([]Solid, len(j.solids))
    for s, i in j.solids {
        solids[i] = solid_from_json(s)
    }

    spawn_points := make([]Spawn_Point, len(j.spawn_points))
    for sp, i in j.spawn_points {
        spawn_points[i] = Spawn_Point{
            angle_id = sp.angle_id,
            pos      = to_vec3(sp.pos),
        }
    }

    return Level_Definition{
        solids       = solids,
        player_spawn = Spawn{
            pos   = to_vec3(j.player_spawn.pos),
            yaw   = j.player_spawn.yaw,
            pitch = j.player_spawn.pitch,
        },
        spawn_points = spawn_points,
        angle_count  = j.angle_count,
        sun_dir1     = to_vec3(j.sun_dir1),
        sun_color1   = to_vec3(j.sun_color1),
        sun_dir2     = to_vec3(j.sun_dir2),
        sun_color2   = to_vec3(j.sun_color2),
        ambient      = to_vec3(j.ambient),
        clear_color  = to_color(j.clear_color),
        enemy_glow   = to_color(j.enemy_glow),
    }
}

// Frees a single Run_Level's owned memory: definition slices + indices.
free_run_level :: proc(rl_: ^Run_Level) {
    if rl_.definition.solids != nil do delete(rl_.definition.solids)
    if rl_.definition.spawn_points != nil do delete(rl_.definition.spawn_points)
    if rl_.enemy_spawn_indices != nil do delete(rl_.enemy_spawn_indices)
    rl_^ = Run_Level{}
}

// Frees the full per-run levels array. Call at run end / shutdown only.
// Safe to call when levels^ is nil/empty.
free_run_levels :: proc(levels: ^[]Run_Level) {
    if levels^ == nil do return
    for &lv in levels^ {
        free_run_level(&lv)
    }
    delete(levels^)
    levels^ = nil
}

free_level :: proc(gs: ^Game_State) {
	// free previous level's memory as needed
    if gs.level.solids  != nil do delete(gs.level.solids)
    if gs.level.enemies != nil do delete(gs.level.enemies)
    if gs.level.hits    != nil do delete(gs.level.hits)
    gs.level = Level{}
}

load_level :: proc(gs: ^Game_State, level_num: int) {
 	free_level(gs)

    // Find the Run_Level matching this level_id.
    target_id := i16(level_num)
    rl_idx := -1
    for lv, i in gs.levels {
        if lv.level_id == target_id {
            rl_idx = i
            break
        }
    }
    if rl_idx == -1 {
        return
    }
    rlv := &gs.levels[rl_idx]
    def := rlv.definition  // struct copy; aliases the heap-owned slices

    // Copy solids to heap so `delete` above works on the next transition.
    solids := make([]Solid, len(def.solids))
    copy(solids, def.solids)

    //different proc definition when receiving level-def from server
    enemies := generate_enemies(def, rlv.enemy_spawn_indices)

    finalize_level(gs, solids, enemies, def)
    gs.cur_level = level_num
    gs.player.position = def.player_spawn.pos
    gs.player.yaw = def.player_spawn.yaw
    gs.player.pitch = def.player_spawn.pitch
    gs.player.velocity = {}
    gs.phase = .Playing
    level_start_recording(gs.player)
    rl.DisableCursor()

    set_sun(gs.pipeline, def)
}

finalize_level :: proc(gs: ^Game_State, solids: []Solid, enemies: []Enemy, def: Level_Definition) {
    gs.level = Level{
        level_def  = def,
        solids     = solids,
        enemies    = enemies,
        spawn      = def.player_spawn,
        hits       = make([dynamic]Hit, 0, len(enemies)),
        start_time = rl.GetTime(),
        begin_time = gs.rem_time,
    }
}

// Builds an Enemy at each of the server-supplied spawn point indices per def.spawn_points.
// out-of-range entries are logged and fall back to spawn point 0 to prevent game crash.
generate_enemies :: proc(def: Level_Definition, indices: []i16) -> []Enemy {
    enemies := make([]Enemy, len(indices))
    for idx_i16, i in indices {
        idx := int(idx_i16)
        if idx < 0 || idx >= len(def.spawn_points) {
            idx = 0
        }
        sp := def.spawn_points[idx]
        enemies[i] = Enemy{ 
            pos                 = sp.pos, 
            radius              = 0.5, 
            color               = rl.ORANGE, 
            active              = true, 
            visible             = false, 
            last_frame          = 0, 
            exposed_since_ms    = -1,
            onscreen_since_ms   = -1,
            seg_start_sample    = -1,
        }
    }
    return enemies
}

draw_level_solids :: proc(level: Level) {
    for s in level.solids {
        draw_solid(s)
    }
}

draw_level_enemies :: proc(level: Level) {
    for e in level.enemies {
        if !e.active do continue
        rl.DrawSphere(e.pos, e.radius, e.color)
    }
}

draw_metrics :: proc(gs: Game_State) {
    TEXT_SIZE :: 20
    fps := rl.TextFormat("FPS: %d", rl.GetFPS())
    rl.DrawText(fps, i32(gs.c_screen.x + (gs.c_screen.x*.85)), i32(gs.c_screen.y - (gs.c_screen.y*.95)), TEXT_SIZE, rl.GREEN)

    //could derive this from hits and level_def angles * 3
    active_enemies := 0
    for e in gs.level.enemies {
        if e.active {
            active_enemies += 1
        }
    }
    enemies_rem := rl.TextFormat("ENEMIES: %d", active_enemies)
    rl.DrawText(enemies_rem, i32(gs.c_screen.x - (gs.c_screen.x*.96)), i32(gs.c_screen.y - (gs.c_screen.y*.95)), TEXT_SIZE, rl.GREEN)
}

solid_aabb :: proc(s: Solid) -> rl.BoundingBox {
    switch v in s {
    case Box:
        half := v.size * 0.5
        return rl.BoundingBox{ min = v.pos - half, max = v.pos + half }
    case Cylinder:
        return rl.BoundingBox{
            min = { v.pos.x - v.radius, v.pos.y,            v.pos.z - v.radius },
            max = { v.pos.x + v.radius, v.pos.y + v.height, v.pos.z + v.radius },
        }
    }
    return rl.BoundingBox{}
}

solid_collision :: proc(s: Solid) -> bool {
    switch v in s {
    case Box  		: return v.collision
    case Cylinder 	: return v.collision
    }
    return false
}

draw_solid :: proc(s: Solid) {
    switch v in s {
    case Box  		: rl.DrawCubeV(v.pos, v.size, v.color)
    case Cylinder  	: rl.DrawCylinder(v.pos, v.radius, v.radius, v.height, 16, v.color)
    }
}

player_aabb :: proc(pos: rl.Vector3) -> rl.BoundingBox {
    return rl.BoundingBox{
        min = {pos.x - PLAYER_RADIUS, pos.y,                 pos.z - PLAYER_RADIUS},
        max = {pos.x + PLAYER_RADIUS, pos.y + PLAYER_HEIGHT, pos.z + PLAYER_RADIUS},
    }
}

collides :: proc(pos: rl.Vector3, level: Level) -> bool {
    box := player_aabb(pos)
    for s in level.solids {
        if !solid_collision(s) do continue
        if rl.CheckCollisionBoxes(box, solid_aabb(s)) do return true
    }
    return false
}

// Used by both shot wall-blocking and enemy visibility.
solid_ray_collision :: proc(s: Solid, ray: rl.Ray) -> rl.RayCollision {
    switch v in s {
    case Box:
        return rl.GetRayCollisionBox(ray, solid_aabb(s))
    case Cylinder:
    	return get_ray_collision_cylinder(ray, v.pos, v.radius, v.height)
    }
    return rl.RayCollision{}
}

//specific to cylinders obviously
get_ray_collision_cylinder :: proc(ray: rl.Ray, base: rl.Vector3, radius, height: f32) -> rl.RayCollision {
    result := rl.RayCollision{}
    best_t := max(f32)

    y_min := base.y
    y_max := base.y + height

    // --- Side (infinite cylinder in XZ, clipped to [y_min, y_max]) ---
    dx := ray.position.x - base.x
    dz := ray.position.z - base.z
    a  := ray.direction.x*ray.direction.x + ray.direction.z*ray.direction.z
    b  := 2*(dx*ray.direction.x + dz*ray.direction.z)
    c  := dx*dx + dz*dz - radius*radius

    if a > 1e-6 {   // skip if ray is parallel to the cylinder axis
        disc := b*b - 4*a*c
        if disc >= 0 {
            sq := math.sqrt(disc)
            ts := [2]f32{ (-b - sq) / (2*a), (-b + sq) / (2*a) }
            for t in ts {
                if t < 0 do continue
                y_hit := ray.position.y + t*ray.direction.y
                if y_hit < y_min || y_hit > y_max do continue
                if t < best_t {
                    best_t = t
                    hx := ray.position.x + t*ray.direction.x
                    hz := ray.position.z + t*ray.direction.z
                    result.normal = { (hx - base.x)/radius, 0, (hz - base.z)/radius }
                }
            }
        }
    }

    // --- Caps (bottom at y_min, top at y_max) ---
    if abs(ray.direction.y) > 1e-6 {
        // Bottom
        t := (y_min - ray.position.y) / ray.direction.y
        if t >= 0 && t < best_t {
            hx := ray.position.x + t*ray.direction.x
            hz := ray.position.z + t*ray.direction.z
            ex := hx - base.x
            ez := hz - base.z
            if ex*ex + ez*ez <= radius*radius {
                best_t = t
                result.normal = {0, -1, 0}
            }
        }
        // Top
        t = (y_max - ray.position.y) / ray.direction.y
        if t >= 0 && t < best_t {
            hx := ray.position.x + t*ray.direction.x
            hz := ray.position.z + t*ray.direction.z
            ex := hx - base.x
            ez := hz - base.z
            if ex*ex + ez*ez <= radius*radius {
                best_t = t
                result.normal = {0, 1, 0}
            }
        }
    }

    if best_t < max(f32) {
        result.hit = true
        result.distance = best_t
        result.point = ray.position + ray.direction * best_t
    }
    return result
}

level_state :: proc(gs: ^Game_State) {
    if !gs.run_active do return
    // player ran out of time
    if gs.rem_time <= 0 {
        on_level_fail(gs)
        return
    }
    // player completed level
    if len(gs.level.hits) == len(gs.level.enemies) {
        on_level_complete(gs)
    }
}

on_level_fail :: proc(gs: ^Game_State) {
    level_stop_recording()
    time := rl.GetTime()
    req  := build_level_req(gs, false, time)
    body := marshal_level_req(req)
    path := fmt.aprintf("/api/runs/%s/levels", gs.run_uuid)
    defer delete(path)
    gs.pending_submit  = net_post_async(path, body)
    gs.pending_op      = .Level_Submit
    gs.finish_outcome  = "failed"

    on_run_end(gs)
    gs.phase = .Run_Failed
}

on_level_complete :: proc(gs: ^Game_State) {
    level_stop_recording()
    time := rl.GetTime()
    req  := build_level_req(gs, true, time)
    body := marshal_level_req(req)
    path := fmt.aprintf("/api/runs/%s/levels", gs.run_uuid)
    defer delete(path)
    gs.pending_submit  = net_post_async(path, body)
    gs.pending_op      = .Level_Submit
    gs.finish_outcome  = "completed"

    if gs.cur_level >= len(gs.levels) {
        // queue the finish request too; intermission/run-complete
        // poller will drain both in turn
        on_run_end(gs)
        gs.phase = .Run_Complete
        return
    }
    gs.phase = .Level_Intermission
    rl.EnableCursor()
}
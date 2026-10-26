//https://zylinski.se/odin-raylib-web/
//the below code in this file is heavily changed from Karl Zylinski's odin-raylib-web template
//however, it follows the same structure as provided in the template through these procs:
//init, update, parent_window_size_changed, shutdown, should_run
//the should_run proc remains unchanged

package game

import rl "vendor:raylib"
import "core:fmt"
import "core:c"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

MAX_SPEED            :: f32(12.0)
ACCEL                :: f32(4.0)
FRICTION             :: f32(13.0)
EYE_HEIGHT           :: f32(1.7)
SENSITIVITY          :: f32(0.002)
PLAYER_RADIUS        :: f32(0.4)
PLAYER_HEIGHT        :: f32(1.8)
MOVEMENT_THRESHOLD   :: f32(0.8) // when am I actually considered still
//spread cone Ring shape: shots land between 60% and 100% of max angle, never close
SPREAD_MAX_ANGLE_RAD :: f32(0.35)   // ~20 degrees
SPREAD_MIN_FRACTION  :: f32(0.7)    // less inner tolerance
SPREAD_MAX_FRACTION  :: f32(1.0)

//related to async network requests
Pending_Op :: enum {
    None,
    Level_Submit,
    Finish_Submit,
}

Game_Phase :: enum {
    Start,                      // launched the game
    Playing,                    // in a level, normal gameplay
    Level_Intermission,         // between levels, showing results
    Run_Complete,               // showing final run summary
    Run_Failed,                 // showing failure screen
}

Game_Mode :: enum {
    Normal,                     // standard movement
    Tactical,                   // tac-shooter movement (affects aim)
}

Game_State :: struct {
    //networking
    run_uuid        : string,
    run_active      : bool,
    web_ready       : bool,          // true once net_start_run response is resolved
    cur_seed        : []u8,
    pending_submit  : Submit_Handle, // INVALID_HANDLE when nothing in flight
    pending_op      : Pending_Op,    // network
    levels          : []Run_Level,   // levels via Go from JSON
    //session
    start_time      : f64,           // start time for the run
    rem_time        : i32,           // ticking timer across all levels
    frame_count     : int,
    player          : Player,
    shot_delay      : f64,
    c_screen        : rl.Vector2,
    camera          : rl.Camera3D,
    pipeline        : Glow_Pipeline,
    cur_level       : int,
    level           : Level,
    phase           : Game_Phase,
    mode            : Game_Mode,
    finish_outcome  : string,        // "completed" | "failed", set when Level_Submit completes
}

Player :: struct {
    position        : rl.Vector3,   // place
    velocity        : rl.Vector3,   // speed
    yaw             : f32,          // left or right
    pitch           : f32,          // up or down
}

Hit :: struct {
    hit_id          : i16,
    time_ms         : i32,
    gametime_ms     : i32,          // remaining time
    enemy_id        : i16,
    enemy_ctr       : rl.Vector3,
    p_pos           : rl.Vector3,
    p_yaw           : f32,
    p_pitch         : f32,
    hit_point       : rl.Vector3,
    dist_ctr        : f32,
    accuracy        : i16,
    add_time        : i32,          // added time from hit
    tac_spread      : bool,
    time_since_exposed_ms  : i32,   // -1 = never exposed (NULL on the wire)
    time_since_onscreen_ms : i32,   // -1 = killed before crossing into view
    seg_start_sample       : int,   // inclusive start index into mouse_samples
    seg_end_sample         : int,   // exclusive end (== len at hit)
}

run     : bool
gs      : Game_State

init :: proc() {
	run = true
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 720, "FlickOff")

	net_init()
    net_async_init()

    gs = Game_State{
        camera = rl.Camera3D{
            fovy       = 90.0,
            projection = .PERSPECTIVE,
            up         = {0, 1, 0},
        },
        mode = .Normal,
        c_screen = rl.Vector2{f32(rl.GetScreenWidth())/2, f32(rl.GetScreenHeight())/2},
    }
    //lighting
    pipeline := init_pipeline(1280, 720)
    gs.pipeline = pipeline
    // Start a run immediately on launch
    uuid, seed, ok, gametime, levels := net_start_run(gs.mode)
    if ok {
        gs.run_uuid     = uuid
        gs.cur_seed     = seed
        gs.rem_time     = gametime
        gs.levels       = levels
        gs.run_active   = true
        gs.web_ready    = true
        fmt.printfln("[GAME] Run started — UUID: %s, levels: %d", uuid, len(levels))
    } // web hack here
    // used to have an 'else' here so the game fails if net_start_run fails,
    // removed it because web will have ok=false guaranteed as a hack for async.
    // at this state of development, if Go server is not running the game fails
    gs.start_time = rl.GetTime()
}

update :: proc() {
    gs.frame_count += 1
    delta := rl.GetFrameTime()

    switch gs.phase {
    case .Start:
        // basically web-only net async init here, native never hits this
        if !gs.web_ready {
            uuid, seed, ok, gametime, levels, done := net_poll_start_run()
            if done {
                gs.web_ready = true
                if ok {
                    gs.run_uuid   = uuid
                    gs.cur_seed   = seed
                    gs.rem_time   = gametime
                    gs.levels     = levels
                    gs.run_active = true
                    fmt.printfln("[GAME] Run started — UUID: %s, levels: %d", uuid, len(levels))
                } else {
                    fmt.eprintln("[GAME] WARNING: could not start run, playing offline")
                }
            }
        }
        if rl.IsKeyPressed(.SPACE) {
            load_level(&gs, gs.cur_level + 1)
        }
        rl.BeginDrawing()
        rl.ClearBackground(rl.BEIGE)
        //TODO update to be based on screen size
        rl.DrawText(fmt.ctprintf("Press SPACEBAR to Start"), 100, 300, 30, rl.WHITE)
        rl.EndDrawing()
    case .Playing:
        update_player(&gs.player, gs.level, delta)
        update_camera(&gs.camera, gs.player)
        metrics_frame_sync(gs.player) // re-seed sample yaw/pitch integrator
        update_time(&gs, delta)
        update_enemy_visibility(&gs)  // this must always happen before shoot()
        shoot(&gs)
        level_state(&gs)
        render_frame(gs.pipeline, gs, gs.level.level_def)
    case .Level_Intermission:
        drain_pending(&gs)
        if rl.IsKeyPressed(.SPACE) && gs.pending_submit == INVALID_HANDLE {
            gs.run_active = true
            load_level(&gs, gs.cur_level + 1)
        }
        rl.BeginDrawing()
        rl.ClearBackground(rl.BEIGE)
        draw_summary(gs, "Continue")
        //TODO update to be based on screen size
        rl.DrawText("Level Complete", 100, 100, 30, rl.WHITE)
        if gs.pending_submit != INVALID_HANDLE {
            rl.DrawText("submitting...", 100, 200, 20, rl.GRAY)
        }
        rl.EndDrawing()
    case .Run_Complete, .Run_Failed:
        drain_pending(&gs)
        if rl.IsKeyPressed(.SPACE) && gs.pending_submit == INVALID_HANDLE {
            free_all(context.temp_allocator)
            run = false
            return
        }
        rl.BeginDrawing()
        rl.ClearBackground(rl.BEIGE)
        draw_summary(gs, "Return")
        //TODO update to be based on screen size
        label : cstring = "Run Complete" if gs.phase == .Run_Complete else "Run Failed"
        rl.DrawText(label, 100, 100, 30, rl.WHITE)
        if gs.pending_submit != INVALID_HANDLE {
            rl.DrawText("submitting...", 100, 200, 20, rl.GRAY)
        }
        rl.EndDrawing()
    }
    free_all(context.temp_allocator)
}

// In a web build, this is called when browser changes size. Remove the
// `rl.SetWindowSize` call if you don't want a resizable game.
parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(c.int(w), c.int(h))
    gs.c_screen = rl.Vector2{f32(w)/2, f32(h)/2}
    // hack to get web working properly
    // basically this is guaranteed to be called on web
    free_pipeline(&gs.pipeline)
    pipeline := init_pipeline(i32(w), i32(h))
    gs.pipeline = pipeline
}

shutdown :: proc() {
	if gs.run_active {
        req := Finish_Run_Request{ outcome = "abandoned" }
        body := marshal_finish_req(req)
        if body != nil {
            path := fmt.aprintf("/api/runs/%s/finish", gs.run_uuid)
            defer delete(path)
            _ = net_post_async(path, body)
        }
    }
    metrics_shutdown()
    net_async_shutdown()

    if gs.run_uuid != "" {
        delete(gs.run_uuid)
    }
    if gs.cur_seed != nil {
        delete(gs.cur_seed)
        gs.cur_seed = nil
    }
    free_run_levels(&gs.levels)
    free_level(&gs)

    free_pipeline(&gs.pipeline)
    net_shutdown()
    rl.CloseWindow()
}

should_run :: proc() -> bool {
	when ODIN_OS != .JS {
		// Never run this proc in browser. It contains a 16 ms sleep on web!
		if rl.WindowShouldClose() {
			run = false
		}
	}

	return run
}

update_player :: proc(p: ^Player, level: Level, delta: f32) {
    PITCH_LIMIT :: f32(math.PI/2 - 0.01)
    // Look: yaw/pitch from mouse, pitch clamped
    md          := rl.GetMouseDelta()
    p.yaw       -= md.x * SENSITIVITY
    p.pitch     -= md.y * SENSITIVITY
    p.pitch      = clamp(p.pitch, -PITCH_LIMIT, PITCH_LIMIT)

    // Build forward vector, then flatten for movement basis
    forward := rl.Vector3{
        math.cos(p.pitch) * math.sin(p.yaw),
        math.sin(p.pitch),
        math.cos(p.pitch) * math.cos(p.yaw),
    }
    forward_flat := linalg.normalize(rl.Vector3{forward.x, 0, forward.z})
    right_flat   := rl.Vector3{forward_flat.z, 0, -forward_flat.x}

    // Read input
    fb := f32(int(rl.IsKeyDown(.W)) - int(rl.IsKeyDown(.S)))
    lr := f32(int(rl.IsKeyDown(.A)) - int(rl.IsKeyDown(.D)))

    // Normalized direction the player wishes to move this frame, based on their input
    wish         := forward_flat*fb + right_flat*lr
    wish_len     := linalg.length(wish)
    if wish_len > 0.001 {
        wish = wish / wish_len
    } else {
        wish = {}
    }

    // Lerp velocity toward wish * MAX_SPEED, friction when idle
    target_vel   := wish * MAX_SPEED
    rate         := ACCEL if wish_len > 0 else FRICTION
    t            := min(1, rate * delta)
    p.velocity.x  = rl.Lerp(p.velocity.x, target_vel.x, t)
    p.velocity.z  = rl.Lerp(p.velocity.z, target_vel.z, t)

    // Horizontal movement with sliding
    new_pos      := p.position
    new_pos.x    += p.velocity.x * delta
    if collides(new_pos, level) {
        new_pos.x = p.position.x
        p.velocity.x = 0
    }
    new_pos.z    += p.velocity.z * delta
    if collides(new_pos, level) {
        new_pos.z = p.position.z
        p.velocity.z = 0
    }
    p.position    = new_pos
}

update_camera :: proc(cam: ^rl.Camera3D, p: Player) {
    forward := rl.Vector3{
        math.cos(p.pitch) * math.sin(p.yaw),
        math.sin(p.pitch),
        math.cos(p.pitch) * math.cos(p.yaw),
    }
    cam.position = p.position + {0, EYE_HEIGHT, 0}
    cam.target   = cam.position + forward
    cam.up       = {0, 1, 0}
}

shoot :: proc(gs: ^Game_State) {
    if !rl.IsMouseButtonPressed(.LEFT) do return

    //delay: 100ms between shots
    now := rl.GetTime()
    if now < gs.shot_delay do return
    gs.shot_delay = now + 0.15

    moving  := linalg.length(gs.player.velocity) > MOVEMENT_THRESHOLD
    spread  := gs.mode == .Tactical && moving
    forward := rl.Vector3Normalize(gs.camera.target - gs.camera.position)
    //apply tactical mode inaccuracy
    if spread {
        forward = apply_spread(forward)
    }
    shot := rl.Ray{
        position = gs.camera.position,
        direction = forward,
    }

    //no bullet pen on solids with collision
    wall_dist := f32(200)
    wall_point := shot.position + shot.direction * wall_dist
    for s in gs.level.solids {
        if !solid_collision(s) do continue
        hit := solid_ray_collision(s, shot)
        if hit.hit && hit.distance < wall_dist {
            wall_dist = hit.distance
            wall_point = hit.point
        }
    }

    //no bullet pen on enemies
    target_idx   := -1
    target_dist  := f32(200)
    target_point : rl.Vector3
    for &enemy, i in gs.level.enemies {
        if !enemy.active do continue
        hit := rl.GetRayCollisionSphere(shot, enemy.pos, enemy.radius)
        if hit.hit && hit.distance < target_dist {
            target_dist  = hit.distance
            target_idx   = i
            target_point = hit.point
        }
    }

    if target_idx < 0 do return             // missed shot
    if wall_dist < target_dist do return    // shot blocked
    enemy := &gs.level.enemies[target_idx]  // shot hit

    // Accuracy: perpendicular distance from shot ray to enemy center
    d    := shot_accuracy(shot, enemy^)
    frac := d / enemy.radius

    bucket  : i16
    awarded : i32
    switch {
    case frac <= 0.1:
        bucket  = 0
        awarded = 1000   // placeholder: center
    case frac <= 0.5:
        bucket  = 1
        awarded = 600    // placeholder: close
    case:
        bucket  = 2
        awarded = 100    // placeholder: edge
    }

    now_ms := i32((rl.GetTime() - gs.level.start_time) * 1000)

    // Reaction clocks. -1 sentinel = "no valid onset" → store NULL server-side.
    tse : i32 = -1
    if enemy.exposed_since_ms >= 0 {
        tse = now_ms - enemy.exposed_since_ms
    }
    tso : i32 = -1
    if enemy.onscreen_since_ms >= 0 {
        tso = now_ms - enemy.onscreen_since_ms
    }

    // Engagement segment: seg_start, current sample count
    // seg_start may be -1 if the target was killed before any on-screen onset
    // e.g. a blind flick will be recorded as an empty/sentinel range.
    seg_start := enemy.seg_start_sample
    seg_end   := len(mouse_samples)
    if seg_start < 0 {
        seg_start = seg_end   // empty segment; no on-screen motion was captured
    }

    append(&gs.level.hits, Hit{
        hit_id                  = i16(len(gs.level.hits)),
        enemy_id                = i16(target_idx),
        time_ms                 = now_ms,
        gametime_ms             = gs.rem_time,
        p_pos                   = gs.player.position,
        p_yaw                   = gs.player.yaw,
        p_pitch                 = gs.player.pitch,
        enemy_ctr               = enemy.pos,
        hit_point               = target_point,
        dist_ctr                = d,
        accuracy                = bucket,
        add_time                = awarded,
        tac_spread              = spread,
        time_since_exposed_ms   = tse,
        time_since_onscreen_ms  = tso,
        seg_start_sample        = seg_start,
        seg_end_sample          = seg_end,
    })

    gs.rem_time             += awarded
    gs.level.time_gain      += awarded
    enemy.active            = false
    enemy.visible           = false
    enemy.exposed_since_ms  = -1   // explicit; enemy is hit, clocks are meaningless now
    enemy.onscreen_since_ms = -1
}

apply_spread :: proc(dir: rl.Vector3) -> rl.Vector3 {
    //make the shot go crazy
    u := rand.float32_range(SPREAD_MIN_FRACTION * SPREAD_MIN_FRACTION,
                            SPREAD_MAX_FRACTION * SPREAD_MAX_FRACTION)
    r_frac := math.sqrt(u)
    theta  := rand.float32_range(0, 2 * math.PI)

    // Local offsets on the plane perpendicular to dir
    offset_angle := SPREAD_MAX_ANGLE_RAD * r_frac
    sin_off := math.sin(offset_angle)
    cos_off := math.cos(offset_angle)

    // Build a basis perpendicular to dir. Pick "up" that isn't parallel to dir.
    up := rl.Vector3{0, 1, 0}
    if abs(linalg.dot(dir, up)) > 0.99 {
        up = rl.Vector3{1, 0, 0}  // fallback if looking straight up/down
    }
    right := linalg.normalize(linalg.cross(dir, up))
    true_up := linalg.cross(right, dir)

    // Offset direction in the perpendicular plane
    perp := right * math.cos(theta) + true_up * math.sin(theta)

    // The new direction is dir rotated toward perp by offset_angle
    return linalg.normalize(dir * cos_off + perp * sin_off)
}

shot_accuracy :: proc(shot: rl.Ray, enemy: Enemy) -> f32 {
    // Vector from shot origin to enemy center
    offset := enemy.pos - shot.position
    // Project that onto the shot direction
    along := rl.Vector3DotProduct(offset, shot.direction)
    // Closest point on the shot to the enemy center
    closest := shot.position + shot.direction * along
    // Perpendicular distance from shot to center
    return rl.Vector3Distance(closest, enemy.pos)
}

draw_summary :: proc(gs: Game_State, next: string) {
    //TODO make dependent on screen size 
    //click to whatever
    leave := fmt.ctprintf("Press SPACEBAR to %s", next)
    rl.DrawText(leave, 100, 330, 30, rl.WHITE)

    rl.DrawText("Level Summary", 700, 100, 30, rl.WHITE)
    //This level took X seconds
    duration        := gs.level.time_lost
    line := fmt.ctprintf("Duration: %.2fs", f32(duration) / 1000.0)
    rl.DrawText(line, 700, 160, 24, rl.WHITE)
    //Total time change during level: 
    time_delta      := gs.level.time_gain - gs.level.time_lost
    line = fmt.ctprintf("Net time change: %+.2fs", f32(time_delta) / 1000.0)
    rl.DrawText(line, 700, 190, 24, rl.WHITE)

    //Total time remaining
    line = fmt.ctprintf("Total time remaining: %.2fs", f32(gs.rem_time) / 1000.0)
    rl.DrawText(line, 700, 220, 24, rl.WHITE)

    hit_count       := i32(len(gs.level.hits))
    target_avg_ms   : i32
    counts          : [3]i32
    if hit_count > 0 {
        target_avg_ms = duration / hit_count
        for h in gs.level.hits do counts[h.accuracy] += 1
    }
    //Average time taken per target: X
    line = fmt.ctprintf("Avg time per target: %.2fs", f32(target_avg_ms) / 1000.0)
    rl.DrawText(line, 700, 250, 24, rl.WHITE)

    //Targets remaining: X
    targets_rem     : i32
    for e in gs.level.enemies {
        if e.active do targets_rem += 1
    }
    line = fmt.ctprintf("Targets remaining: %d", targets_rem)
    rl.DrawText(line, 700, 280, 24, rl.WHITE)

    //Accuracy per target: X
    line = fmt.ctprintf("Shot Dispersion -\nCenter: %d   Close: %d   Edge: %d",
        counts[0], counts[1], counts[2])
    rl.DrawText(line, 700, 310, 24, rl.WHITE)
}

update_time :: proc(gs: ^Game_State, delta: f32) {
    if !gs.run_active do return

    if any_enemy_visible(gs) {
        drain              := i32(delta * 1000)
        actual             := min(drain, gs.rem_time) // only count what was actually there to lose
        gs.rem_time        -= drain
        gs.level.time_lost += actual
        if gs.rem_time < 0 do gs.rem_time = 0
    }
}

update_enemy_visibility :: proc(gs: ^Game_State) {
    now_ms := i32((rl.GetTime() - gs.level.start_time) * 1000)
    for &enemy in gs.level.enemies {
        if !enemy.active do continue

        exposed  := enemy_visible(gs, enemy) // occlusion only — drives timer
        onscreen := exposed && in_view_cone(gs, enemy) // flick clock

        if exposed && enemy.exposed_since_ms < 0 {
            enemy.exposed_since_ms = now_ms
        } else if !exposed {
            enemy.exposed_since_ms = -1
        }

        if onscreen && enemy.onscreen_since_ms < 0 {
            enemy.onscreen_since_ms = now_ms
            enemy.seg_start_sample  = len(mouse_samples) // flick segment starts here
        } else if !onscreen {
            enemy.onscreen_since_ms = -1
        }

        enemy.visible    = exposed // timer reads this, unchanged
        enemy.last_frame = gs.frame_count
    }
}

enemy_visible :: proc(gs: ^Game_State, enemy: Enemy) -> bool {
    // note to me: use this for anti-cheat DB check, not the field on struct
    to_enemy    := enemy.pos - gs.camera.position
    dist        := rl.Vector3Length(to_enemy)
    if dist < 0.0001 do return true

    forward     := to_enemy / dist

    // Camera-space right/up. Using world-up as the seed is standard;
    // it degenerates only if you look straight up or down, which isn't allowed.
    world_up    := rl.Vector3{0, 1, 0}
    if abs(rl.Vector3DotProduct(forward, world_up)) > 0.99 {
        world_up = rl.Vector3{1, 0, 0}
    }
    right       := rl.Vector3Normalize(rl.Vector3CrossProduct(forward, world_up))
    up          := rl.Vector3CrossProduct(right, forward) // already unit length

    // Center + 4 silhouette samples. Sample on the visible hemisphere
    // (pulled toward the camera by a hair) so the offset point isn't
    // buried inside the far side of the sphere.
    r := enemy.radius * 0.95
    samples := [5]rl.Vector3{
        enemy.pos,
        enemy.pos + right *  r,
        enemy.pos + right * -r,
        enemy.pos + up    *  r,
        enemy.pos + up    * -r,
    }

    for sample in samples {
        to_sample := sample - gs.camera.position
        sample_dist := rl.Vector3Length(to_sample)
        if sample_dist < 0.0001 do return true

        ray := rl.Ray{
            position  = gs.camera.position,
            direction = to_sample / sample_dist,
        }

        clear := true
        for s in gs.level.solids {
            if !solid_collision(s) do continue
            hit := solid_ray_collision(s, ray)
            if hit.hit && hit.distance < sample_dist {
                clear = false
                break
            }
        }
        if clear do return true
    }
    return false
}

any_enemy_visible :: proc(gs: ^Game_State) -> bool {
    for enemy in gs.level.enemies {
        if enemy.active && enemy.visible do return true
    }
    return false
}

// is the target inside the player's view cone right now (anticheat)
in_view_cone :: proc(gs: ^Game_State, enemy: Enemy) -> bool {
    forward := rl.Vector3Normalize(gs.camera.target - gs.camera.position)
    to_e    := enemy.pos - gs.camera.position
    d       := rl.Vector3Length(to_e)
    if d < 0.0001 do return true
    cos_a := rl.Vector3DotProduct(forward, to_e / d)
    //widen by aspect so edge-of-screen targets still count as on-screen.
    half_h := math.to_radians(gs.camera.fovy) * 0.5 * (gs.c_screen.x / gs.c_screen.y)
    return cos_a >= math.cos(half_h)
}

on_run_end :: proc(gs: ^Game_State) {
    gs.run_active = false
    rl.EnableCursor()
    if gs.cur_seed != nil {
        delete(gs.cur_seed)
        gs.cur_seed = nil
    }
    free_run_levels(&gs.levels)
}

draw_crosshair :: proc(gs: Game_State) {
    size    :: 8
    gap     :: 2
    thick   :: 2
    moving  := linalg.length(gs.player.velocity) > MOVEMENT_THRESHOLD
    spread  := gs.mode == .Tactical && moving

    if spread {
        //left
        rl.DrawLineEx({gs.c_screen.x - size, gs.c_screen.y}, {gs.c_screen.x - gap, gs.c_screen.y}, thick, rl.BLACK)
        //right
        rl.DrawLineEx({gs.c_screen.x + size, gs.c_screen.y}, {gs.c_screen.x + gap, gs.c_screen.y}, thick, rl.BLACK)
        //bottom
        rl.DrawLineEx({gs.c_screen.x, gs.c_screen.y + gap}, {gs.c_screen.x, gs.c_screen.y + size}, thick, rl.BLACK)
        //top
        rl.DrawLineEx({gs.c_screen.x, gs.c_screen.y - gap}, {gs.c_screen.x, gs.c_screen.y - size}, thick, rl.BLACK)
    } else {
        //left
        rl.DrawLineEx({gs.c_screen.x - size, gs.c_screen.y}, {gs.c_screen.x - gap, gs.c_screen.y}, thick, rl.GREEN)
        //right
        rl.DrawLineEx({gs.c_screen.x + size, gs.c_screen.y}, {gs.c_screen.x + gap, gs.c_screen.y}, thick, rl.GREEN)
        //bottom
        rl.DrawLineEx({gs.c_screen.x, gs.c_screen.y + gap}, {gs.c_screen.x, gs.c_screen.y + size}, thick, rl.GREEN)
        //top
        rl.DrawLineEx({gs.c_screen.x, gs.c_screen.y - gap}, {gs.c_screen.x, gs.c_screen.y - size}, thick, rl.GREEN)
    }
}

draw_timer :: proc(gs: Game_State) {
    seconds     := f32(gs.rem_time) / 1000.0
    label       := fmt.ctprintf("%.2f", seconds)    //.2f for 2 decimals

    font_size   := i32(48)
    ref_w       := rl.MeasureText("00.00", font_size)
    x           := (i32(gs.c_screen.x*2) - ref_w) / 2
    y           := i32(gs.c_screen.y - (gs.c_screen.y * 0.80))

    // Color shifts to red when low
    color := rl.WHITE
    switch {
    case gs.rem_time <= 5000:  color = rl.RED
    case gs.rem_time <= 15000: color = rl.YELLOW
    }

    rl.DrawText(label, x, y, font_size, color)
}

draw_screen :: proc(gs: Game_State) {
    draw_crosshair(gs)
    draw_timer(gs)
    draw_metrics(gs)
}

//handling async state transitions
drain_pending :: proc(gs: ^Game_State) {
    if gs.pending_submit == INVALID_HANDLE do return

    r := poll_submission(gs.pending_submit)
    if r.status == .In_Flight do return

    if r.status != .Success {
        fmt.eprintfln("[GAME] submit failed: op=%v status=%v http=%d %s",
            gs.pending_op, r.status, r.http_status, r.error)
    }
    release_submission(gs.pending_submit)
    gs.pending_submit = INVALID_HANDLE

    completed_op := gs.pending_op
    gs.pending_op = .None

    // chain: a level submit on a terminal phase triggers finish
    if completed_op == .Level_Submit &&
       (gs.phase == .Run_Complete || gs.phase == .Run_Failed) {
        req := Finish_Run_Request{ outcome = gs.finish_outcome }
        body := marshal_finish_req(req)
        path := fmt.aprintf("/api/runs/%s/finish", gs.run_uuid)
        defer delete(path)
        gs.pending_submit = net_post_async(path, body)
        gs.pending_op     = .Finish_Submit
    }
}
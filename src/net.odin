package game

/*
    net.odin — shared wire-format types, JSON marshaling, and helpers used
    by both native and web builds.
*/

import "core:fmt"
import "core:encoding/json"

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

SERVER_BASE_URL :: "http://localhost:4000"

// ---------------------------------------------------------------------------
// Wire format — must match the Go server's json tags. Field names are kept
// snake_case to match the server side directly.
// ---------------------------------------------------------------------------

// POST /api/runs/start — request body
Start_Run_Request :: struct {
    client_version          : string,
    client_uuid             : string,
    screen_width            : i32,
    screen_height           : i32,
    total_levels            : i16,
    game_mode               : string,
}

// Current level as the server returns it inside Start_Run_Response
Server_Level_JSON :: struct {
    level_id                : i16,
    definition              : Level_JSON,
    enemy_spawn_indices     : []i16,
}

// POST /api/runs/start — response body
Start_Run_Response :: struct {
    run_uuid                : string,
    seed                    : string,
    started_at              : string,
    starting_gametime_ms    : i32,
    total_enemies           : i16,
    levels                  : []Server_Level_JSON,
}

Hit_Event :: struct {
    hit_index               : i16,
    enemy_id                : i16,
    time_ms                 : i32,
    gametime_at_hit_ms      : i32,
    player_x                : f32,
    player_y                : f32,
    player_z                : f32,
    view_yaw                : f32,
    view_pitch              : f32,
    enemy_center_x          : f32,
    enemy_center_y          : f32,
    enemy_center_z          : f32,
    hit_x                   : f32,
    hit_y                   : f32,
    hit_z                   : f32,
    distance_from_center    : f32,
    accuracy_bucket         : i16,
    gametime_awarded_ms     : i32,
    tac_spread              : bool,
}

// POST /api/runs/{uuid}/levels — request body. hits is fixed-size per level
// at submit time, so a slice rather than a [dynamic] array.
Submit_Level_Request :: struct {
    level_index             : i16,
    level_id                : i16,
    duration_ms             : i32,
    gametime_entering_ms    : i32,
    gametime_gained_ms      : i32,
    gametime_lost_ms        : i32,
    gametime_exiting_ms     : i32,
    enemies_total           : i16,
    enemies_hit             : i16,
    completed               : bool,
    hits                    : []Hit_Event,
}

Submit_Level_Response :: struct {
    run_level_id            : i64,
    hits_accepted           : i64,
}

// POST /api/runs/{uuid}/finish — request body
Finish_Run_Request :: struct {
    outcome                 : string,
    levels_completed        : i16,
    total_gametime_gained_ms: i32,
    total_gametime_lost_ms  : i32,
    final_gametime_ms       : i32,
    total_hits              : i16,
    center_hits             : i16,
    close_hits              : i16,
    edge_hits               : i16,
}

Finish_Run_Response :: struct {
    status                  : string,
}

// Generic error body the server may return
Server_Error_Response :: struct {
    error                   : string,
}

// this is the big one
build_level_req :: proc(gs: ^Game_State, completed: bool, time: f64) -> Submit_Level_Request {
    events := make([]Hit_Event, len(gs.level.hits), context.temp_allocator)
    for h, i in gs.level.hits {
        events[i] = Hit_Event{
            hit_index            = h.hit_id,
            enemy_id             = h.enemy_id,
            time_ms              = h.time_ms,
            gametime_at_hit_ms   = h.gametime_ms,
            player_x             = h.p_pos.x,
            player_y             = h.p_pos.y,
            player_z             = h.p_pos.z,
            view_yaw             = h.p_yaw,
            view_pitch           = h.p_pitch,
            enemy_center_x       = h.enemy_ctr.x,
            enemy_center_y       = h.enemy_ctr.y,
            enemy_center_z       = h.enemy_ctr.z,
            hit_x                = h.hit_point.x,
            hit_y                = h.hit_point.y,
            hit_z                = h.hit_point.z,
            distance_from_center = h.dist_ctr,
            accuracy_bucket      = h.accuracy,
            gametime_awarded_ms  = h.add_time,
        }
    }

    // TODO: level_index and level_id works because they play in order
    // if order ever changes this needs to change
    return Submit_Level_Request{
        level_index          = i16(gs.cur_level - 1),
        level_id             = i16(gs.cur_level),
        duration_ms          = i32((time - gs.level.start_time) * 1000),
        gametime_entering_ms = gs.level.begin_time,
        gametime_gained_ms   = gs.level.time_gain,
        gametime_lost_ms     = gs.level.time_lost,
        gametime_exiting_ms  = gs.rem_time,
        enemies_total        = i16(len(gs.level.enemies)),
        enemies_hit          = i16(len(gs.level.hits)),
        completed            = completed,
        hits                 = events,
    }
}

// Move request to HEAP memory so free_all(context.temp_allocator) doesn't
// kill it for the async layer.
marshal_level_req :: proc(req: Submit_Level_Request) -> []u8 {
    body, err := json.marshal(req) // default allocator = heap
    if err != nil {
        return nil
    }
    return body
}

marshal_finish_req :: proc(req: Finish_Run_Request) -> []u8 {
    body, err := json.marshal(req)
    if err != nil {
        return nil
    }
    return body
}

// ---------------------------------------------------------------------------
// Helpers — pure, target-independent
// ---------------------------------------------------------------------------

is_valid_uuid :: proc(s: string) -> bool {
    if len(s) != 36 do return false

    for i in 0 ..< 36 {
        ch := s[i]
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if ch != '-' do return false
        } else {
            if !is_hex_digit(ch) do return false
        }
    }
    return true
}

is_hex_digit :: proc(ch: u8) -> bool {
    return (ch >= '0' && ch <= '9') ||
           (ch >= 'a' && ch <= 'f') ||
           (ch >= 'A' && ch <= 'F')
}

log_server_error :: proc(caller: string, status: int, response: []u8) {
    err_resp: Server_Error_Response
    if json.unmarshal(response, &err_resp) == nil && err_resp.error != "" {
        fmt.eprintfln("[NET] %s: server returned %d — %s", caller, status, err_resp.error)
    } else {
        fmt.eprintfln("[NET] %s: unexpected status %d", caller, status)
    }
}
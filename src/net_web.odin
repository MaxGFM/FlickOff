#+build wasm32, wasm64p32

package game

/*
    net_web.odin — web networking via the JS fetch bridge (net.js).
*/

import "core:fmt"
import "core:encoding/json"
import "core:encoding/hex"
import "core:strings"

// ---------------------------------------------------------------------------
// JS bridge — foreign imports provided by net.js via Emscripten env
// ---------------------------------------------------------------------------

@(default_calling_convention = "c")
foreign {
    js_http_post        :: proc(url_ptr: [^]u8, url_len: i32, body_ptr: [^]u8, body_len: i32) -> i32 ---
    js_poll_request     :: proc(request_id: i32) -> i32 ---
    js_get_http_status  :: proc(request_id: i32) -> i32 ---
    js_get_response_len :: proc(request_id: i32) -> i32 ---
    js_copy_response    :: proc(request_id: i32, out_ptr: [^]u8) ---
    js_free_request     :: proc(request_id: i32) ---
}

// Poll status codes — must match net.js constants
JS_POLL_PENDING  :: 0
JS_POLL_DONE_OK  :: 1
JS_POLL_DONE_ERR :: 2

// ---------------------------------------------------------------------------
// Module state — tracks the in-flight start_run request
// ---------------------------------------------------------------------------

@(private="file")
Web_Net_State :: struct {
    start_run_request_id: i32,  // 0 = no request in flight
}

@(private="file")
wns: Web_Net_State

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

net_init :: proc() {
    wns = Web_Net_State{}
    fmt.println("[NET] web bridge initialized")
}

net_shutdown :: proc() {
    if wns.start_run_request_id > 0 {
        js_free_request(wns.start_run_request_id)
        wns.start_run_request_id = 0
    }
    fmt.println("[NET] web bridge shut down")
}

// ---------------------------------------------------------------------------
// Start run — fire-and-forget, polled from game loop
// ---------------------------------------------------------------------------

// Fires the start_run request asynchronously. Always returns ok=false.
// The actual response is retrieved by net_poll_start_run() each frame.
@(require_results)
net_start_run :: proc(mode: Game_Mode) -> (uuid: string, seed: []u8, ok: bool, gametime: i32, levels: []Run_Level) {
    modes := [Game_Mode]string {
        .Normal   = "normal",
        .Tactical = "tactical",
    }
    req := Start_Run_Request{
        client_version = "dev-0.1",
        client_uuid    = "2724dd46-829e-49ad-9cf8-7375e30b8048",
        screen_width   = 1280,
        screen_height  = 720,
        total_levels   = 2,
        game_mode      = modes[mode],
    }

    body, marshal_err := json.marshal(req, allocator = context.temp_allocator)
    if marshal_err != nil {
        fmt.eprintfln("[NET] start_run: marshal failed: %v", marshal_err)
        return "", nil, false, 0, nil
    }

    // Relative URL — same origin, no CORS needed
    url := "/api/runs/start"

    wns.start_run_request_id = js_http_post(
        raw_data(url), i32(len(url)),
        raw_data(body), i32(len(body)),
    )
    fmt.printfln("[NET] start_run: fired request id=%d", wns.start_run_request_id)

    return "", nil, false, 0, nil
}

// ---------------------------------------------------------------------------
// Poll start run — called each frame from .Start phase until done
// ---------------------------------------------------------------------------

// Returns done=true when the request has completed (success or failure).
// On success, returns the same data as the native net_start_run.
// Caller owns the returned uuid, seed, and levels (heap-allocated).
@(require_results)
net_poll_start_run :: proc() -> (uuid: string, seed: []u8, ok: bool, gametime: i32, levels: []Run_Level, done: bool) {
    if wns.start_run_request_id <= 0 {
        // No request was fired (marshal failed in net_start_run)
        return "", nil, false, 0, nil, true
    }

    status := js_poll_request(wns.start_run_request_id)
    if status == JS_POLL_PENDING {
        return "", nil, false, 0, nil, false  // still waiting
    }

    // Request completed — read the response
    defer {
        js_free_request(wns.start_run_request_id)
        wns.start_run_request_id = 0
    }

    http_status := int(js_get_http_status(wns.start_run_request_id))
    resp_len    := int(js_get_response_len(wns.start_run_request_id))

    if status == JS_POLL_DONE_ERR && http_status == 0 {
        fmt.eprintln("[NET] start_run: network error (fetch failed)")
        return "", nil, false, 0, nil, true
    }

    if resp_len == 0 {
        fmt.eprintfln("[NET] start_run: empty response, http=%d", http_status)
        return "", nil, false, 0, nil, true
    }

    // Copy response bytes from JS into WASM memory
    response := make([]u8, resp_len, context.temp_allocator)
    js_copy_response(wns.start_run_request_id, raw_data(response))

    if http_status != 201 {
        log_server_error("start_run", http_status, response)
        return "", nil, false, 0, nil, true
    }

    // Parse the JSON response — same logic as native net_start_run
    resp: Start_Run_Response
    if err := json.unmarshal(response, &resp, .JSON, context.temp_allocator); err != nil {
        fmt.eprintfln("[NET] start_run: failed to parse response: %v", err)
        return "", nil, false, 0, nil, true
    }

    if !is_valid_uuid(resp.run_uuid) {
        fmt.eprintfln("[NET] start_run: server returned invalid UUID: %s", resp.run_uuid)
        return "", nil, false, 0, nil, true
    }

    seed_bytes, decoded := hex.decode(transmute([]u8)resp.seed)
    if !decoded {
        fmt.eprintln("[NET] start_run: seed hex decode failed")
        return "", nil, false, 0, nil, true
    }

    if len(resp.levels) == 0 {
        fmt.eprintln("[NET] start_run: server returned 0 levels")
        delete(seed_bytes)
        return "", nil, false, 0, nil, true
    }

    out_levels := make([]Run_Level, len(resp.levels))
    for sl, i in resp.levels {
        idxs := make([]i16, len(sl.enemy_spawn_indices))
        copy(idxs, sl.enemy_spawn_indices)
        out_levels[i] = Run_Level{
            level_id            = sl.level_id,
            definition          = level_def_from_json(sl.definition),
            enemy_spawn_indices = idxs,
        }
    }

    fmt.printfln("[NET] start_run: success — uuid=%s levels=%d", resp.run_uuid, len(out_levels))
    return strings.clone(resp.run_uuid), seed_bytes, true, resp.starting_gametime_ms, out_levels, true
}
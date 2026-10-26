#+build !wasm32
#+build !wasm64p32

package game

/*
    net_desktop.odin — HTTP client backed by libcurl.
*/

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:encoding/hex"
import curl "vendor:curl"

// ---------------------------------------------------------------------------
// Native-only constants
// ---------------------------------------------------------------------------

MAX_RESPONSE_BYTES :: 1_048_576 // 1MB cap
NET_TIMEOUT_SECS   :: 5         // Max seconds for the entire request
NET_CONNECT_SECS   :: 3         // Max seconds to establish TCP connection

// ---------------------------------------------------------------------------
// Response buffering — written to by libcurl from the worker thread.
// ---------------------------------------------------------------------------

Response_Buffer :: struct {
    data        : [dynamic]u8,
    overflow    : bool,
}

// Called by libcurl as data arrives. Appends to buffer with a size cap.
write_callback :: proc "c" (ptr: [^]u8, size: uint, nmemb: uint, userdata: rawptr) -> uint {
    context = runtime.default_context()

    total := int(size * nmemb)
    buf := cast(^Response_Buffer)userdata

    if len(buf.data) + total > MAX_RESPONSE_BYTES {
        buf.overflow = true
        return 0
    }

    for i in 0 ..< total {
        append(&buf.data, ptr[i])
    }
    return size * nmemb
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

Net_State :: struct {
    initialized : bool,
}

net_state: Net_State

net_init :: proc() {
    curl.global_init(curl.GLOBAL_DEFAULT)
    net_state.initialized = true
    fmt.println("[NET] curl initialized")
}

net_shutdown :: proc() {
    if net_state.initialized {
        curl.global_cleanup()
        net_state.initialized = false
        fmt.println("[NET] curl shut down")
    }
}

// ---------------------------------------------------------------------------
// HTTP transport
// ---------------------------------------------------------------------------

// POST marshaled JSON to a URL. Returns (response_bytes, http_status, success).
// Caller owns the returned response slice and must delete it.
@(require_results)
http_post_json :: proc(url: string, body: []u8) -> (response: []u8, status: int, ok: bool) {
    handle := curl.easy_init()
    if handle == nil {
        fmt.eprintln("[NET] curl_easy_init failed")
        return nil, 0, false
    }
    defer curl.easy_cleanup(handle)

    url_c := strings.clone_to_cstring(url, context.temp_allocator)
    curl.easy_setopt(handle, .URL, url_c)

    curl.easy_setopt(handle, .TIMEOUT,        i64(NET_TIMEOUT_SECS))
    curl.easy_setopt(handle, .CONNECTTIMEOUT, i64(NET_CONNECT_SECS))

    curl.easy_setopt(handle, .POST,           i64(1))
    curl.easy_setopt(handle, .POSTFIELDS,     raw_data(body))
    curl.easy_setopt(handle, .POSTFIELDSIZE,  i64(len(body)))

    headers: ^curl.slist = nil
    headers = curl.slist_append(headers, "Content-Type: application/json")
    headers = curl.slist_append(headers, "Accept: application/json")
    defer curl.slist_free_all(headers)
    curl.easy_setopt(handle, .HTTPHEADER, headers)

    response_buf := Response_Buffer{ data = make([dynamic]u8) }
    defer delete(response_buf.data)

    curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
    curl.easy_setopt(handle, .WRITEDATA,     &response_buf)

    res := curl.easy_perform(handle)
    if res != .E_OK {
        if response_buf.overflow {
            fmt.eprintln("[NET] response exceeded size limit, aborted")
        } else {
            fmt.eprintfln("[NET] request failed: %s", curl.easy_strerror(res))
        }
        return nil, 0, false
    }

    http_code: i64 = 0
    curl.easy_getinfo(handle, .RESPONSE_CODE, &http_code)

    result := make([]u8, len(response_buf.data))
    copy(result, response_buf.data[:])

    return result, int(http_code), true
}

// ---------------------------------------------------------------------------
// Game-specific endpoints
// ---------------------------------------------------------------------------

// Returned `levels` is heap-allocated.
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

    url := fmt.tprintf("%s/api/runs/start", SERVER_BASE_URL)

    response, status, success := http_post_json(url, body)
    if !success {
        fmt.eprintln("[NET] start_run: request failed")
        return "", nil, false, 0, nil
    }
    defer delete(response)

    if status != 201 {
        log_server_error("start_run", status, response)
        return "", nil, false, 0, nil
    }

    resp: Start_Run_Response
    if err := json.unmarshal(response, &resp, .JSON, context.temp_allocator); err != nil {
        fmt.eprintfln("[NET] start_run: failed to parse response: %v", err)
        return "", nil, false, 0, nil
    }

    if !is_valid_uuid(resp.run_uuid) {
        fmt.eprintfln("[NET] start_run: server returned invalid UUID: %s", resp.run_uuid)
        return "", nil, false, 0, nil
    }

    seed_bytes, decoded := hex.decode(transmute([]u8)resp.seed)
    if !decoded {
        fmt.eprintfln("[NET] start_run: seed hex decode failed")
        return "", nil, false, 0, nil
    }

    if len(resp.levels) == 0 {
        fmt.eprintln("[NET] start_run: server returned 0 levels")
        delete(seed_bytes)
        return "", nil, false, 0, nil
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

    return strings.clone(resp.run_uuid), seed_bytes, true, resp.starting_gametime_ms, out_levels
}

// Native no-op: Returns done=true immediately so the game loop's poll check passes.
@(require_results)
net_poll_start_run :: proc() -> (uuid: string, seed: []u8, ok: bool, gametime: i32, levels: []Run_Level, done: bool) {
    return "", nil, false, 0, nil, true
}
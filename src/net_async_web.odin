#+build wasm32, wasm64p32

package game

/*
    net_async_web.odin — non-blocking submission API for the browser.

    The browser is single-threaded, so we just fire fetch() via the JS 
    bridge and poll the request status each frame.

    Slot pool design mirrors the native version for consistency:
    - Fixed array of slots, each holding one in-flight request.
    - Handle encodes (generation, slot index) to detect stale references.
    - Caller owns body bytes; we free them after firing the fetch.
*/

import "core:fmt"
import "core:strings"
import "core:encoding/json"

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

WEB_ASYNC_SLOTS :: 8

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

@(private="file")
Web_Job_State :: enum u8 {
    Idle,
    Pending,   // fetch in flight
    Done,      // response arrived, result published
}

@(private="file")
Web_Job_Slot :: struct {
    in_use:     bool,
    generation: u32,
    request_id: i32,            // JS-side request id from js_http_post
    state:      Web_Job_State,
    result:     Submit_Result,
}

@(private="file")
Web_Async_State :: struct {
    slots:          [WEB_ASYNC_SLOTS]Web_Job_Slot,
    jobs_submitted: int,
    jobs_completed: int,
    jobs_failed:    int,
}

@(private="file")
wa: Web_Async_State

// ---------------------------------------------------------------------------
// Handle encoding — same scheme as native
// ---------------------------------------------------------------------------

@(private="file")
encode_handle :: proc(slot: int, gen: u32) -> Submit_Handle {
    return Submit_Handle((u64(gen) << 32) | u64(slot + 1))
}

@(private="file")
decode_handle :: proc(h: Submit_Handle) -> (slot: int, gen: u32, ok: bool) {
    if h == INVALID_HANDLE do return 0, 0, false
    raw := u64(h)
    idx := int(raw & 0xFFFF_FFFF)
    if idx == 0 || idx > WEB_ASYNC_SLOTS do return 0, 0, false
    return idx - 1, u32(raw >> 32), true
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

net_async_init :: proc() {
    wa = Web_Async_State{}
    fmt.println("[NET-ASYNC] web initialized")
}

net_async_shutdown :: proc() {
    leaked := 0
    for &slot in wa.slots {
        if slot.in_use {
            if slot.request_id > 0 {
                js_free_request(slot.request_id)
            }
            if slot.result.error != "" {
                delete(slot.result.error)
            }
            leaked += 1
        }
        slot = Web_Job_Slot{}
    }
    fmt.printfln(
        "[NET-ASYNC] web shutdown (submitted=%d completed=%d failed=%d unreleased=%d)",
        wa.jobs_submitted, wa.jobs_completed, wa.jobs_failed, leaked,
    )
}

// ---------------------------------------------------------------------------
// Submission
// ---------------------------------------------------------------------------

// Takes ownership of body (frees it after firing the request).
// path is cloned internally — caller's storage can die immediately.
net_post_async :: proc(path: string, body: []u8) -> Submit_Handle {
    if body == nil {
        return INVALID_HANDLE
    }

    // Find a free slot
    slot_idx := -1
    for i in 0 ..< WEB_ASYNC_SLOTS {
        if !wa.slots[i].in_use {
            slot_idx = i
            break
        }
    }
    if slot_idx < 0 {
        delete(body)
        fmt.eprintln("[NET-ASYNC] web: no slots available")
        return INVALID_HANDLE
    }

    // Build the full relative URL and fire the fetch via JS bridge
    url := path
    request_id := js_http_post(
        raw_data(url),  i32(len(url)),
        raw_data(body), i32(len(body)),
    )

    // Body bytes have been copied by JS (wasmBytes makes a copy), safe to free
    delete(body)

    slot := &wa.slots[slot_idx]
    slot.in_use     = true
    slot.generation += 1
    slot.request_id = request_id
    slot.state      = .Pending
    slot.result     = Submit_Result{ status = .In_Flight }

    wa.jobs_submitted += 1

    h := encode_handle(slot_idx, slot.generation)
    fmt.printfln("[NET-ASYNC] web: handle=%v path=%s js_id=%d", h, path, request_id)
    return h
}

// ---------------------------------------------------------------------------
// Polling — checks JS bridge status each frame
// ---------------------------------------------------------------------------

poll_submission :: proc(h: Submit_Handle) -> Submit_Result {
    slot_idx, gen, ok := decode_handle(h)
    if !ok {
        return Submit_Result{ status = .Network_Err, error = "invalid handle" }
    }

    slot := &wa.slots[slot_idx]
    if !slot.in_use || slot.generation != gen {
        return Submit_Result{ status = .Network_Err, error = "stale handle" }
    }

    // If already done, return cached result
    if slot.state == .Done {
        return slot.result
    }

    // Poll the JS bridge
    js_status := js_poll_request(slot.request_id)
    if js_status == JS_POLL_PENDING {
        return Submit_Result{ status = .In_Flight }
    }

    // Request completed — build the result
    http_status := int(js_get_http_status(slot.request_id))
    res: Submit_Result

    if js_status == JS_POLL_DONE_OK {
        res.status      = .Success
        res.http_status = http_status
        wa.jobs_completed += 1
    } else if http_status == 0 {
        res.status = .Network_Err
        res.error  = strings.clone("fetch failed (network error)")
        wa.jobs_failed += 1
    } else {
        res.status      = .Server_Err
        res.http_status = http_status
        wa.jobs_failed += 1

        // Try to extract error message from response body
        resp_len := int(js_get_response_len(slot.request_id))
        if resp_len > 0 {
            response := make([]u8, resp_len, context.temp_allocator)
            js_copy_response(slot.request_id, raw_data(response))
            err_resp: Server_Error_Response
            if json.unmarshal(response, &err_resp) == nil && err_resp.error != "" {
                res.error = strings.clone(err_resp.error)
            }
        }
    }

    // Cache result and release the JS request
    slot.state  = .Done
    slot.result = res
    js_free_request(slot.request_id)
    slot.request_id = 0

    fmt.printfln("[NET-ASYNC] web: slot %d done — status=%v http=%d", slot_idx, res.status, res.http_status)
    return res
}

// ---------------------------------------------------------------------------
// Release
// ---------------------------------------------------------------------------

release_submission :: proc(h: Submit_Handle) {
    slot_idx, gen, ok := decode_handle(h)
    if !ok do return

    slot := &wa.slots[slot_idx]
    if !slot.in_use || slot.generation != gen do return

    if slot.state != .Done {
        fmt.eprintfln("[NET-ASYNC] web: release called on non-Done handle %v", h)
        return
    }

    // Clean up any heap-allocated error string
    if slot.result.error != "" {
        delete(slot.result.error)
        slot.result.error = ""
    }

    // Release the JS request if not already freed
    if slot.request_id > 0 {
        js_free_request(slot.request_id)
        slot.request_id = 0
    }

    slot.in_use = false
    slot.state  = .Idle
}

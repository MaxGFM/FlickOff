#+build !wasm32
#+build !wasm64p32

package game

/*
    net_async_native.odin — non-blocking submission API (worker-thread impl).

    Architecture:
    - A pool of NET_ASYNC_SLOTS slots, each holding one in-flight job.
    - A ring-buffer queue of slot indices the worker pops from.
    - One mutex protects everything (slots + queue + counters + shutdown flag).
    - One condition variable wakes the worker when work is queued or shutdown
      is requested.
    - Exactly one worker thread.

    Threading model:
    - MAIN THREAD (game loop):
        net_post_async    — acquires slot, pushes to queue, signals worker
        poll_submission   — reads slot result (cheap)
        release_submission — frees slot
    - WORKER THREAD:
        worker_proc — pops index from queue, runs http_post_json (no lock
                      held during the network call), writes result, marks
                      slot as Done.

    Lifetime rules:
    - body bytes passed to net_post_async: ownership transfers to async layer.
      Worker frees after http_post_json returns. On any failure path that
      doesn't queue the job (shutdown, full slots), the async layer frees.
    - path: net_post_async clones it internally; caller's storage can die
      immediately after the call returns.
    - result.error in Submit_Result: heap-allocated by worker, owned by the
      slot, freed by release_submission.

    Spurious wakeup note:
    - sync.cond_wait can return without anyone calling cond_signal/broadcast.
      The worker's wait loop re-checks (queue_count == 0 && !shutdown) on
      every wake-up, so a spurious wakeup just goes back to sleep.
*/

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:encoding/json"

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

NET_ASYNC_SLOTS  :: 8
QUEUE_SIZE       :: 8                     // must be >= NET_ASYNC_SLOTS, power of 2
QUEUE_MASK       :: QUEUE_SIZE - 1
SHUTDOWN_TIMEOUT :: 3 * time.Second

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

@(private="file")
Job_State :: enum u8 {
    Idle,     // slot is unused (in_use == false)
    Pending,  // queued or running, worker has not finished
    Done,     // result is published, ready for poll_submission
}

@(private="file")
Job_Slot :: struct {
    in_use:     bool,
    generation: u32,
    state:      Job_State,
    path:       string,
    body:       []u8,
    result:     Submit_Result,
}

@(private="file")
Net_Async_State :: struct {
    mu:   sync.Mutex,
    cond: sync.Cond,

    slots: [NET_ASYNC_SLOTS]Job_Slot,

    queue:       [QUEUE_SIZE]int,
    queue_head:  int,
    queue_tail:  int,
    queue_count: int,

    shutdown: bool,
    worker:   ^thread.Thread,

    jobs_submitted: int,
    jobs_completed: int,
    jobs_failed:    int,
}

@(private="file")
g: Net_Async_State

// ---------------------------------------------------------------------------
// Handle encoding
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
    if idx == 0 || idx > NET_ASYNC_SLOTS do return 0, 0, false
    return idx - 1, u32(raw >> 32), true
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

@(private="file")
worker_proc :: proc(t: ^thread.Thread) {
    fmt.println("[NET-ASYNC] worker thread started")

    for {
        sync.lock(&g.mu)

        for !g.shutdown && g.queue_count == 0 {
            sync.cond_wait(&g.cond, &g.mu)
        }

        if g.shutdown && g.queue_count == 0 {
            sync.unlock(&g.mu)
            runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
            fmt.println("[NET-ASYNC] worker thread exiting")
            return
        }

        idx := g.queue[g.queue_head]
        g.queue_head = (g.queue_head + 1) & QUEUE_MASK
        g.queue_count -= 1

        path := g.slots[idx].path
        body := g.slots[idx].body
        g.slots[idx].path = ""
        g.slots[idx].body = nil

        sync.unlock(&g.mu)

        // ------------ Network call (no lock held) -------------------------
        t_start := time.tick_now()
        url := fmt.aprintf("%s%s", SERVER_BASE_URL, path)
        response, http_status, ok := http_post_json(url, body)
        elapsed_ms := f64(time.tick_diff(t_start, time.tick_now())) / f64(time.Millisecond)
        fmt.printfln("[NET-ASYNC] %s -> %d in %.2f ms", path, http_status, elapsed_ms)

        res: Submit_Result
        if !ok {
            res.status = .Network_Err
            res.error  = strings.clone("request failed (timeout, DNS, or connection error)")
        } else if http_status >= 200 && http_status < 300 {
            res.status      = .Success
            res.http_status = http_status
        } else {
            res.status      = .Server_Err
            res.http_status = http_status
            if response != nil {
                err_resp: Server_Error_Response
                if json.unmarshal(response, &err_resp) == nil && err_resp.error != "" {
                    res.error = strings.clone(err_resp.error)
                }
            }
        }

        delete(url)
        delete(path)
        delete(body)
        if response != nil do delete(response)

        // ------------ Publish result --------------------------------------
        sync.lock(&g.mu)
        g.slots[idx].state  = .Done
        g.slots[idx].result = res
        if res.status == .Success {
            g.jobs_completed += 1
        } else {
            g.jobs_failed += 1
        }
        sync.unlock(&g.mu)

        free_all(context.temp_allocator)
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

net_async_init :: proc() {
    g = Net_Async_State{}

    g.worker = thread.create(worker_proc)
    if g.worker == nil {
        fmt.eprintln("[NET-ASYNC] failed to create worker thread")
        return
    }
    g.worker.init_context = context
    thread.start(g.worker)
    fmt.println("[NET-ASYNC] initialized")
}

net_async_shutdown :: proc() {
    if g.worker == nil do return

    shutdown_start := time.tick_now()

    sync.lock(&g.mu)
    g.shutdown = true
    sync.unlock(&g.mu)
    sync.cond_broadcast(&g.cond)

    forced := false
    for !thread.is_done(g.worker) {
        if time.tick_diff(shutdown_start, time.tick_now()) > SHUTDOWN_TIMEOUT {
            fmt.eprintln("[NET-ASYNC] shutdown timeout exceeded — terminating worker")
            thread.terminate(g.worker, 1)
            forced = true
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    thread.destroy(g.worker)
    g.worker = nil

    elapsed_ms := f64(time.tick_diff(shutdown_start, time.tick_now())) / f64(time.Millisecond)

    leaked := 0
    for &slot in g.slots {
        if slot.in_use {
            if slot.path != ""         do delete(slot.path)
            if slot.body != nil        do delete(slot.body)
            if slot.result.error != "" do delete(slot.result.error)
            leaked += 1
        }
        slot = Job_Slot{}
    }

    fmt.printfln(
        "[NET-ASYNC] drained in %.2f ms (submitted=%d completed=%d failed=%d unreleased=%d forced=%v)",
        elapsed_ms,
        g.jobs_submitted,
        g.jobs_completed,
        g.jobs_failed,
        leaked,
        forced,
    )
}

// ---------------------------------------------------------------------------
// Submission
// ---------------------------------------------------------------------------

net_post_async :: proc(path: string, body: []u8) -> Submit_Handle {
    if body == nil {
        return INVALID_HANDLE
    }

    sync.lock(&g.mu)

    if g.shutdown {
        sync.unlock(&g.mu)
        delete(body)
        fmt.eprintln("[NET-ASYNC] net_post_async: refusing — shutdown in progress")
        return INVALID_HANDLE
    }

    slot := -1
    for i in 0 ..< NET_ASYNC_SLOTS {
        if !g.slots[i].in_use {
            slot = i
            break
        }
    }
    if slot < 0 {
        sync.unlock(&g.mu)
        delete(body)
        fmt.eprintln("[NET-ASYNC] net_post_async: no slots available")
        return INVALID_HANDLE
    }

    g.slots[slot].in_use     = true
    g.slots[slot].generation += 1
    g.slots[slot].state      = .Pending
    g.slots[slot].path       = strings.clone(path)
    g.slots[slot].body       = body
    g.slots[slot].result     = Submit_Result{ status = .In_Flight }

    g.queue[g.queue_tail] = slot
    g.queue_tail = (g.queue_tail + 1) & QUEUE_MASK
    g.queue_count += 1

    g.jobs_submitted += 1

    h := encode_handle(slot, g.slots[slot].generation)

    sync.unlock(&g.mu)
    sync.cond_signal(&g.cond)

    fmt.printfln("[NET-ASYNC] net_post_async: handle=%v path=%s", h, path)
    return h
}

// ---------------------------------------------------------------------------
// Polling and release
// ---------------------------------------------------------------------------

poll_submission :: proc(h: Submit_Handle) -> Submit_Result {
    slot, gen, ok := decode_handle(h)
    if !ok {
        return Submit_Result{ status = .Network_Err, error = "invalid handle" }
    }

    sync.lock(&g.mu)
    defer sync.unlock(&g.mu)

    if !g.slots[slot].in_use || g.slots[slot].generation != gen {
        return Submit_Result{ status = .Network_Err, error = "stale handle" }
    }

    return g.slots[slot].result
}

release_submission :: proc(h: Submit_Handle) {
    slot, gen, ok := decode_handle(h)
    if !ok do return

    sync.lock(&g.mu)
    defer sync.unlock(&g.mu)

    if !g.slots[slot].in_use || g.slots[slot].generation != gen do return

    if g.slots[slot].state != .Done {
        fmt.eprintfln("[NET-ASYNC] release_submission called on non-Done handle %v", h)
        return
    }

    if g.slots[slot].result.error != "" {
        delete(g.slots[slot].result.error)
        g.slots[slot].result.error = ""
    }

    g.slots[slot].in_use = false
    g.slots[slot].state  = .Idle
}
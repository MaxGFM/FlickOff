package game

// metrics.odin:
// input/mouse sample capture buffers, recording lifecycle, and binary blob encoding

import "core:math"

// yaw/pitch are kept on the sample (the schema's resolved camera state). 
// They are resolved at append time by integrating dx/dy, re-seeded each
// frame from the authoritative player camera to avoid drift.
Mouse_Sample :: struct {
    sample_index : i32,
    time_ms      : i32,   // ms since level start (rebased against level_t0_ms)
    dx           : f32,   // raw delta (biometric signal)
    dy           : f32,
    yaw          : f32,   // resolved camera state at this sample
    pitch        : f32,
}

Input_Event :: struct {
    event_index : i32,
    time_ms     : i32,
    event_type  : u8,     // 0=key_down 1=key_up 2=mouse_down 3=mouse_up
    key_code    : u8,     // semantic action code (see input.js)
    synthetic   : bool,
}

// ---------------------------------------------------------------------------
// Buffers + lifecycle state (package-level; one level's worth at a time).
// ---------------------------------------------------------------------------
mouse_samples    : [dynamic]Mouse_Sample
input_events     : [dynamic]Input_Event
recording_active : bool
pointer_locked   : bool
level_t0_ms      : f64    // now_ms() captured at level start; rebases samples

// Running camera integrator for per-sample yaw/pitch. Re-seeded each frame
// from the authoritative player camera in metrics_frame_sync().
@(private="file") rec_yaw   : f32
@(private="file") rec_pitch : f32

// Pre-allocation sizing: worst case ~1500Hz (decimation cap) * longest level
// budget (~25s) ~= 38k samples. Round to 40k so we never realloc mid-level.
SAMPLE_CAP :: 40_000
EVENT_CAP  :: 1_024

metrics_init :: proc() {
    mouse_samples = make([dynamic]Mouse_Sample, 0, SAMPLE_CAP)
    input_events  = make([dynamic]Input_Event,  0, EVENT_CAP)
}

metrics_shutdown :: proc() {
    if mouse_samples != nil do delete(mouse_samples)
    if input_events  != nil do delete(input_events)
}

// Call at level start (from load_level), after the player camera is seeded.
level_start_recording :: proc(p: Player) {
    clear(&mouse_samples)
    clear(&input_events)
    level_t0_ms      = now_ms()
    rec_yaw          = p.yaw
    rec_pitch        = p.pitch
    recording_active = true
}

// Call at level end (from on_level_complete / on_level_fail).
level_stop_recording :: proc() {
    recording_active = false
}

// Call once per frame during .Playing, AFTER update_player has set the
// authoritative camera. Re-seeds the sample integrator so per-sample yaw/pitch
// can't drift away from the gameplay camera over the course of a level.
metrics_frame_sync :: proc(p: Player) {
    rec_yaw   = p.yaw
    rec_pitch = p.pitch
}

// ---------------------------------------------------------------------------
// Append paths. Called from main_web exports (web) on each browser event.
// ---------------------------------------------------------------------------
PITCH_LIMIT_REC :: f32(math.PI/2 - 0.01)

record_mouse_sample :: proc(time_ms: f64, dx, dy: f32) {
    if !recording_active do return
    // Integrate using the SAME convention as update_player:
    //   yaw   -= dx * SENSITIVITY ; pitch -= dy * SENSITIVITY (clamped)
    rec_yaw   -= dx * SENSITIVITY
    rec_pitch -= dy * SENSITIVITY
    rec_pitch  = clamp(rec_pitch, -PITCH_LIMIT_REC, PITCH_LIMIT_REC)

    append(&mouse_samples, Mouse_Sample{
        sample_index = i32(len(mouse_samples)),
        time_ms      = i32(time_ms - level_t0_ms),
        dx           = dx,
        dy           = dy,
        yaw          = rec_yaw,
        pitch        = rec_pitch,
    })
}

record_input_event :: proc(time_ms: f64, ev_type, code: u8, synthetic: bool) {
    if !recording_active do return
    append(&input_events, Input_Event{
        event_index = i32(len(input_events)),
        time_ms     = i32(time_ms - level_t0_ms),
        event_type  = ev_type,
        key_code    = code,
        synthetic   = synthetic,
    })
}

// ---------------------------------------------------------------------------
// Binary blob encoding.  (FORMAT IS THE NEXT STEP TO FINALIZE — this is a
// concrete starting point so the path is runnable end-to-end. The Go decoder
// must mirror whatever this emits.)
//
// Layout (little-endian), one contiguous buffer:
//   Header (16 bytes):
//     magic        u32   0x464C4B31 ("FLK1")
//     version      u16   1
//     reserved     u16   0
//     sample_count u32
//     event_count  u32
//   Samples (sample_count * 24 bytes):
//     sample_index u32, time_ms i32, dx f32, dy f32, yaw f32, pitch f32
//   Events (event_count * 12 bytes):
//     event_index u32, time_ms i32, event_type u8, key_code u8,
//     synthetic u8, pad u8
// ---------------------------------------------------------------------------
BLOB_MAGIC   :: u32(0x464C4B31)
BLOB_VERSION :: u16(1)
HEADER_BYTES :: 16
SAMPLE_BYTES :: 24
EVENT_BYTES  :: 12

@(private="file")
put_u32 :: proc(b: []u8, off: int, v: u32) {
    b[off+0] = u8(v)
    b[off+1] = u8(v >> 8)
    b[off+2] = u8(v >> 16)
    b[off+3] = u8(v >> 24)
}
@(private="file")
put_u16 :: proc(b: []u8, off: int, v: u16) {
    b[off+0] = u8(v)
    b[off+1] = u8(v >> 8)
}
@(private="file")
put_f32 :: proc(b: []u8, off: int, v: f32) {
    put_u32(b, off, transmute(u32)v)
}

// Encodes current buffers into a freshly-allocated byte slice (caller owns it
// and must delete it). gzip happens on top of this, client-side, before upload.
encode_blob :: proc(allocator := context.allocator) -> []u8 {
    n_s := len(mouse_samples)
    n_e := len(input_events)
    total := HEADER_BYTES + n_s*SAMPLE_BYTES + n_e*EVENT_BYTES

    buf := make([]u8, total, allocator)

    put_u32(buf, 0,  BLOB_MAGIC)
    put_u16(buf, 4,  BLOB_VERSION)
    put_u16(buf, 6,  0)
    put_u32(buf, 8,  u32(n_s))
    put_u32(buf, 12, u32(n_e))

    off := HEADER_BYTES
    for s in mouse_samples {
        put_u32(buf, off+0,  u32(s.sample_index))
        put_u32(buf, off+4,  u32(s.time_ms))
        put_f32(buf, off+8,  s.dx)
        put_f32(buf, off+12, s.dy)
        put_f32(buf, off+16, s.yaw)
        put_f32(buf, off+20, s.pitch)
        off += SAMPLE_BYTES
    }
    for e in input_events {
        put_u32(buf, off+0, u32(e.event_index))
        put_u32(buf, off+4, u32(e.time_ms))
        buf[off+8]  = e.event_type
        buf[off+9]  = e.key_code
        buf[off+10] = u8(e.synthetic ? 1 : 0)
        buf[off+11] = 0  // pad
        off += EVENT_BYTES
    }
    return buf
}

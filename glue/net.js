// net.js — HTTP bridge between WASM (Odin) and browser fetch() API.
//
// Loaded before Emscripten's script. Functions are merged into the WASM
// "env" imports so Odin can call them via `foreign {}` declarations.
//
// Architecture: request-slot pool polled from the game loop.
//   1. WASM calls js_http_post → JS fires fetch(), returns a request_id
//   2. WASM polls js_poll_request each frame → 0=pending, 1=ok, 2=err
//   3. WASM reads response via js_get_response_len + js_copy_response
//   4. WASM calls js_free_request to release the slot

var netBridge = (function () {
    "use strict";

    var requests = {};
    var nextId = 1;

    // Status codes — must match the Odin constants in net_web.odin
    var PENDING  = 0;
    var DONE_OK  = 1;
    var DONE_ERR = 2;

    // Helper: read a byte range from WASM memory as a string.
    function wasmString(ptr, len) {
        var mem = new Uint8Array(wasmExports.memory.buffer);
        return new TextDecoder().decode(mem.subarray(ptr, ptr + len));
    }

    // Helper: read a byte range from WASM memory as a copy.
    function wasmBytes(ptr, len) {
        var mem = new Uint8Array(wasmExports.memory.buffer);
        return new Uint8Array(mem.subarray(ptr, ptr + len));
    }

    return {
        // Fire a POST request. Returns a request_id (>0).
        // url_ptr/url_len  — pointer+length of the URL string in WASM memory
        // body_ptr/body_len — pointer+length of the JSON body bytes
        js_http_post: function (url_ptr, url_len, body_ptr, body_len) {
            var id  = nextId++;
            var url = wasmString(url_ptr, url_len);
            var body = wasmBytes(body_ptr, body_len);

            requests[id] = { status: PENDING, httpStatus: 0, response: null };

            fetch(url, {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "Accept":       "application/json"
                },
                body: body
            })
            .then(function (resp) {
                return resp.arrayBuffer().then(function (buf) {
                    requests[id].httpStatus = resp.status;
                    requests[id].response   = new Uint8Array(buf);
                    requests[id].status = (resp.status >= 200 && resp.status < 300)
                        ? DONE_OK
                        : DONE_ERR;
                });
            })
            .catch(function (err) {
                console.error("[net.js] fetch error:", err);
                requests[id].status     = DONE_ERR;
                requests[id].httpStatus = 0;
                requests[id].response   = new TextEncoder().encode(
                    JSON.stringify({ error: err.message })
                );
            });

            return id;
        },

        // timestamp in ms for determining level-start for metrics
        js_now_ms: function () { 
            return performance.now();
        },

        // Returns 0 (pending), 1 (success), or 2 (error).
        js_poll_request: function (id) {
            var req = requests[id];
            return req ? req.status : DONE_ERR;
        },

        // HTTP status code (e.g. 200, 201, 404). 0 if network error.
        js_get_http_status: function (id) {
            var req = requests[id];
            return req ? req.httpStatus : 0;
        },

        // Byte length of the response body. 0 if not yet available.
        js_get_response_len: function (id) {
            var req = requests[id];
            return (req && req.response) ? req.response.length : 0;
        },

        // Copy response bytes into WASM memory at out_ptr.
        // Caller must allocate at least js_get_response_len bytes.
        js_copy_response: function (id, out_ptr) {
            var req = requests[id];
            if (!req || !req.response) return;
            var mem = new Uint8Array(wasmExports.memory.buffer);
            mem.set(req.response, out_ptr);
        },

        // Release a completed request slot.
        js_free_request: function (id) {
            delete requests[id];
        }
    };
})();

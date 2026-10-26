// input.js — capture keyboard/mouse events and push them into Odin via wasmExports.
// Loaded before emscripten's script. Listeners are installed AFTER WASM is ready
// so wasmExports is guaranteed to exist by the time any handler fires.

var inputBridge = (function () {
    "use strict";

    var canvas;
    var t0;           // performance.now() at install;
    var keysDown;     // Set of held key codes, for synthetic key-up on blur/lock-loss
    var installed = false;

    var ACTION_MOVE_FORWARD   = 1;
    var ACTION_MOVE_LEFT      = 2;
    var ACTION_MOVE_BACKWARD  = 3;
    var ACTION_MOVE_RIGHT     = 4;
    var ACTION_CONTINUE       = 5; //spacebar
    var ACTION_SHOOT          = 6; //left mouse click

    // ---- Event type codes (must match input_events.event_type CHECK 0..3) ----
    var EV_KEY_DOWN   = 0;
    var EV_KEY_UP     = 1;
    var EV_MOUSE_DOWN = 2;
    var EV_MOUSE_UP   = 3;

    var KEY_ACTION = {
        'KeyW':  ACTION_MOVE_FORWARD,
        'KeyA':  ACTION_MOVE_LEFT,
        'KeyS':  ACTION_MOVE_BACKWARD,
        'KeyD':  ACTION_MOVE_RIGHT,
        'Space': ACTION_CONTINUE,
    };

    // ---- Decimation cap ----
    // Hard ceiling on captured mouse samples per second, independent of mouse
    // polling rate. A 4000Hz mouse would otherwise blow up blob-sizes
    var MAX_SAMPLE_RATE_HZ      = 1500;
    var MIN_SAMPLE_INTERVAL_MS  = 1000 / MAX_SAMPLE_RATE_HZ;
    var lastSampleStamp         = -1;

    function flushHeldKeys() {
        if (typeof wasmExports === "undefined" || !wasmExports) return;
        var t = performance.now() - t0;
        keysDown.forEach(function (action) {
            wasmExports.web_push_input_event(t, EV_KEY_UP, action, 1 /*synthetic*/);
        });
        keysDown.clear();
    }

    return {
      // Call once from onRuntimeInitialized, AFTER e.main_start().
      install: function () {
        if (installed) return;
        installed = true;

        canvas   = document.getElementById('canvas');
        t0       = performance.now();
        keysDown = new Set();

        // ---- Pointer lock (must come from a user gesture) ----
        canvas.addEventListener('click', function () {
            if (document.pointerLockElement !== canvas) {
                canvas.requestPointerLock();
            }
        });
        document.addEventListener('pointerlockchange', function () {
            var locked = document.pointerLockElement === canvas;
            wasmExports.web_pointer_lock_changed(locked ? 1 : 0);
            if (!locked) flushHeldKeys();
        });

        // ---- Mouse movement — high-fidelity via getCoalescedEvents, decimated ----
        document.addEventListener('mousemove', function (e) {
            if (document.pointerLockElement !== canvas) return;
            var events = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
            for (var i = 0; i < events.length; i++) {
                var ev = events[i];
                var stamp = ev.timeStamp - t0;
                if (lastSampleStamp >= 0 &&
                    (stamp - lastSampleStamp) < MIN_SAMPLE_INTERVAL_MS) {
                    continue; // decimate: too soon since last kept sample
                }
                lastSampleStamp = stamp;
                wasmExports.web_push_mouse_sample(stamp, ev.movementX, ev.movementY);
            }
        });

        // ---- Mouse buttons (left = SHOOT) ----
        canvas.addEventListener('mousedown', function (e) {
          if (document.pointerLockElement !== canvas) return;
          if (e.button !== 0) return; // left only
          wasmExports.web_push_input_event(
            e.timeStamp - t0, EV_MOUSE_DOWN, ACTION_SHOOT, 0);
        });
        canvas.addEventListener('mouseup', function (e) {
          if (document.pointerLockElement !== canvas) return;
          if (e.button !== 0) return;
          wasmExports.web_push_input_event(
            e.timeStamp - t0, EV_MOUSE_UP, ACTION_SHOOT, 0);
        });

        // ---- Keyboard ----
        window.addEventListener('keydown', function (e) {
          var action = KEY_ACTION[e.code];
          if (action === undefined) return;
          if (e.repeat) return;          // drop OS auto-repeat
          e.preventDefault();            // stop Space scrolling the page
          keysDown.add(action);
          wasmExports.web_push_input_event(
            e.timeStamp - t0, EV_KEY_DOWN, action, 0);
        });
        window.addEventListener('keyup', function (e) {
          var action = KEY_ACTION[e.code];
          if (action === undefined) return;
          keysDown.delete(action);
          wasmExports.web_push_input_event(
            e.timeStamp - t0, EV_KEY_UP, action, 0);
        });

        // ---- Focus loss — synth key_up for everything still down ----
        window.addEventListener('blur', flushHeldKeys);
      },
      // Reset the decimation clock at a level boundary (optional; Odin rebases
      // time origins itself via now_ms, this just keeps decimation aligned).
      resetSampleClock: function () {
        lastSampleStamp = -1;
      }
    };
})();
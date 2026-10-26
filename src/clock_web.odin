#+build wasm32, wasm64p32
package game
//Foreign import: monotonic time from JS performance.now()
foreign import env "env"
@(default_calling_convention="c")
foreign env {
    js_now_ms :: proc() -> f64 ---
}

now_ms :: proc() -> f64 { return js_now_ms() }

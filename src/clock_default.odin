#+build !wasm32
#+build !wasm64p32
package game
import rl "vendor:raylib"
now_ms :: proc() -> f64 { return rl.GetTime() * 1000 }

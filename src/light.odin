package game

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Glow_Pipeline :: struct {
    light_shader   : rl.Shader,
    scene_rt       : rl.RenderTexture2D,
    glow_rt        : rl.RenderTexture2D,
    // Uniform locations — lighting
    sun_dir1_loc   : i32,
    sun_color1_loc : i32,
    sun_dir2_loc   : i32,
    sun_color2_loc : i32,
    ambient_loc    : i32,
}

init_pipeline :: proc(w, h: i32) -> Glow_Pipeline {
    p: Glow_Pipeline

    // GLSL 100 — load from embedded strings for web
    if light_vs, light_vs_ok := read_entire_file("assets/lighting.vs", context.temp_allocator); light_vs_ok {
        if light_fs, light_fs_ok := read_entire_file("assets/lighting.fs", context.temp_allocator); light_fs_ok {
            vs_cstr := strings.clone_to_cstring(string(light_vs), context.temp_allocator)
            fs_cstr := strings.clone_to_cstring(string(light_fs), context.temp_allocator)
            p.light_shader = rl.LoadShaderFromMemory(vs_cstr, fs_cstr)
        }
    }

    // Render textures
    p.scene_rt = rl.LoadRenderTexture(w, h)
    p.glow_rt  = rl.LoadRenderTexture(w, h)

    // Cache uniform locations
    p.sun_dir1_loc   = rl.GetShaderLocation(p.light_shader, "sunDir1")
    p.sun_color1_loc = rl.GetShaderLocation(p.light_shader, "sunColor1")
    p.sun_dir2_loc   = rl.GetShaderLocation(p.light_shader, "sunDir2")
    p.sun_color2_loc = rl.GetShaderLocation(p.light_shader, "sunColor2")
    p.ambient_loc    = rl.GetShaderLocation(p.light_shader, "ambientColor")

    fmt.println("[LIGHT] shaders initialized")

    return p
}

free_pipeline :: proc(p: ^Glow_Pipeline) {
    rl.UnloadShader(p.light_shader)
    rl.UnloadRenderTexture(p.scene_rt)
    rl.UnloadRenderTexture(p.glow_rt)

    fmt.println("[LIGHT] shaders unloaded")
}

// Called when loading a level to push that level's sun config
set_sun :: proc(p: Glow_Pipeline, def: Level_Definition) {
    dir1   := def.sun_dir1
    color1 := def.sun_color1
    dir2   := def.sun_dir2
    color2 := def.sun_color2
    amb    := def.ambient
    rl.SetShaderValue(p.light_shader, p.sun_dir1_loc,   &dir1,   .VEC3)
    rl.SetShaderValue(p.light_shader, p.sun_color1_loc, &color1, .VEC3)
    rl.SetShaderValue(p.light_shader, p.sun_dir2_loc,   &dir2,   .VEC3)
    rl.SetShaderValue(p.light_shader, p.sun_color2_loc, &color2, .VEC3)
    rl.SetShaderValue(p.light_shader, p.ambient_loc,    &amb,    .VEC3)
}

// The main render call for all drawing + 3D + 2D
render_frame :: proc(p: Glow_Pipeline, gs: Game_State, def: Level_Definition) {
    // Pass 1: Scene with lighting
    rl.BeginTextureMode(p.scene_rt)
        rl.ClearBackground(def.clear_color)
        rl.BeginMode3D(gs.camera)
            rl.BeginShaderMode(p.light_shader)
                draw_level_solids(gs.level)
                draw_level_enemies(gs.level)
            rl.EndShaderMode()
        rl.EndMode3D()
    rl.EndTextureMode()

    // Pass 2: Glow source (enemies only, flat bright color)
    rl.BeginTextureMode(p.glow_rt)
        rl.ClearBackground(rl.BLACK)
        rl.BeginMode3D(gs.camera)
            draw_level_solids(gs.level)
            for e in gs.level.enemies {
                if !e.active do continue
                rl.DrawSphere(e.pos, e.radius, def.enemy_glow)
            }
        rl.EndMode3D()
    rl.EndTextureMode()

    // Draw scene, then additive blend glow on top
    rl.BeginDrawing()
        draw_rt_flipped(p.scene_rt.texture)
        rl.BeginBlendMode(.ADDITIVE)
            draw_rt_flipped(p.glow_rt.texture)
        rl.EndBlendMode()
        draw_screen(gs)
    rl.EndDrawing()
}

// Raylib render textures have flipped Y
draw_rt_flipped :: proc(tex: rl.Texture2D) {
    src := rl.Rectangle{0, 0, f32(tex.width), -f32(tex.height)}
    dst := rl.Rectangle{0, 0, f32(tex.width),  f32(tex.height)}
    rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.LIGHTGRAY)
}
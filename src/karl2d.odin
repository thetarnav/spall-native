package main

import "core:time"
import "core:fmt"

import k2 "../karl2d"

// Sole Spall-facing Karl2D boundary.

create_context :: proc(title: string, width, height: int) -> (gfx: GFX_Context, scale: f64, out_width, out_height: f64) {
	k2.init(width, height, title, options={
        window_mode = .Windowed_Resizable,
    })
	karl2d_coords_refresh_gfx(&gfx)
	if !karl2d_load_fonts(&gfx) {
		karl2d_release_fonts(&gfx)
		k2.shutdown()
		platform_fonts = {}
		platform_font_scale = 1
		platform_frontend_ready = false
		return
	}
	platform_fonts = gfx.fonts
	platform_font_scale = gfx.window_scale
	platform_frontend_ready = true
	scale = gfx.window_scale
	out_width = f64(gfx.physical_width)
	out_height = f64(gfx.physical_height)
	return
}

shutdown_context :: proc(gfx: ^GFX_Context) {
	karl2d_release_fonts(gfx)
	k2.shutdown()
	platform_fonts = {}
	platform_font_scale = 1
	platform_frontend_ready = false
}

get_events :: proc (gfx: ^GFX_Context, block: bool) -> (events: []k2.Event, ok: bool) {

    update_frontend(gfx) or_return

	for _ in 0..<4 {
		events = k2.get_events()

        if len(events) == 0 {
            if !block do return {}, true

            k2.present() // without this k2 never wakes up

            time.sleep(1 * time.Millisecond)
            update_frontend(gfx) or_return
            continue
        }
        return events, true
	}

    return {}, true
}

karl2d_current_coords :: proc(gfx: ^GFX_Context) -> Karl2D_Coords {
	return karl2d_coords_make(gfx.physical_width, gfx.physical_height, gfx.window_scale)
}

update_frontend :: proc(gfx: ^GFX_Context) -> bool {
	running := k2.update()
	karl2d_coords_refresh_gfx(gfx)
	return running
}

set_fullscreen :: proc(gfx: ^GFX_Context, fullscreen: bool) -> (width, height: int) {
	mode := k2.Window_Mode.Windowed
	if fullscreen { mode = .Borderless_Fullscreen }
	k2.set_window_mode(mode)
	gfx.fullscreen = fullscreen
	karl2d_coords_refresh_gfx(gfx)
	return gfx.physical_width, gfx.physical_height
}

set_cursor :: proc(gfx: ^GFX_Context, name: string) {
	cursor := k2.Standard_Cursor.Default
	if name == "pointer" { cursor = .Hand }
	if name == "text" { cursor = .Text }
	k2.set_cursor(cursor)
    is_hovering = name != ""
}
reset_cursor :: proc(gfx: ^GFX_Context) {
	set_cursor(gfx, "")
}

// Physical dimensions are drawable pixels; logical dimensions are UI units.
Karl2D_Coords :: struct {
	physical_width:  int,
	physical_height: int,
	logical_width:   f64,
	logical_height:  f64,
	window_scale:    f64,
}

karl2d_coords_make :: proc(physical_width, physical_height: int, window_scale: f64) -> Karl2D_Coords {
	coords := Karl2D_Coords{}
	karl2d_coords_update(&coords, physical_width, physical_height, window_scale)
	return coords
}

karl2d_coords_update :: proc(coords: ^Karl2D_Coords, physical_width, physical_height: int, window_scale: f64) {
	coords.physical_width  = max(0, physical_width)
	coords.physical_height = max(0, physical_height)
	coords.window_scale    = window_scale > 0 ? window_scale : 1.0
	coords.logical_width   = f64(coords.physical_width) / coords.window_scale
	coords.logical_height  = f64(coords.physical_height) / coords.window_scale
}

karl2d_coords_update_gfx :: proc(gfx: ^GFX_Context, physical_width, physical_height: int, window_scale: f64) {
	karl2d_coords_update_gfx_fields(gfx, physical_width, physical_height, window_scale)
}

karl2d_coords_update_gfx_fields :: proc(gfx: ^GFX_Context, physical_width, physical_height: int, window_scale: f64) {
	coords := karl2d_coords_make(physical_width, physical_height, window_scale)
	gfx.physical_width = coords.physical_width
	gfx.physical_height = coords.physical_height
	gfx.logical_width = coords.logical_width
	gfx.logical_height = coords.logical_height
	gfx.window_scale = coords.window_scale
	platform_font_scale = coords.window_scale
}

karl2d_coords_refresh_gfx :: proc(gfx: ^GFX_Context) {
	karl2d_coords_update_gfx(gfx, k2.get_screen_width(), k2.get_screen_height(), f64(k2.get_window_scale()))
}

karl2d_coords_logical_to_physical :: proc(coords: Karl2D_Coords, logical: Vec2) -> Vec2 {
	return logical * coords.window_scale
}

karl2d_coords_physical_to_logical :: proc(coords: Karl2D_Coords, physical: Vec2) -> Vec2 {
	return physical / coords.window_scale
}

// Deltas have no origin and therefore use the same scale without translation.
karl2d_coords_physical_delta_to_logical :: proc(coords: Karl2D_Coords, delta: Vec2) -> Vec2 {
	return delta / coords.window_scale
}

karl2d_coords_logical_rect_to_physical :: proc(coords: Karl2D_Coords, logical: Rect) -> Rect {
	return Rect{
		x = logical.x * coords.window_scale,
		y = logical.y * coords.window_scale,
		w = logical.w * coords.window_scale,
		h = logical.h * coords.window_scale,
	}
}

karl2d_coords_physical_rect_to_logical :: proc(coords: Karl2D_Coords, physical: Rect) -> Rect {
	return Rect{
		x = physical.x / coords.window_scale,
		y = physical.y / coords.window_scale,
		w = physical.w / coords.window_scale,
		h = physical.h / coords.window_scale,
	}
}

Edge :: struct {start, end: Vec2}

karl2d_color :: proc(color: BVec4) -> k2.Color {
	// Karl2D consumes straight RGBA8. Keep UI colors unchanged at this boundary.
	return k2.Color{color[0], color[1], color[2], color[3]}
}

karl2d_draw_scale :: proc(gfx: ^GFX_Context) -> f64 {
	if gfx != nil && gfx.window_scale > 0 {
		return gfx.window_scale
	}
	return 1
}

karl2d_rect_geometry :: proc(rect: Rect, scale: f64) -> k2.Rect {
	return {
		x = f32(rect.x * scale),
		y = f32(rect.y * scale),
		w = f32(rect.w * scale),
		h = f32(rect.h * scale),
	}
}

karl2d_line_geometry :: proc(start, end: Vec2, width, scale: f64) -> (k2.Vec2, k2.Vec2, f32) {
	return k2.Vec2{f32(start.x * scale), f32(start.y * scale)},
		k2.Vec2{f32(end.x * scale), f32(end.y * scale)},
		f32(width * scale)
}

karl2d_outline_edges :: proc(rect: Rect, width: f64, inset: bool) -> [4]Edge {
	x1, y1 := rect.x, rect.y
	x2, y2 := rect.x + rect.w, rect.y + rect.h
	if inset {
		x1 += width
		y1 += width
		x2 -= width
		y2 -= width
	}
	return {
		{{x1, y1}, {x2, y1}},
		{{x1, y1}, {x1, y2}},
		{{x2, y1}, {x2, y2}},
		{{x1, y2}, {x2, y2}},
	}
}

draw_rect :: proc(gfx: ^GFX_Context, rect: Rect, color: BVec4) {
	scale := karl2d_draw_scale(gfx)
	k2.draw_rect(karl2d_rect_geometry(rect, scale), karl2d_color(color))
}

draw_line :: proc(gfx: ^GFX_Context, start, end: Vec2, width: f64, color: BVec4) {
	scale := karl2d_draw_scale(gfx)
	physical_start, physical_end, physical_width := karl2d_line_geometry(start, end, width, scale)
	k2.draw_line(physical_start, physical_end, physical_width, karl2d_color(color))
}

draw_rect_outline :: proc(gfx: ^GFX_Context, rect: Rect, width: f64, color: BVec4) {
	for edge in karl2d_outline_edges(rect, width, false) {
		draw_line(gfx, edge.start, edge.end, width, color)
	}
}

draw_rect_inline :: proc(gfx: ^GFX_Context, rect: Rect, width: f64, color: BVec4) {
	for edge in karl2d_outline_edges(rect, width, true) {
		draw_line(gfx, edge.start, edge.end, width, color)
	}
}

karl2d_load_font :: proc(gfx: ^GFX_Context, kind: FontType, data: []u8, name: string) -> bool {
	if gfx == nil || len(data) == 0 {
		if len(data) == 0 do fmt.eprintln("Karl2D font data missing: ", name)
		return false
	}
	handle := k2.load_dynamic_font_from_bytes(data)
	if handle == k2.FONT_NONE {
		fmt.eprintln("Karl2D font failed to load: ", name)
		return false
	}
	gfx.fonts[kind] = handle
	return true
}

karl2d_release_fonts :: proc(gfx: ^GFX_Context) {
	for &font in &gfx.fonts {
		if font != k2.FONT_NONE {
			k2.destroy_font(font)
			font = k2.FONT_NONE
		}
	}
}

karl2d_load_fonts :: proc(gfx: ^GFX_Context) -> bool {
	sans_loaded  := karl2d_load_font(gfx, .DefaultFont, #load("../fonts/Montserrat-Regular.ttf"),  "Montserrat-Regular.ttf")
	mono_loaded  := karl2d_load_font(gfx, .MonoFont,    #load("../fonts/FiraMono-Regular.ttf"),    "FiraMono-Regular.ttf")
	icons_loaded := karl2d_load_font(gfx, .IconFont,    #load("../fonts/fontawesome-webfont.ttf"), "fontawesome-webfont.ttf")
	return sans_loaded && mono_loaded && icons_loaded
}

karl2d_font_handle_valid :: proc(font: k2.Font) -> bool { return font != k2.FONT_NONE }

karl2d_font_size :: proc(scale: FontSize, dpr: f64) -> f32 {
	if dpr <= 0 { return 0 }
	#partial switch scale {
	case .PSize:  return f32(p_height * dpr)
	case .H1Size: return f32(h1_height * dpr)
	case .H2Size: return f32(h2_height * dpr)
	}
	return 0
}

get_text_height :: proc(scale: FontSize, font: FontType) -> f64 {
	_ = font
	#partial switch scale {
	case .PSize:  return p_height
	case .H1Size: return h1_height
	case .H2Size: return h2_height
	}
	return 0
}

measure_text :: proc(str: string, scale: FontSize, font_type: FontType) -> f64 {
	if len(str) == 0 || !platform_frontend_ready { return 0 }
	font := platform_fonts[font_type]
	if !karl2d_font_handle_valid(font) || platform_font_scale <= 0 { return 0 }
	return f64(k2.measure_text(str, karl2d_font_size(scale, platform_font_scale), font).x) / platform_font_scale
}

draw_text :: proc(gfx: ^GFX_Context, str: string, pos: Vec2, scale: FontSize, font_type: FontType, color: BVec4) {
	if len(str) == 0 do return
	font := gfx.fonts[font_type]
	if !karl2d_font_handle_valid(font) { return }
	dpr := gfx.window_scale
	if dpr <= 0 { dpr = 1 }
	k2.draw_text(str, k2.Vec2{f32(pos.x * dpr), f32(pos.y * dpr)}, karl2d_font_size(scale, dpr), k2.Color(color), font)
}

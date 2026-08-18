package main

import "core:strings"
import "core:time"
import k2 "../karl2d"

// Platform_Services is application-owned service state.  It deliberately has
// no window, renderer, or SDL handles, so dialogs and clipboard operations can
// survive frontend replacement and recover from service failures.
// platform_dialog_result is the neutral contract used by OS dialog adapters:
// cancellation or an empty selection never becomes an application update.
platform_dialog_result :: proc(accepted: bool, value: string) -> (string, bool) {
	if !accepted || len(value) == 0 {
		return "", false
	}
	return strings.clone(value), true
}

// Compatibility wrappers retain the signatures used by UI callers while
// keeping service state independent from Karl2D's renderer state.
get_clipboard :: proc(gfx: ^GFX_Context) -> string {
	_ = gfx
	return platform_clipboard_get()
}

set_clipboard :: proc(gfx: ^GFX_Context, text: string) {
	_ = gfx
	platform_clipboard_set(text)
}

mouse_down :: proc(x, y: f64) {
	is_mouse_down = true
	mouse_pos = Vec2{x, y}

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}

	clicked = true
	clicked_pos = mouse_pos

	cur_time := time.tick_now()
	time_diff := time.tick_diff(clicked_t, cur_time)
	click_window := time.duration_milliseconds(time_diff)
	double_click_window_ms := 400.0

	if click_window < double_click_window_ms {
		double_clicked = true
	} else {
		double_clicked = false
	}
	clicked_t = cur_time
}

mouse_up :: proc(x, y: f64) {
	is_mouse_down = false
	was_mouse_down = true
	mouse_up_now = true

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}

	mouse_pos = Vec2{x, y}
}

mouse_moved :: proc(x, y: f64) {
	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}

	mouse_pos = Vec2{x, y}
}

mouse_scroll :: proc(y: f64) {
    y := y
    when ODIN_OS == .Darwin {
        y *= -15
    } else {
        y *= -100
    }
	if ctrl_down {
		y *= 10
	}
	scroll_val_y += y
}

// Text callers predate Karl2D and do not receive a context.  The lifecycle
// adapter updates this pointer on creation and clears it during shutdown.
platform_fonts: [FontType.LastFont]k2.Font
platform_frontend_ready := false
platform_font_scale := f64(1)

get_system_color :: proc() -> bool { return false }
get_session_storage :: proc(key: string) { }
set_session_storage :: proc(key, val: string) { }

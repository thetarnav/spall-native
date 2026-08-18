package main

import "core:strings"
import "core:time"
import "core:os"
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

get_clipboard :: proc() -> string {
	return ""
}

set_clipboard :: proc(text: string) {
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

_session_storage_field_valid :: proc(value: string) -> bool {
	for c in value {
		if c == '=' || c == '\n' || c == '\r' {
			return false
		}
	}
	return true
}

_session_storage_key_valid :: proc(key: string) -> bool {
	return len(key) > 0 && _session_storage_field_valid(key)
}

_session_storage_path :: proc() -> (string, bool) {
	config_dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil {
		return "", false
	}
	path, path_err := os.join_path({config_dir, "spall", "session.storage"}, context.temp_allocator)
	if path_err != nil {
		return "", false
	}
	return path, true
}

get_session_storage :: proc(key: string) -> string {
	if !_session_storage_key_valid(key) {
		return ""
	}

	path, path_ok := _session_storage_path()
	if !path_ok {
		return ""
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}

	contents := string(data)
	for line in strings.split_lines_iterator(&contents) {
		equals := strings.index_byte(line, '=')
		if equals <= 0 || equals + 1 > len(line) {
			continue
		}
		stored_key := line[:equals]
		stored_value := line[equals+1:]
		if !_session_storage_key_valid(stored_key) || !_session_storage_field_valid(stored_value) {
			continue
		}
		if stored_key == key {
			return strings.clone(stored_value)
		}
	}
	return ""
}

set_session_storage :: proc(key, val: string) {
	if !_session_storage_key_valid(key) || !_session_storage_field_valid(val) {
		return
	}

	config_dir, config_err := os.user_config_dir(context.temp_allocator)
	if config_err != nil {
		return
	}
	app_dir, app_dir_err := os.join_path({config_dir, "spall"}, context.temp_allocator)
	if app_dir_err != nil || os.make_directory_all(app_dir) != nil {
		return
	}
	path, path_err := os.join_path({app_dir, "session.storage"}, context.temp_allocator)
	if path_err != nil {
		return
	}

	b := strings.builder_make(context.temp_allocator)
	found := false
	needs_separator := false
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		contents := string(data)
		needs_separator = len(contents) > 0 && contents[len(contents)-1] != '\n'
		for raw_line in strings.split_after_iterator(&contents, "\n") {
			line := raw_line
			if len(line) > 0 && line[len(line)-1] == '\n' {
				line = line[:len(line)-1]
			}
			equals := strings.index_byte(line, '=')
			if equals <= 0 || equals + 1 > len(line) {
				strings.write_string(&b, raw_line)
				continue
			}
			stored_key := line[:equals]
			stored_value := line[equals+1:]
			if !_session_storage_key_valid(stored_key) || !_session_storage_field_valid(stored_value) {
				strings.write_string(&b, raw_line)
				continue
			}
			if stored_key == key {
				if !found {
					strings.write_string(&b, key)
					strings.write_string(&b, "=")
					strings.write_string(&b, val)
					if len(raw_line) > len(line) {
						strings.write_string(&b, "\n")
					}
					found = true
				}
			} else {
				strings.write_string(&b, raw_line)
			}
		}
	}
	if !found {
		if needs_separator {
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, key)
		strings.write_string(&b, "=")
		strings.write_string(&b, val)
		strings.write_string(&b, "\n")
	}
	_ = os.write_entire_file(path, strings.to_string(b))
}

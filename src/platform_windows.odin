#+build windows
package main

import "core:strings"
import "core:sys/windows"

windows_clipboard_text: string

platform_clipboard_get :: proc() -> string { return strings.clone(windows_clipboard_text) }
platform_clipboard_set :: proc(text: string) {
	if len(windows_clipboard_text) > 0 { delete(windows_clipboard_text) }
	windows_clipboard_text = strings.clone(text)
}

// Convert a dialog buffer without exposing the Windows dialog API to callers.
// Keeping this separate also makes path conversion testable without opening a dialog.
windows_path_from_utf16 :: proc(path_buf: []u16) -> (string, bool) {
	file_name, ok := windows.utf16_to_utf8(path_buf, context.temp_allocator)
	if !ok {
		return "", false
	}
	trimmed_name := strings.trim_right_null(file_name)
	if len(trimmed_name) == 0 {
		return "", false
	}
	return strings.clone(trimmed_name), true
}

open_file_dialog :: proc() -> (string, bool) {
	path_buf := make([]u16, windows.MAX_PATH_WIDE)
	if path_buf == nil {
		return "", false
	}
	defer delete(path_buf)

	filters := []string{"All Files", "*.*"}
	filter: string
	filter = strings.join(filters, "\u0000", context.temp_allocator)
	filter = strings.concatenate({filter, "\u0000"}, context.temp_allocator)

	title := "Select tracefile to open"
	dir := "."
	default_ext := ""

	ofn := windows.OPENFILENAMEW{
		lStructSize     = size_of(windows.OPENFILENAMEW),
		lpstrFile       = windows.wstring(&path_buf[0]),
		nMaxFile        = windows.MAX_PATH_WIDE,
		lpstrTitle      = windows.utf8_to_wstring(title, context.temp_allocator),
		lpstrFilter     = windows.utf8_to_wstring(filter, context.temp_allocator),
		lpstrInitialDir = windows.utf8_to_wstring(dir, context.temp_allocator),
		nFilterIndex    = 1,
		lpstrDefExt     = windows.utf8_to_wstring(default_ext, context.temp_allocator),
		Flags           = windows.OPEN_FLAGS,
	}

	ok := windows.GetOpenFileNameW(&ofn)
	if !ok {
		return "", false
	}

	return windows_path_from_utf16(path_buf[:])
}

// we don't actually demangle on Windows, because Windows.
demangle_symbol :: proc(name: string, tmp_buffer: []u8) -> (string, bool) {
	return name, true
}

sample_child :: proc(trace: ^Trace, program_name: string, path: string, args: []string) -> (ok: bool) { return }
supports_sampling :: proc() -> (ok: bool) { return }

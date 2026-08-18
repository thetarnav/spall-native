#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

// State retained by Linux clipboard/drop services, independent of Karl2D's
// frontend window and renderer lifecycle.
Linux_Platform_Services :: struct {
	clipboard_text: string,
	dropped_file:   string,
	dnd_src_window: uintptr,
	dnd_format:     uintptr,
	dnd_version:    int,
}

linux_services: Linux_Platform_Services

// Clipboard remains a platform service, not Karl2D state. The native X11
// owner/request protocol can replace these two seams without changing UI code.
platform_clipboard_get :: proc() -> string {
	return strings.clone(linux_services.clipboard_text)
}

platform_clipboard_set :: proc(text: string) {
	if len(linux_services.clipboard_text) > 0 { delete(linux_services.clipboard_text) }
	linux_services.clipboard_text = strings.clone(text)
}

// dialog_output_result converts Zenity's stdout into the application result.
// Empty output is the normal result for cancellation or an unavailable dialog.
dialog_output_result :: proc(output: []u8) -> (path: string, ok: bool) {
	if len(output) == 0 {
		return "", false
	}

	end := len(output)
	for end > 0 && (output[end-1] == '\n' || output[end-1] == '\r') {
		end -= 1
	}
	if end == 0 {
		return "", false
	}

	return strings.clone_from_bytes(output[:end]), true
}

open_file_dialog :: proc() -> (string, bool) {
	buffer := [4096]u8{}
	fds := [2]linux.Fd{}
	if linux.pipe2(&fds, {}) != nil {
		return "", false
	}

	pid, err := linux.fork()
	if err != nil {
		fmt.eprintln("Spall file dialogs require Zenity; launch a trace from the command line instead.")
		linux.close(fds[0])
		linux.close(fds[1])
		return "", false
	}

	if pid == 0 {
		linux.dup2(fds[1], 1)
		linux.close(fds[1])
		linux.close(fds[0])
		argv := []cstring{"zenity", "--file-selection", nil}
		posix.execvp("zenity", raw_data(argv))
		os.exit(1)
	}

	linux.close(fds[1])
	read_count, read_err := linux.read(fds[0], buffer[:])
	linux.close(fds[0])
	status: i32 = 0
	posix.waitpid(posix.pid_t(pid), &status, nil)
	if read_err != nil || read_count <= 0 {
		return "", false
	}

	return dialog_output_result(buffer[:read_count])
}

_hex_digit :: proc(v: u8) -> (u8, bool) {
	switch {
	case v >= '0' && v <= '9': return v - '0', true
	case v >= 'a' && v <= 'f': return v - 'a' + 10, true
	case v >= 'A' && v <= 'F': return v - 'A' + 10, true
	}
	return 0, false
}

// normalize_file_uri accepts local file URIs and returns a native path.
// Remote authorities and malformed percent escapes are rejected.
normalize_file_uri :: proc(uri: string) -> (path: string, ok: bool) {
	if !strings.has_prefix(uri, "file://") {
		return "", false
	}

	rest := uri[len("file://"):]
	if len(rest) == 0 {
		return "", false
	}
	if strings.has_prefix(rest, "localhost/") {
		rest = rest[len("localhost"):]
	} else if rest[0] != '/' {
		return "", false
	}

	decoded := make([dynamic]u8)
	defer delete(decoded)
	for i := 0; i < len(rest); i += 1 {
		if rest[i] == '%' {
			if i + 2 >= len(rest) {
				return "", false
			}
			hi, hi_ok := _hex_digit(rest[i+1])
			lo, lo_ok := _hex_digit(rest[i+2])
			if !hi_ok || !lo_ok {
				return "", false
			}
			append(&decoded, hi << 4 | lo)
			i += 2
		} else {
			append(&decoded, rest[i])
		}
	}

	if len(decoded) == 0 || decoded[0] != '/' {
		return "", false
	}
	return strings.clone_from_bytes(decoded[:]), true
}

// parse_dropped_file_uri_list reads the first URI in a text/uri-list payload.
parse_dropped_file_uri_list :: proc(data: string) -> (string, bool) {
	lines := data
	for line in strings.split_lines_iterator(&lines) {
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		return normalize_file_uri(line)
	}
	return "", false
}

// Compatibility seam for callers which still provide the native payload as a
// cstring.  Invalid drops are rejected without terminating the application.
_parse_dropped_files_list :: proc(data: cstring) -> string {
	if data == nil {
		return ""
	}
	payload := strings.clone_from_cstring(data)
	defer delete(payload)
	path, ok := parse_dropped_file_uri_list(payload)
	if !ok {
		return ""
	}
	return path
}

foreign import abi "system:stdc++"
foreign abi {
	@(link_name = "__cxa_demangle")
	_cxa_demangle :: proc(name: rawptr, out_buf: rawptr, len: rawptr, status: rawptr) -> cstring ---
}

demangle_symbol :: proc(name: string, tmp_buffer: []u8) -> (string, bool) {
	name_cstr := strings.clone_to_cstring(name, context.temp_allocator)
	buffer_size := len(tmp_buffer)
	status: i32 = 0
	ret_str := _cxa_demangle(rawptr(name_cstr), raw_data(tmp_buffer), &buffer_size, &status)
	if status == -2 {
		return name, true
	} else if status != 0 {
		return "", false
	}
	return string(ret_str), true
}

sample_child :: proc(
	trace: ^Trace,
	program_name: string,
	path: string,
	args: []string,
) -> (ok: bool) {
	return false
}

supports_sampling :: proc() -> (ok: bool) {
	return false
}

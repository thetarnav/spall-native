#+build darwin

package main

import "core:strings"
import NS "core:sys/darwin/Foundation"

// Normalize the result of an NSOpenPanel selection. A canceled panel and an
// unexpected empty selection are both recoverable service failures.
darwin_dialog_result :: proc(accepted: bool, path: string) -> (string, bool) {
	return platform_dialog_result(accepted, path)
}

darwin_dialog_path_result :: proc(accepted: bool, path_cstr: cstring) -> (string, bool) {
	if !accepted || path_cstr == nil {
		return "", false
	}
	path := string(path_cstr)
	return darwin_dialog_result(true, path)
}

open_file_dialog :: proc() -> (string, bool) {
	panel := NS.OpenPanel.openPanel()
	panel->setCanChooseFiles(true)
	panel->setResolvesAliases(true)
	panel->setCanChooseDirectories(false)
	panel->setAllowsMultipleSelection(false)

	if panel->runModal() == .OK {
		urls := panel->URLs()
		ret_count := urls->count()
		if ret_count != 1 {
			return darwin_dialog_result(false, "")
		}

		url := urls->objectAs(0, ^NS.URL)
		if url == nil {
			return darwin_dialog_result(false, "")
		}

		path_cstr := url->fileSystemRepresentation()
		if path_cstr == nil {
			return darwin_dialog_result(false, "")
		}

		return darwin_dialog_path_result(true, path_cstr)
	}

	return darwin_dialog_result(false, "")
}

foreign import abi "system:c++abi"
foreign abi {
	@(link_name="__cxa_demangle") _cxa_demangle :: proc(name: rawptr, out_buf: rawptr, len: rawptr, status: rawptr) -> cstring ---
}

demangle_symbol :: proc(name: string, tmp_buffer: []u8) -> (string, bool) {
	name_cstr := strings.clone_to_cstring(name, context.temp_allocator)

	buffer_size := len(tmp_buffer)

	status : i32 = 0
	ret_str := _cxa_demangle(rawptr(name_cstr), raw_data(tmp_buffer), &buffer_size, &status)
	if status == -2 {
		return name, true
	} else if status != 0 {
		return "", false
	}

	return string(ret_str), true
}

supports_sampling :: proc() -> (ok: bool) { return false }

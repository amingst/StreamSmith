package streamdeck_plugin

// Logging goes to %APPDATA%\StreamSmith\streamdeck\plugin.log, never into the
// plugin folder: under Marketplace DRM the distributed files are immutable.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import win32 "core:sys/windows"

MAX_LOG_BYTES :: 1 * 1024 * 1024

@(private="file")
log_file: ^os.File

log_open :: proc() {
	dir := log_dir()
	if dir == "" do return
	defer delete(dir)

	// Missing parents are made too; an existing directory is not an error here.
	os.make_directory_all(dir)

	path, join_err := filepath.join({dir, "plugin.log"})
	if join_err != nil do return
	defer delete(path)

	// One rollover, so a long-running install can't grow without bound.
	if info, stat_err := os.stat(path, context.temp_allocator); stat_err == nil && info.size > MAX_LOG_BYTES {
		if old, old_err := filepath.join({dir, "plugin.log.1"}); old_err == nil {
			os.remove(old)
			os.rename(path, old)
			delete(old)
		}
	}

	f, open_err := os.open(path, {.Write, .Create, .Append})
	if open_err != nil do return
	log_file = f
}

log_close :: proc() {
	if log_file == nil do return
	os.close(log_file)
	log_file = nil
}

log_line :: proc(format: string, args: ..any) {
	if log_file == nil do return

	year, month, day := time.date(time.now())
	hour, minute, second := time.clock(time.now())
	message := fmt.tprintf(format, ..args)
	line := fmt.tprintf("%4d-%02d-%02d %02d:%02d:%02d  %s\n",
		year, int(month), day, hour, minute, second, message)
	os.write_string(log_file, line)
}

// %APPDATA%\StreamSmith\streamdeck
@(private)
log_dir :: proc() -> string {
	roaming: string
	folder_id := win32.FOLDERID_RoamingAppData // needs an addressable copy
	wpath: win32.LPWSTR
	if hr := win32.SHGetKnownFolderPath(&folder_id, 0, nil, &wpath); hr >= 0 && wpath != nil {
		defer win32.CoTaskMemFree(wpath)
		if s, err := win32.wstring_to_utf8(win32.wstring(wpath), -1, context.temp_allocator); err == nil {
			roaming = s
		}
	}
	if roaming == "" {
		env, found := os.lookup_env("APPDATA", context.temp_allocator)
		if !found do return ""
		roaming = env
	}

	dir, err := filepath.join({roaming, "StreamSmith", "streamdeck"})
	if err != nil do return ""
	return strings.clone(dir)
}

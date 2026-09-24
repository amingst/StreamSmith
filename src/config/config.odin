package config

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"

@(private)
CURRENT_VERSION :: 1

App_Config :: struct {           // app.json
    version:        int,
    active_show_id: string,
    remote:         Remote_Config,
}

// Remote control (Stream Deck and other local clients), app-wide rather than
// per show. See docs/remote-protocol.md.
Remote_Config :: struct {
    enabled:         bool,
    port:            int,
    allowed_origins: []string, // owned; exact Origin headers allowed to connect
}

DEFAULT_REMOTE_PORT :: 4460

// Used for a missing or unreadable app.json, and as the base the loader fills
// in over, so a config written before remote control existed still gets these.
default_remote_config :: proc() -> Remote_Config {
    return Remote_Config{enabled = true, port = DEFAULT_REMOTE_PORT}
}

// Every field is an owned string; release with destroy_paths.
Paths :: struct {
	root:       string,
	app_config: string, // root/app.json
	videos:     string, // recording output directory, e.g. %USERPROFILE%\Videos
	shows:      string, // root/shows/
}

destroy_paths :: proc(p: ^Paths) {
	if p == nil { return }
	if p.root       != "" do delete(p.root)
	if p.app_config != "" do delete(p.app_config)
	if p.videos     != "" do delete(p.videos)
	if p.shows      != "" do delete(p.shows)
	p^ = {}
}

@(require_results)
resolve_paths :: proc() -> (paths: Paths, ok: bool) {
	roaming: string
	folder_id := win32.FOLDERID_RoamingAppData // needs an addressable copy
	wpath: win32.LPWSTR
	if hr := win32.SHGetKnownFolderPath(&folder_id, 0, nil, &wpath); hr >= 0 && wpath != nil {
		defer win32.CoTaskMemFree(wpath)
		if s, err := win32.wstring_to_utf8(win32.wstring(wpath), -1, context.temp_allocator);
		   err == nil && s != "" {
			roaming = s
			log.debugf("config root from SHGetKnownFolderPath: %v", roaming)
		}
	} else {
		log.warnf("SHGetKnownFolderPath(FOLDERID_RoamingAppData) failed: HRESULT 0x%08X", u32(hr))
	}

	if roaming == "" {
		env, found := os.lookup_env("APPDATA", context.temp_allocator)
		if !found || env == "" {
			log.warn("no roaming AppData directory available (known folder and APPDATA both failed); settings will not persist")
			return {}, false
		}
		roaming = env
		log.debugf("config root from APPDATA: %v", roaming)
	}
	defer if !ok do destroy_paths(&paths)

	if !join_into(&paths.root, roaming, "StreamSmith")   do return
	if !make_dir(paths.root)                           do return

	if !join_into(&paths.app_config, paths.root, "app.json") do return

	if !join_into(&paths.shows, paths.root, "shows") do return
	if !make_dir(paths.shows)                        do return

	// Recording output directory (the user's Videos folder, not under paths.root).
	resolve_videos(&paths)

	ok = true
	return
}

@(private = "file")
resolve_videos :: proc(paths: ^Paths) {
	videos: string
	folder_id := win32.FOLDERID_Videos // needs an addressable copy
	wpath: win32.LPWSTR
	if hr := win32.SHGetKnownFolderPath(&folder_id, 0, nil, &wpath); hr >= 0 && wpath != nil {
		defer win32.CoTaskMemFree(wpath)
		if s, err := win32.wstring_to_utf8(win32.wstring(wpath), -1, context.temp_allocator);
		   err == nil && s != "" {
			videos = s
			log.debugf("videos directory from SHGetKnownFolderPath: %v", videos)
		}
	} else {
		log.warnf("SHGetKnownFolderPath(FOLDERID_Videos) failed: HRESULT 0x%08X", u32(hr))
	}

	if videos == "" {
		profile, found := os.lookup_env("USERPROFILE", context.temp_allocator)
		if !found || profile == "" {
			log.warn("no Videos directory available (known folder and USERPROFILE both failed); recording will not be available")
			return
		}
		joined, jerr := filepath.join({profile, "Videos"}, context.temp_allocator)
		if jerr != nil {
			log.warnf("could not build videos path from USERPROFILE: %v; recording will not be available", jerr)
			return
		}
		videos = joined
		log.debugf("videos directory from USERPROFILE: %v", videos)
	}

	if !make_dir(videos) {
		return
	}
	paths.videos = strings.clone(videos)
}

@(private="file")
join_into :: proc(dst: ^string, parts: ..string) -> bool {
	joined, jerr := filepath.join(parts)
	if jerr != nil {
		log.warnf("could not build config path %v: %v; settings will not persist", parts, jerr)
		return false
	}
	dst^ = joined
	return true
}

@(private="file")
make_dir :: proc(dir: string) -> bool {
	// Already-there is the steady state, not a failure.
	if err := os.make_directory(dir); err != nil && err != os.General_Error.Exist {
		log.warnf("could not create config directory %v: %v; settings will not persist", dir, err)
		return false
	}
	return true
}

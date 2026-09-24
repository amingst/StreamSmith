package app

import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../applog"
import "../config"
import "../show"

// Opens one log file per run under paths.root, named with the start timestamp.
open_log_file :: proc(sink: ^applog.Sink, paths: ^config.Paths) {
	if paths.root == "" do return

	year, month, day := time.date(time.now())
	hour, min, sec := time.clock(time.now())
	log_file_name := fmt.tprintf("log-%4d-%02d-%02d_%02d-%02d-%02d.txt",
		year, int(month), day, hour, min, sec)
	if log_path, jerr := filepath.join({paths.root, log_file_name}, context.temp_allocator); jerr == nil {
		if !applog.sink_open_file(sink, log_path) {
			fmt.eprintfln("applog: could not open log file %v -- continuing with ring buffer and console only", log_path)
		}
	}
}

// Loads app.json (missing/invalid file just leaves app_cfg zero-valued).
load_app_config :: proc(paths: ^config.Paths) -> (app_cfg: config.App_Config) {
	app_cfg.remote = config.default_remote_config() // load fills these in when the file has them
	if paths.app_config != "" {
		config.load_app_config(&app_cfg, paths.app_config)
	}
	return
}

// Same load-active / pick-first / create-Default shape as the old
// profiles/collections had. Deliberately no migration step -- a show starts
// empty, it is never derived from an existing profile or scene collection.
load_show :: proc(paths: ^config.Paths, app_cfg: ^config.App_Config) -> (s: show.Show, show_infos: []show.Show_Info) {
	s = show.create_default()
	selected := false

	if paths.shows != "" {
		infos := show.enumerate(paths.shows)
		defer show.destroy_infos(infos)

		if app_cfg.active_show_id != "" {
			found := false
			for info in infos {
				if info.id == app_cfg.active_show_id {
					found = true
					break
				}
			}
			if found {
				if loaded, ok := show.load_by_id(app_cfg.active_show_id, paths.shows); ok {
					show.destroy_show(&s)
					s = loaded
					selected = true
				}
			} else {
				log.warnf("active show %v not found among %v show(s) in %v; picking another",
					app_cfg.active_show_id, len(infos), paths.shows)
			}
		}

		if !selected && len(infos) > 0 {
			// First by name (stable across runs), tie-broken by id.
			best := 0
			for info, i in infos {
				if info.name < infos[best].name ||
				   (info.name == infos[best].name && info.id < infos[best].id) {
					best = i
				}
			}
			if loaded, ok := show.load_by_id(infos[best].id, paths.shows); ok {
				show.destroy_show(&s)
				s = loaded
				selected = true
			}
		}

		if !selected {
			if created, ok := show.create(paths.shows, "Default"); ok {
				show.destroy_show(&s)
				s = created
				selected = true
			}
		}
	}

	// Keep app.json in sync with whichever show ended up active.
	if selected && paths.app_config != "" && app_cfg.active_show_id != s.id {
		delete(app_cfg.active_show_id)
		app_cfg.active_show_id = strings.clone(s.id)
		config.save_app_config(app_cfg, paths.app_config)
	}

	log.infof("show %v (%v) active (%v scene(s))", s.name, s.id, len(s.scenes))

	// Cached listing for the Show menu; refreshed on create/rename/delete.
	if paths.shows != "" {
		show_infos = show.enumerate(paths.shows)
	}

	return
}

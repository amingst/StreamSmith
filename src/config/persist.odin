package config

import json "core:encoding/json"
import os "core:os"
import log "core:log"
import "core:strings"

// app.json's on-disk shape.
App_Config_DTO :: struct {
    version:        int,
    active_show_id: string,
    remote:         Remote_DTO,
}

Remote_DTO :: struct {
    enabled:         bool,
    port:            int,
    allowed_origins: []string,
}

destroy_app_config :: proc(cfg: ^App_Config) {
    delete(cfg.active_show_id)
    for origin in cfg.remote.allowed_origins {
        delete(origin)
    }
    delete(cfg.remote.allowed_origins)
    cfg^ = {}
}

save_app_config :: proc(cfg: ^App_Config, path: string) -> bool {
    dto := App_Config_DTO{
        version        = CURRENT_VERSION,
        active_show_id = cfg.active_show_id,
        remote         = {
            enabled         = cfg.remote.enabled,
            port            = cfg.remote.port,
            allowed_origins = cfg.remote.allowed_origins,
        },
    }
    data, merr := json.marshal(dto, {pretty = true}, context.temp_allocator)
    if merr != nil {
        log.errorf("app config marshal failed: %v", merr)
        return false
    }

    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("app config write failed: %v (%v)", path, werr)
        return false
    }

    log.infof("app config saved: %v", path)
    return true
}

load_app_config :: proc(cfg: ^App_Config, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        // Missing file is the normal first-run case; anything else logs a warning.
        if rerr != os.General_Error.Not_Exist {
            log.warnf("app config read failed: %v (%v)", path, rerr)
        }
        return false
    }

    // Pre-filled with the defaults: unmarshal only writes the keys the file
    // has, so a config from before remote control still comes out sane. Adding
    // an optional section like this doesn't need a version bump.
    defaults := default_remote_config()
    dto := App_Config_DTO{remote = {enabled = defaults.enabled, port = defaults.port}}
    if perr := json.unmarshal(data, &dto, allocator = context.temp_allocator); perr != nil {
        log.errorf("app config parse failed: %v (%v)", path, perr)
        return false
    }
    if dto.version != CURRENT_VERSION {
        log.warnf("app config version %v, expected %v — using defaults: %v",
            dto.version, CURRENT_VERSION, path)
        return false
    }

    delete(cfg.active_show_id)
    cfg.active_show_id = strings.clone(dto.active_show_id)

    cfg.remote.enabled = dto.remote.enabled
    cfg.remote.port = dto.remote.port
    if cfg.remote.port < 1 || cfg.remote.port > 65535 {
        log.warnf("app config: remote port %v is out of range, using %v", dto.remote.port, DEFAULT_REMOTE_PORT)
        cfg.remote.port = DEFAULT_REMOTE_PORT
    }
    for origin in cfg.remote.allowed_origins {
        delete(origin)
    }
    delete(cfg.remote.allowed_origins)
    origins := make([]string, len(dto.remote.allowed_origins))
    for origin, i in dto.remote.allowed_origins {
        origins[i] = strings.clone(origin)
    }
    cfg.remote.allowed_origins = origins
    return true
}

package ui

import "core:os"
import "core:log"
import im "libs:odin-imgui"

import "../action"
import "../capture"
import "../config"
import "../show"
import "../audio"

DEFAULT_LAYOUT :: #load("default_layout.ini", string)

State :: struct {
    version: string, // shown in the status bar; supplied by main
    actions: ^action.Envelope_Queue, // owned by main; panels push actions here instead of editing live state
    show_demo: bool,
    show_settings: bool,
    scenes: Scenes_State,
    preview: Preview_State,
    controls: Controls_State,
    mixer: Mixer_State,
    sources: Sources_State,
    settings: Settings_State,
    shows: Show_State,
}

draw :: proc(
    state: ^State,
    show_cfg: ^show.Show,
    app_cfg: ^config.App_Config,
    clear_color: ^im.Vec4,
    preview_tex: im.TextureRef,
    outputs: []capture.Output_Info,
    shows: []show.Show_Info,
    canvas_w, canvas_h: f32,
    audio_devices: []audio.Device_Info
) {
    // Chrome first: it shrinks the viewport work area the dockspace then fills.
    draw_chrome(state, show_cfg, shows)

    // AutoHideTabBar: every panel is alone in its node, so this drops the dock tabs
    // in favour of the headers drawn inside each card.
    im.DockSpaceOverViewport(0, im.GetMainViewport(), {.PassthruCentralNode, .AutoHideTabBar}, nil)

    draw_preview(&state.preview, &state.sources, &state.scenes, &state.controls, show_cfg, preview_tex, canvas_w, canvas_h)
    draw_scenes(&state.scenes, show_cfg, state.actions)
    draw_sources(&state.sources, &state.scenes, show_cfg, outputs, canvas_w, canvas_h, audio_devices, state.actions)
    draw_mixer(&state.mixer, &state.scenes, show_cfg, state.actions)

    draw_modals(state, show_cfg, app_cfg, outputs, state.controls.streaming)
}

init_state :: proc(version: string, actions: ^action.Envelope_Queue) -> State {
    state := State{
        version = version,
        actions = actions,
        show_demo = false,
        show_settings = false,
        scenes = init_scenes_state(),
        preview = init_preview_state(),
        sources = init_sources_state(),
        mixer = init_mixer_state(),
        controls = init_controls_state(),
        settings = init_settings_state(),
        shows = init_show_state(),
    }
    return state
}

// Queues an action from a UI control; main dispatches it next frame.
push_action :: proc(q: ^action.Envelope_Queue, a: action.Action) {
    action.queue_push(q, action.Envelope{action = a, origin = .UI})
}

load_layout :: proc() {
// Load Default IMGUI Layout from default_layout.ini
		io := im.GetIO()
		io.IniFilename = "imgui.ini"

		if !os.exists(string(io.IniFilename)) {
			im.LoadIniSettingsFromMemory(
				cstring(raw_data(DEFAULT_LAYOUT)),
				uint(len(DEFAULT_LAYOUT))
			)
		}
}

destroy :: proc(state: ^State) {
    log.debug("UI state torn down")
    destroy_sources_state(&state.sources)
    // future panels' destroyers go here
}

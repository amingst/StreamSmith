package ui

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:strings"
import im "libs:odin-imgui"
import "../action"
import "../capture"
import "../show"
import "../audio"
import "../platform"

// The kinds selectable in the Add Source popup.
Source_Kind_Choice :: enum i32 {
    Color,
    Display,
    Audio_Input,
    Audio_Output,
    Image,
    Window,
    Camera
}

Sources_State :: struct {
    selected_id:   string, // placement id; "" == nothing selected
    name_buf:      [128]u8,
    kind_choice:   Source_Kind_Choice,
    output_choice: int, // index into the enumerated outputs, for the Add popup
    audio_choice:  int, // index into the *filtered* device list, for the Add popup

    // Window picker popup state; list is enumerated on open, freed on close.
    window_picker_list:     []capture.Window_Info,
    window_picker_show_all: bool, // bypasses the game-capture default filter

    // Camera picker popup state; list is enumerated on open, freed on close.
    camera_picker_list: []capture.Camera_Info,
}

init_sources_state :: proc() -> Sources_State {
    return Sources_State{}
}

// Frees any picker list left allocated (e.g. exiting with a popup still open).
destroy_sources_state :: proc(state: ^Sources_State) {
    if state.window_picker_list != nil {
        capture.destroy_window_list(state.window_picker_list)
        state.window_picker_list = nil
    }
    if state.camera_picker_list != nil {
        capture.destroy_camera_list(state.camera_picker_list)
        state.camera_picker_list = nil
    }
}

// Icon for a source's kind, shown at the head of its row.
@(private="file")
source_icon :: proc(data: show.Show_Source_Data) -> string {
    switch _ in data {
    case show.Color_Source_Data:   return ICON_PALETTE
    case show.Display_Source_Data: return ICON_DISPLAY
    case show.Audio_Source_Data:   return ICON_MICROPHONE
    case show.Image_Source_Data:   return ICON_IMAGE
    case show.Window_Source_Data:  return ICON_WINDOW
    case show.Camera_Source_Data:  return ICON_CAMERA
    }
    return ICON_LAYER_GROUP
}

// Formats an output as e.g. "\\.\DISPLAY1 (2560x1600)".
@(private="file")
output_label :: proc(o: capture.Output_Info) -> cstring {
    return fmt.ctprintf("%v (%vx%v)", o.device_name, o.width, o.height)
}

@(private="file")
audio_label :: proc(d: audio.Device_Info) -> cstring {
    return fmt.ctprintf("%v", d.name)
}

// Index of the output a display source is pointed at, or -1 if not found.
@(private="file")
find_output :: proc(outputs: []capture.Output_Info, adapter_index, output_index: i32) -> int {
    for o, i in outputs {
        if i32(o.adapter_index) == adapter_index && i32(o.output_index) == output_index {
            return i
        }
    }
    return -1
}

// Devices matching a source's direction (input/loopback). Temp-allocated.
@(private="file")
audio_devices_for :: proc(devices: []audio.Device_Info, is_loopback: bool) -> []audio.Device_Info {
    out := make([dynamic]audio.Device_Info, 0, len(devices), context.temp_allocator)
    for d in devices {
        if d.is_loopback == is_loopback do append(&out, d)
    }
    return out[:]
}

// Sizes and centers a placement to fill the canvas at its source's native
// aspect ratio (letterboxed/pillarboxed as needed). Colour sources use the
// canvas aspect. Geometry writes go to the placement; the aspect ratio is
// read from the (possibly shared) source.
@(private="file")
fit_to_canvas :: proc(p: ^show.Show_Source_Placement, src: ^show.Show_Source, outputs: []capture.Output_Info, canvas_w, canvas_h: f32) {
    aspect := canvas_w / canvas_h
    switch d in src.data {
    case show.Display_Source_Data:
        if i := find_output(outputs, d.adapter_index, d.output_index); i >= 0 && outputs[i].height > 0 {
            aspect = f32(outputs[i].width) / f32(outputs[i].height)
        }
    case show.Image_Source_Data:
        if d.width > 0 && d.height > 0 {
            aspect = f32(d.width) / f32(d.height)
        }
    case show.Window_Source_Data:
        // No native size until capture starts; doesn't re-fit on later resize.
        if d.capture != nil && d.capture.width > 0 && d.capture.height > 0 {
            aspect = f32(d.capture.width) / f32(d.capture.height)
        }
    case show.Camera_Source_Data:
        if d.cam != nil && d.width > 0 && d.height > 0 {
            aspect = f32(d.width) / f32(d.height)
        }
    case show.Color_Source_Data, show.Audio_Source_Data:
        // no native size, keep canvas aspect
    }


    size := [2]f32{canvas_w, canvas_w / aspect}
    if size.y > canvas_h {
        size = {canvas_h * aspect, canvas_h}
    }

    p.w, p.h = size.x, size.y
    p.x = (canvas_w - size.x) * 0.5
    p.y = (canvas_h - size.y) * 0.5
}

// Combo of enumerated outputs; picking a new one tears down the old capture.
@(private="file")
draw_output_picker :: proc(d: ^show.Display_Source_Data, outputs: []capture.Output_Info) {
    if len(outputs) == 0 {
        im.TextDisabled("No outputs available")
        return
    }

    current := find_output(outputs, d.adapter_index, d.output_index)
    preview: cstring = current >= 0 ? output_label(outputs[current]) : "<unavailable>"

    if im.BeginCombo("Output", preview) {
        for o, i in outputs {
            if im.Selectable(output_label(o), i == current) && i != current {
                log.infof("display source output %v/%v -> %v/%v (%v), restarting capture",
                    d.adapter_index, d.output_index, o.adapter_index, o.output_index, o.device_name)
                d.adapter_index = i32(o.adapter_index)
                d.output_index  = i32(o.output_index)
                show.reset_display_capture(d)
            }
        }
        im.EndCombo()
    }
}

// Device combo plus volume/mute. An unplugged device shows as unavailable.
@(private="file")
draw_audio_picker :: proc(source_id: string, d: ^show.Audio_Source_Data, devices: []audio.Device_Info, actions: ^action.Envelope_Queue) {
    matching := audio_devices_for(devices, d.is_loopback)
    if len(matching) == 0 {
        im.TextDisabled("No matching audio devices")
    } else {
        current := -1
        for m, i in matching {
            if m.id == d.device_id {
                current = i
                break
            }
        }
        preview: cstring = current >= 0 ? audio_label(matching[current]) : "<unavailable>"

        if im.BeginCombo("Device", preview) {
            for m, i in matching {
                if im.Selectable(audio_label(m), i == current) && i != current {
                    log.infof("audio source device -> %q", m.name)
                    if d.stream != nil {
                        audio.release_stream(d.device_id)
                        d.stream = nil
                    }
                    delete(d.device_id)
                    d.device_id = strings.clone(m.id)
                    d.next_retry = {}
                }
            }
            im.EndCombo()
        }
    }

    // Edit copies; mute and volume only change through actions.
    volume := d.volume
    if im.SliderFloat("Volume", &volume, 0, 1) {
        push_action(actions, action.Action_Set_Volume{source_id = source_id, volume = volume})
    }
    muted := d.muted
    if im.Checkbox("Muted", &muted) {
        push_action(actions, action.Action_Set_Mute{source_id = source_id, muted = muted})
    }
}

// Window picker: stops the old capture and stores the new identity, but never
// starts a capture itself -- the main loop's retry path does that next frame.
@(private="file")
draw_window_picker :: proc(d: ^show.Window_Source_Data, state: ^Sources_State) {
    if d.title != "" {
        im.TextWrapped(fmt.ctprintf("Window: %v", d.title))
    } else {
        im.TextDisabled("No window selected")
    }
    if d.class_name != "" || d.exe_name != "" {
        im.TextDisabled(fmt.ctprintf("Class: %v   Exe: %v",
            d.class_name != "" ? d.class_name : "?",
            d.exe_name   != "" ? d.exe_name   : "?"))
    }
    if d.capture != nil {
        im.Text(fmt.ctprintf("%v x %v", d.capture.width, d.capture.height))
    }
    if d.lost {
        im.TextDisabled("Lost -- retrying")
    }

    im.Checkbox("Game Capture", &d.game_capture)
    im.Checkbox("Hide cursor", &d.hide_cursor)
    im.Checkbox("Hide capture border", &d.hide_border)

    if im.Button("Pick Window...") {
        state.window_picker_list = capture.enumerate_windows()
        state.window_picker_show_all = false
        im.OpenPopup("Pick Window")
    }

    if im.BeginPopupModal("Pick Window") {
        im.Checkbox("Show all windows", &state.window_picker_show_all)
        im.Separator()

        // The list is freed after the loop, not inside it: destroying it mid-iteration
        // leaves the range walking freed Window_Info strings.
        picked := -1
        any_shown := false
        for w, i in state.window_picker_list {
            if d.game_capture && !state.window_picker_show_all && !w.likely_game {
                continue
            }
            any_shown = true

            exe: cstring = w.exe_name != "" ? fmt.ctprintf("%v", w.exe_name) : "?"
            label := fmt.ctprintf("%v  [%v]", w.title, exe)
            if im.Selectable(label, false) {
                picked = i
                break
            }
        }

        if picked >= 0 {
            w := state.window_picker_list[picked]
            if d.capture != nil {
                capture.stop_window_capture(d.capture)
                d.capture = nil
            }
            if d.title      != "" do delete(d.title)
            if d.class_name != "" do delete(d.class_name)
            if d.exe_name   != "" do delete(d.exe_name)
            d.title      = strings.clone(w.title)
            d.class_name = strings.clone(w.class_name)
            d.exe_name   = strings.clone(w.exe_name)
            d.lost       = false
            d.next_retry = {}

            capture.destroy_window_list(state.window_picker_list)
            state.window_picker_list = nil
            im.CloseCurrentPopup()
        } else if !any_shown {
            im.TextDisabled(d.game_capture ? "No likely-game windows found (try Show all windows)" : "No windows found")
        }

        im.Separator()
        if im.Button("Cancel") {
            capture.destroy_window_list(state.window_picker_list)
            state.window_picker_list = nil
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}

draw_sources :: proc(
    state: ^Sources_State,
    scenes: ^Scenes_State,
    s: ^show.Show,
    outputs: []capture.Output_Info,
    canvas_w, canvas_h: f32,
    devices: []audio.Device_Info,
    actions: ^action.Envelope_Queue,
) {
    p := panel_begin("Sources", "SOURCES")
    if p.visible {
        // Header buttons are laid out right-to-left.
        move_down := panel_header_button(ICON_CHEVRON_DOWN, "Move down")
        move_up   := panel_header_button(ICON_CHEVRON_UP, "Move up")
        add_source := panel_header_button("+", "Add source")
        panel_header_end()

        sc := show.find_scene(s, scenes.active_id)
        if sc == nil {
            im.TextDisabled("No scene selected")
        } else {
            if add_source {
                im.OpenPopup("Add Source")
            }
            if move_up {
                for i in 0..<len(sc.sources) {
                    if sc.sources[i].id == state.selected_id && i > 0 {
                        sc.sources[i], sc.sources[i - 1] = sc.sources[i - 1], sc.sources[i]
                        break
                    }
                }
            }
            if move_down {
                for i in 0..<len(sc.sources) {
                    if sc.sources[i].id == state.selected_id && i < len(sc.sources) - 1 {
                        sc.sources[i], sc.sources[i + 1] = sc.sources[i + 1], sc.sources[i]
                        break
                    }
                }
            }

            if im.BeginPopupModal("Add Source") {
                im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))

                im.RadioButtonIntPtr("Colour", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Color))
                im.SameLine()
                im.RadioButtonIntPtr("Display Capture", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Display))
                im.RadioButtonIntPtr("Audio Input", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Audio_Input))
                im.SameLine()
                im.RadioButtonIntPtr("Audio Output", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Audio_Output))
                im.RadioButtonIntPtr("Image", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Image))
                im.SameLine()
                im.RadioButtonIntPtr("Window Capture", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Window))
                im.SameLine()
                im.RadioButtonIntPtr("Camera", (^i32)(&state.kind_choice), i32(Source_Kind_Choice.Camera))
                if state.kind_choice == .Display {
                    if len(outputs) == 0 {
                        im.TextDisabled("No outputs available")
                    } else {
                        if state.output_choice >= len(outputs) do state.output_choice = 0
                        if im.BeginCombo("Output", output_label(outputs[state.output_choice])) {
                            for o, i in outputs {
                                if im.Selectable(output_label(o), i == state.output_choice) {
                                    state.output_choice = i
                                }
                            }
                            im.EndCombo()
                        }
                    }
                }

                if state.kind_choice == .Audio_Input || state.kind_choice == .Audio_Output {
                    matching := audio_devices_for(devices, state.kind_choice == .Audio_Output)
                    if len(matching) == 0 {
                        im.TextDisabled("No matching audio devices")
                    } else {
                        if state.audio_choice >= len(matching) do state.audio_choice = 0
                        if im.BeginCombo("Device", audio_label(matching[state.audio_choice])) {
                            for m, i in matching {
                                if im.Selectable(audio_label(m), i == state.audio_choice) {
                                    state.audio_choice = i
                                }
                            }
                            im.EndCombo()
                        }
                    }
                }

                if im.Button("Add") {
                    n := strings.index_byte(string(state.name_buf[:]), 0)
                    if n < 0 {
                        log.warn("source name truncated at 128 bytes (no NUL found)")
                        n = len(state.name_buf)
                    }
                    name := string(state.name_buf[:n])

                    if len(name) == 0 {
                        log.debug("empty source name rejected")
                    } else {
                        data: show.Show_Source_Data
                        switch state.kind_choice {
                        case .Color:
                            data = show.Color_Source_Data{}
                        case .Display:
                            d := show.Display_Source_Data{}
                            if len(outputs) > 0 {
                                o := outputs[state.output_choice]
                                d.adapter_index = i32(o.adapter_index)
                                d.output_index  = i32(o.output_index)
                            }
                            data = d
                        case .Audio_Input, .Audio_Output:
                            // volume defaults to 1.0 -- zero would be silent.
                            a := show.Audio_Source_Data{
                                is_loopback = state.kind_choice == .Audio_Output,
                                params      = {volume = 1.0},
                            }
                            matching := audio_devices_for(devices, a.is_loopback)
                            if len(matching) > 0 {
                                a.device_id = strings.clone(matching[state.audio_choice].id)
                            }
                            data = a
                        case .Image:
                            data = show.Image_Source_Data{}
                        case .Window:
                            // Empty title until the picker supplies one.
                            data = show.Window_Source_Data{}
                        case .Camera:
                            data = show.Camera_Source_Data{}
                        }

                        source_id := show.create_source(s, name, data)
                        state.selected_id = show.place_source(sc, source_id)

                        // Start a display source at its native aspect, not the default 400x300.
                        if state.kind_choice == .Display {
                            if placement := show.find_placement(sc, state.selected_id); placement != nil {
                                if src := show.find_source(s, source_id); src != nil {
                                    fit_to_canvas(placement, src, outputs, canvas_w, canvas_h)
                                }
                            }
                        }

                        state.name_buf      = {}
                        state.kind_choice   = .Color
                        state.audio_choice  = 0
                        state.output_choice = 0
                        im.CloseCurrentPopup()
                    }
                }
                im.SameLine()
                if im.Button("Cancel") {
                    state.name_buf      = {}
                    state.kind_choice   = .Color
                    state.audio_choice  = 0
                    state.output_choice = 0
                    im.CloseCurrentPopup()
                }
                im.EndPopup()
            }

            if len(sc.sources) == 0 {
                im.TextDisabled("No sources in this scene")
            }

            to_delete := -1

            for &placement, i in sc.sources {
                src := show.find_source(s, placement.source_id)
                if src == nil do continue

                id_cstr := strings.clone_to_cstring(placement.id, context.temp_allocator)
                im.PushID(id_cstr)

                // Kind icon + name fill the row; the eye toggle overlays its right end.
                right_x := im.GetCursorPosX() + im.GetContentRegionAvail().x
                label := fmt.ctprintf("%s  %s", source_icon(src.data), src.name)
                if !placement.visible {
                    im.PushStyleColorVec4(.Text, rgba(OUTLINE))
                }
                if im.Selectable(label, state.selected_id == placement.id, {.AllowOverlap}) {
                    state.selected_id = placement.id
                }
                if !placement.visible {
                    im.PopStyleColor()
                }

                if im.BeginPopupContextItem() {
                    if im.MenuItem("Delete") {
                        to_delete = i
                    }
                    im.EndPopup()
                }

                eye := im.GetFrameHeight()
                im.SameLine()
                im.SetCursorPosX(right_x - eye)
                im.PushStyleColorVec4(.Button, rgba(0, 0))
                im.PushStyleColorVec4(.ButtonHovered, rgba(SURFACE_HIGHEST))
                im.PushStyleColorVec4(.ButtonActive, rgba(OUTLINE_VARIANT))
                im.PushStyleColorVec4(.Text, rgba(placement.visible ? TEXT_VARIANT : OUTLINE))
                if im.Button(placement.visible ? ICON_EYE : ICON_EYE_SLASH, {eye, eye}) {
                    push_action(actions, action.Action_Toggle_Source_Visible{scene_id = sc.id, source_id = placement.source_id})
                }
                im.PopStyleColor(4)

                im.PopID()
            }

            if placement := show.find_placement(sc, state.selected_id); placement != nil {
                if src := show.find_source(s, placement.source_id); src != nil {
                    im.Separator()

                    // Geometry controls are visual-sources-only; audio has no canvas position.
                    _, is_audio := src.data.(show.Audio_Source_Data)

                    if !is_audio {
                        im.DragFloat("X", &placement.x)
                        im.DragFloat("Y", &placement.y)
                        im.DragFloat("W", &placement.w)
                        im.DragFloat("H", &placement.h)
                    }

                    // The colour swatch is a per-placement tint, not part of the shared source.
                    switch &d in src.data {
                    case show.Color_Source_Data:
                        im.ColorEdit4("Color", &placement.color)
                    case show.Display_Source_Data:
                        draw_output_picker(&d, outputs)
                    case show.Audio_Source_Data:
                        draw_audio_picker(src.id, &d, devices, actions)
                    case show.Image_Source_Data:
                        if d.path != "" {
                            im.TextWrapped(fmt.ctprintf("Path: %v", d.path))
                        } else {
                            im.TextDisabled("No path set")
                        }
                        if d.lost {
                            im.TextDisabled("Failed to load")
                        } else if d.texture != nil {
                            im.Text(fmt.ctprintf("%v x %v", d.width, d.height))
                        }
                        if im.Button("Browse...") {
                            if picked, pick_ok := platform.open_image_dialog(); pick_ok {
                                if d.srv != nil     { d.srv->Release();     d.srv = nil }
                                if d.texture != nil { d.texture->Release(); d.texture = nil }
                                if d.path != "" do delete(d.path)
                                d.path   = picked
                                d.width  = 0
                                d.height = 0
                                d.lost   = false
                            }
                        }
                        im.SameLine()
                        if im.Button("Reload") && d.path != "" {
                            if d.srv != nil     { d.srv->Release();     d.srv = nil }
                            if d.texture != nil { d.texture->Release(); d.texture = nil }
                            d.width  = 0
                            d.height = 0
                            d.lost   = false
                        }
                    case show.Window_Source_Data:
                        draw_window_picker(&d, state)

                    case show.Camera_Source_Data:
                        draw_camera_picker(&d, state)
                    }
                    if !is_audio {
                        if im.Button("Fit to canvas") {
                            fit_to_canvas(placement, src, outputs, canvas_w, canvas_h)
                        }
                    }
                }
            }

            if to_delete >= 0 {
                removed_id := show.remove_placement(sc, to_delete)

                if state.selected_id == removed_id {
                    state.selected_id = ""
                    if len(sc.sources) > 0 {
                        state.selected_id = sc.sources[min(to_delete, len(sc.sources) - 1)].id
                    }
                }
            }
        }
    }

    panel_end(p)
}

// Camera picker: stops the old reader and stores the new identity, but never
// starts a reader itself -- the main loop's lazy-start check does that.
@(private="file")
draw_camera_picker :: proc(d: ^show.Camera_Source_Data, state: ^Sources_State) {
    if d.friendly_name != "" {
        im.TextWrapped(fmt.ctprintf("Device: %v", d.friendly_name))
    } else {
        im.TextDisabled("No device selected")
    }
    if d.cam != nil && intrinsics.atomic_load(&d.cam.lost) {
        im.TextDisabled("Reconnecting...")
    } else if d.texture != nil {
        im.Text(fmt.ctprintf("%v x %v", d.width, d.height))
    }

    if im.Button("Pick Camera...") {
        state.camera_picker_list = capture.enumerate_cameras()
        im.OpenPopup("Pick Camera")
    }

    if im.BeginPopupModal("Pick Camera") {
        if len(state.camera_picker_list) == 0 {
            im.TextDisabled("No cameras found")
        }
        // Freed after the loop, for the same reason as the window picker above.
        picked := -1
        for dev, i in state.camera_picker_list {
            label := fmt.ctprintf("%v", dev.friendly_name)
            if im.Selectable(label, false) {
                picked = i
                break
            }
        }

        if picked >= 0 {
            dev := state.camera_picker_list[picked]
            if d.cam != nil {
                capture.camera_stop(d.cam)
                d.cam = nil
            }
            if d.srv != nil     { d.srv->Release();     d.srv = nil }
            if d.texture != nil { d.texture->Release(); d.texture = nil }
            d.width  = 0
            d.height = 0

            if d.symlink       != "" do delete(d.symlink)
            if d.friendly_name != "" do delete(d.friendly_name)
            d.symlink       = strings.clone(dev.symlink)
            d.friendly_name = strings.clone(dev.friendly_name)

            capture.destroy_camera_list(state.camera_picker_list)
            state.camera_picker_list = nil
            im.CloseCurrentPopup()
        }

        im.Separator()
        if im.Button("Cancel") {
            capture.destroy_camera_list(state.camera_picker_list)
            state.camera_picker_list = nil
            im.CloseCurrentPopup()
        }
        im.EndPopup()
    }
}

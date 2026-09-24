package ui

import "core:log"
import "core:strings"
import im "libs:odin-imgui"

import "../action"
import "../show"

Scenes_State :: struct {
    active_id:   string, // mirrored from main each frame; "" == no scene. Change it by pushing Set_Scene.
    name_buf:    [128]u8,
}

init_scenes_state :: proc() -> Scenes_State {
    return Scenes_State{}
}

draw_scenes :: proc(state: ^Scenes_State, s: ^show.Show, actions: ^action.Envelope_Queue) {
    p := panel_begin("Scenes", "SCENES")
    if p.visible {
        add_scene := panel_header_button("+", "Add scene")
        panel_header_end()

        if add_scene {
            im.OpenPopup("Create Scene")
        }

        if im.BeginPopupModal("Create Scene") {
            im.InputText("Name", cstring(&state.name_buf[0]), len(state.name_buf))
            if im.Button("Create") {
                n := strings.index_byte(string(state.name_buf[:]), 0)
                if n < 0 {
                    log.warn("scene name truncated at 128 bytes (no NUL found)")
                    n = len(state.name_buf)
                }
                name := string(state.name_buf[:n])

                if len(name) == 0 {
                    log.debug("empty scene name rejected")
                } else {
                    // A new scene goes live right away, as before.
                    push_action(actions, action.Action_Set_Scene{scene_id = show.create_scene(s, name)})
                    state.name_buf = {}
                    im.CloseCurrentPopup()
                }
            }
            im.SameLine()
            if im.Button("Cancel") {
                state.name_buf = {}
                im.CloseCurrentPopup()
            }
            im.EndPopup()
        }

        to_delete := -1

        for &sc, i in s.scenes {
            label := strings.clone_to_cstring(sc.name, context.temp_allocator)
            if im.Selectable(label, state.active_id == sc.id) && state.active_id != sc.id {
                push_action(actions, action.Action_Set_Scene{scene_id = sc.id})
            }

            if im.BeginPopupContextItem() {
                if im.MenuItem("Delete") {
                    to_delete = i
                }
                im.EndPopup()
            }
        }

        if to_delete >= 0 {
            // Compare before removing: remove_scene frees the scene's id.
            was_active := s.scenes[to_delete].id == state.active_id
            show.remove_scene(s, to_delete)

            if was_active {
                // Deleting the live scene moves it to whatever slid into the
                // vacated slot, else the new last scene. With no scenes left,
                // main clears it (app.ensure_active_scene).
                if len(s.scenes) > 0 {
                    neighbour := s.scenes[min(to_delete, len(s.scenes) - 1)].id
                    push_action(actions, action.Action_Set_Scene{scene_id = neighbour})
                }
                // The mirror names a deleted scene for the rest of this frame.
                state.active_id = ""
            }
        }
    }

    panel_end(p)
}

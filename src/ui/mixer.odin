package ui

import im "libs:odin-imgui"
import "../action"
import "../show"
import "core:fmt"
import "core:math"
import "core:strings"

Mixer_State :: struct {

}

init_mixer_state :: proc() -> Mixer_State {
    return Mixer_State{}
}

@(private="file")
audio_src_label :: proc (name: string) -> cstring {
    return fmt.ctprintf("%v", name)
}

draw_mixer :: proc(state: ^Mixer_State, scenes: ^Scenes_State, s: ^show.Show, actions: ^action.Envelope_Queue) {
    p := panel_begin("Audio Mixer", "AUDIO MIXER")
    if p.visible {
        panel_header_end()

        sc := show.find_scene(s, scenes.active_id)
        if sc == nil {
            im.TextDisabled("No Scenes Selected")
        } else {
            any := false
            for placement in sc.sources {
                if !placement.visible do continue
                src := show.find_source(s, placement.source_id)
                if src == nil do continue

                d, is_audio := &src.data.(show.Audio_Source_Data)
                if !is_audio do continue
                any = true

                id_cstr := strings.clone_to_cstring(src.id, context.temp_allocator)
                im.PushID(id_cstr)

                // Name, then the level readout and mute toggle on the right.
                right_x := im.GetCursorPosX() + im.GetContentRegionAvail().x
                im.TextUnformatted(audio_src_label(src.name))

                peak: f32 = d.stream != nil ? d.stream.peak : 0
                db := peak_db(peak)

                // Placement-level hard mute (mute_override) combines with the
                // source's own base mute; the button here toggles the base
                // mute, same as before -- per-scene override isn't exposed here yet.
                muted := d.params.muted || placement.mute_override

                mute_w := im.GetFrameHeight()
                readout := muted ? cstring("muted") : fmt.ctprintf("%.1f dB", db)
                im.PushFontFloat(fonts.mono, FONT_SIZE_TELEMETRY)
                readout_w := im.CalcTextSize(readout).x
                im.SameLine()
                im.SetCursorPosX(right_x - mute_w - readout_w - 8 * ui_scale())
                im.PushStyleColorVec4(.Text, rgba(TEXT_VARIANT))
                im.TextUnformatted(readout)
                im.PopStyleColor()
                im.PopFont()

                im.SameLine()
                im.SetCursorPosX(right_x - mute_w)
                im.PushStyleColorVec4(.Button, rgba(0, 0))
                im.PushStyleColorVec4(.ButtonHovered, rgba(SURFACE_HIGHEST))
                im.PushStyleColorVec4(.ButtonActive, rgba(OUTLINE_VARIANT))
                im.PushStyleColorVec4(.Text, rgba(muted ? DANGER : TEXT_VARIANT))
                if im.Button(muted ? ICON_VOLUME_XMARK : ICON_VOLUME_HIGH, {mute_w, mute_w}) {
                    push_action(actions, action.Action_Toggle_Mute{source_id = src.id})
                }
                im.PopStyleColor(4)

                draw_meter(muted ? -60 : db)

                im.PushStyleColorVec4(.FrameBg, rgba(SLATE_SURFACE))
                // Edit a copy; the change lands next frame when main dispatches it.
                volume := d.params.volume
                if im.SliderFloat("##vol", &volume, 0, 1, "%.2f") {
                    push_action(actions, action.Action_Set_Volume{source_id = src.id, volume = volume})
                }
                im.PopStyleColor()

                im.Spacing()
                im.PopID()
            }
            if !any do im.TextDisabled("No audio sources in this scene")
        }
    }
    panel_end(p)
}

// Linear peak (0..1) to dBFS, floored at the meter's bottom.
@(private="file")
peak_db :: proc(peak: f32) -> f32 {
    if peak <= 0.000_001 {
        return METER_FLOOR_DB
    }
    return max(20 * math.log10(peak), METER_FLOOR_DB)
}

METER_FLOOR_DB :: f32(-60)

// Horizontal level meter: green below -12 dB, amber to -3 dB, red above.
@(private="file")
draw_meter :: proc(db: f32) {
    scale  := ui_scale()
    height := 6 * scale
    width  := im.GetContentRegionAvail().x

    origin := im.GetCursorScreenPos()
    p_min  := origin
    p_max  := im.Vec2{origin.x + width, origin.y + height}

    dl := im.GetWindowDrawList()
    im.DrawList_AddRectFilled(dl, p_min, p_max, col32(SLATE_SURFACE), height * 0.5)

    norm := clamp((db - METER_FLOOR_DB) / -METER_FLOOR_DB, 0, 1)
    if norm > 0 {
        color := col32(SUCCESS)
        switch {
        case db > -3:  color = col32(DANGER)
        case db > -12: color = col32(WARNING)
        }
        fill_max := im.Vec2{origin.x + width * norm, p_max.y}
        im.DrawList_AddRectFilled(dl, p_min, fill_max, color, height * 0.5)
    }

    im.Dummy({width, height})
}

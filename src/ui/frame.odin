package ui

import "core:fmt"
import "core:time"
import im "libs:odin-imgui"

import "../action"
import "../show"

// Fixed chrome around the dockspace: top bar, left sidebar, bottom status bar.
// Each is an undecorated window pinned to the viewport's work area, which is then
// shrunk so DockSpaceOverViewport only covers what is left over.

SIDEBAR_WIDTH  :: 240 // unscaled; multiplied by ui_scale()
TOP_BAR_PAD_Y  :: 12  // vertical frame padding that sets the top bar's height

@(private="file")
CHROME_FLAGS :: im.WindowFlags{
    .NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoScrollbar,
    .NoScrollWithMouse, .NoSavedSettings, .NoDocking, .NoBringToFrontOnFocus, .NoNavFocus,
}

// DPI scale, derived from the font: style sizes are already scaled, raw constants are not.
ui_scale :: proc() -> f32 {
    if s := im.GetFontSize() / FONT_SIZE_BODY; s > 0 {
        return s
    }
    return 1
}

// Draws the chrome and shrinks the viewport work area to the remaining region.
draw_chrome :: proc(
    state: ^State,
    show_cfg: ^show.Show,
    shows: []show.Show_Info,
) {
    track_output_times(&state.controls)

    vp := im.GetMainViewport()
    origin, size := vp.WorkPos, vp.WorkSize
    scale := ui_scale()

    top_h    := im.GetFontSize() + TOP_BAR_PAD_Y * 2 * scale
    status_h := im.GetFrameHeight()
    side_w   := SIDEBAR_WIDTH * scale
    body_h   := size.y - top_h - status_h

    draw_top_bar(state, show_cfg, shows, origin, {size.x, top_h})
    draw_sidebar(state, {origin.x, origin.y + top_h}, {side_w, body_h})
    draw_status_bar(state, {origin.x, origin.y + size.y - status_h}, {size.x, status_h})

    // Consumed by DockSpaceOverViewport; ImGui recomputes both every NewFrame.
    vp.WorkPos  = {origin.x + side_w, origin.y + top_h}
    vp.WorkSize = {size.x - side_w, body_h}
}

@(private="file")
draw_top_bar :: proc(
    state: ^State,
    show_cfg: ^show.Show,
    shows: []show.Show_Info,
    pos, size: im.Vec2,
) {
    im.SetNextWindowPos(pos)
    im.SetNextWindowSize(size)
    im.PushStyleVarVec2(.FramePadding, {12 * ui_scale(), TOP_BAR_PAD_Y * ui_scale()})
    im.PushStyleVarVec2(.WindowPadding, {0, 0})
    im.PushStyleVar(.WindowRounding, 0)
    im.PushStyleVarVec2(.WindowMinSize, {0, 0}) // see draw_status_bar
    im.PushStyleColorVec4(.WindowBg, rgba(SURFACE))
    im.PushStyleColorVec4(.MenuBarBg, rgba(SURFACE))

    if im.Begin("##TopBar", nil, CHROME_FLAGS | {.MenuBar}) {
        if im.BeginMenuBar() {
            im.PushFontFloat(fonts.semibold, FONT_SIZE_HEADLINE)
            im.TextUnformatted("StreamSmith")
            im.PopFont()

            im.Dummy({16 * ui_scale(), 0})
            draw_menus(state, show_cfg, shows)

            // Right-aligned: live/recording pill, then the settings button.
            gear := fmt.ctprintf("%s", ICON_GEAR)
            gear_w := im.CalcTextSize(gear).x + im.GetStyle().FramePadding.x * 2
            status := output_pill_label(&state.controls)
            status_w: f32 = 0
            if status != nil {
                status_w = im.CalcTextSize(status).x + 16 * ui_scale()
            }

            im.SetCursorPosX(im.GetWindowWidth() - gear_w - status_w - 12 * ui_scale())
            if status != nil {
                im.PushStyleColorVec4(.Text, rgba(state.controls.streaming ? DANGER : PRIMARY_SOFT))
                im.TextUnformatted(status)
                im.PopStyleColor()
            }
            if im.Button(gear) {
                state.show_settings = true
            }
            im.EndMenuBar()
        }
    }
    im.End()

    im.PopStyleColor(2)
    im.PopStyleVar(4)
}

@(private="file")
draw_sidebar :: proc(state: ^State, pos, size: im.Vec2) {
    scale := ui_scale()
    c := &state.controls

    im.SetNextWindowPos(pos)
    im.SetNextWindowSize(size)
    im.PushStyleVar(.WindowRounding, 0)
    im.PushStyleVarVec2(.WindowPadding, {16 * scale, 16 * scale})
    im.PushStyleColorVec4(.WindowBg, rgba(SURFACE_LOW))

    if im.Begin("##Sidebar", nil, CHROME_FLAGS) {
        im.PushFontFloat(fonts.semibold, FONT_SIZE_HEADLINE)
        im.TextUnformatted("Live")
        im.PopFont()
        im.TextDisabled("Controls")
        im.Dummy({0, 12 * scale})

        button_h := im.GetFrameHeight() + 10 * scale

        // Streaming
        if c.streaming {
            if wide_button(fmt.ctprintf("%s  Stop Stream", ICON_TOWER_BROADCAST), DANGER, 0xf87171, button_h) {
                push_action(state.actions, action.Action_Stop_Streaming{})
            }
        } else {
            if wide_button(fmt.ctprintf("%s  Go Live", ICON_TOWER_BROADCAST), PRIMARY, PRIMARY_DEEP, button_h) {
                push_action(state.actions, action.Action_Start_Streaming{})
            }
        }

        // Recording
        if c.finalizing {
            im.BeginDisabled(true)
            wide_button("Finalizing...", SURFACE_HIGHEST, SURFACE_HIGHEST, button_h)
            im.EndDisabled()
        } else if c.recording {
            if wide_button(fmt.ctprintf("%s  Stop Recording", ICON_STOP), SURFACE_HIGHEST, OUTLINE_VARIANT, button_h) {
                push_action(state.actions, action.Action_Stop_Recording{})
            }
        } else {
            if wide_button(fmt.ctprintf("%s  Start Recording", ICON_RECORD), SURFACE_HIGHEST, OUTLINE_VARIANT, button_h) {
                push_action(state.actions, action.Action_Start_Recording{})
            }
        }

        if c.recording {
            im.PushFontFloat(fonts.mono, FONT_SIZE_TELEMETRY)
            im.PushStyleColorVec4(.Text, rgba(DANGER))
            im.TextUnformatted(fmt.ctprintf("%s REC %s", ICON_RECORD, elapsed_string(c.rec_started)))
            im.PopStyleColor()
            im.PopFont()
        }

        // Settings sits at the bottom of the sidebar.
        if avail := im.GetContentRegionAvail(); avail.y > im.GetFrameHeight() {
            im.SetCursorPosY(im.GetCursorPosY() + avail.y - im.GetFrameHeight())
        }
        if wide_button(fmt.ctprintf("%s  Settings", ICON_GEAR), SURFACE, SURFACE_HIGHEST, 0) {
            state.show_settings = true
        }
    }
    im.End()

    im.PopStyleColor()
    im.PopStyleVar(2)
}

@(private="file")
draw_status_bar :: proc(state: ^State, pos, size: im.Vec2) {
    scale := ui_scale()

    im.SetNextWindowPos(pos)
    im.SetNextWindowSize(size)
    im.PushStyleVar(.WindowRounding, 0)
    im.PushStyleVarVec2(.WindowPadding, {16 * scale, 4 * scale})
    // The status bar is thinner than style.WindowMinSize, and ImGui would grow
    // it past the bottom of the viewport. With multi-viewport on, a window that
    // doesn't fit the host viewport is given its own OS window -- which is how
    // the bar ended up floating loose instead of sitting in the frame.
    im.PushStyleVarVec2(.WindowMinSize, {0, 0})
    im.PushStyleColorVec4(.WindowBg, rgba(SURFACE_LOWEST))

    if im.Begin("##StatusBar", nil, CHROME_FLAGS) {
        im.PushFontFloat(fonts.mono, FONT_SIZE_TELEMETRY)

        version := fmt.ctprintf("StreamSmith %s", state.version)
        im.PushStyleColorVec4(.Text, rgba(TEXT_VARIANT))
        im.TextUnformatted(version)
        im.PopStyleColor()

        right := status_right_label(&state.controls)
        if right != nil {
            w := im.CalcTextSize(right).x
            im.SameLine()
            im.SetCursorPosX(im.GetWindowWidth() - w - 16 * scale)
            im.PushStyleColorVec4(.Text, rgba(DANGER))
            im.TextUnformatted(right)
            im.PopStyleColor()
        }

        im.PopFont()
    }
    im.End()

    im.PopStyleColor()
    im.PopStyleVar(3)
}

PANEL_GUTTER   :: 6  // dock-window padding; becomes the gap between cards
PANEL_PADDING  :: 12 // inside the card
PANEL_ROUNDING :: 12

// A docked panel drawn as a rounded card. The dock window itself is painted in the
// page background and holds only padding; the content goes in a rounded child, since
// docked windows are always square-cornered and flush against each other.
Panel :: struct {
    open:    bool, // dock window open -- End() is required either way
    visible: bool, // card is visible; draw content only when true
}

// Right edge of the header row, in window-local coords. Header buttons are laid
// out right-to-left from here; panels are never nested, so one cursor is enough.
@(private="file")
header_x: f32

panel_begin :: proc(name: cstring, title: cstring) -> Panel {
    scale := ui_scale()

    im.PushStyleColorVec4(.WindowBg, rgba(BG))
    im.PushStyleVarVec2(.WindowPadding, {PANEL_GUTTER * scale, PANEL_GUTTER * scale})

    p: Panel
    p.open = im.Begin(name)
    im.PopStyleVar()

    if p.open {
        im.PushStyleColorVec4(.ChildBg, rgba(SURFACE))
        im.PushStyleVar(.ChildRounding, PANEL_ROUNDING * scale)
        im.PushStyleVarVec2(.WindowPadding, {PANEL_PADDING * scale, PANEL_PADDING * scale})
        p.visible = im.BeginChild("##card", {0, 0}, {.Borders})
        im.PopStyleVar(2)
    }

    if p.visible {
        header_x = im.GetCursorPosX() + im.GetContentRegionAvail().x

        // Header buttons are frame-height, so centre the title against them.
        im.AlignTextToFramePadding()
        im.PushFontFloat(fonts.medium, FONT_SIZE_LABEL)
        im.PushStyleColorVec4(.Text, rgba(TEXT_VARIANT))
        im.TextUnformatted(title)
        im.PopStyleColor()
        im.PopFont()
    }
    return p
}

// Header action button, placed right-to-left. Call between panel_begin and
// panel_header_end; returns true when clicked.
panel_header_button :: proc(icon: cstring, tooltip: cstring = nil) -> bool {
    size := im.GetFrameHeight()
    header_x -= size

    im.SameLine()
    im.SetCursorPosX(header_x)

    im.PushStyleColorVec4(.Button, rgba(0, 0))
    im.PushStyleColorVec4(.ButtonHovered, rgba(SURFACE_HIGHEST))
    im.PushStyleColorVec4(.ButtonActive, rgba(OUTLINE_VARIANT))
    im.PushStyleColorVec4(.Text, rgba(TEXT_VARIANT))
    clicked := im.Button(icon, {size, size})
    im.PopStyleColor(4)

    if tooltip != nil && im.IsItemHovered() {
        im.SetTooltip(tooltip)
    }
    return clicked
}

// Closes the header row: divider, then content starts below.
panel_header_end :: proc() {
    im.Separator()
    im.Spacing()
}

panel_end :: proc(p: Panel) {
    if p.open {
        im.EndChild()
        im.PopStyleColor() // ChildBg
    }
    im.End()
    im.PopStyleColor() // WindowBg
}

// Full-width button in explicit colors; height 0 means the default frame height.
@(private="file")
wide_button :: proc(label: cstring, bg, bg_hover: u32, height: f32) -> bool {
    im.PushStyleColorVec4(.Button, rgba(bg))
    im.PushStyleColorVec4(.ButtonHovered, rgba(bg_hover))
    im.PushStyleColorVec4(.ButtonActive, rgba(bg_hover))
    clicked := im.Button(label, {-1, height})
    im.PopStyleColor(3)
    return clicked
}

// Stamps start times on the off->on edges so the UI can show elapsed durations.
@(private="file")
track_output_times :: proc(c: ^Controls_State) {
    if c.recording {
        if c.rec_started._nsec == 0 {
            c.rec_started = time.now()
        }
    } else {
        c.rec_started = {}
    }
    if c.streaming {
        if c.stream_started._nsec == 0 {
            c.stream_started = time.now()
        }
    } else {
        c.stream_started = {}
    }
}

@(private="file")
elapsed_string :: proc(start: time.Time) -> string {
    if start._nsec == 0 {
        return "00:00:00"
    }
    secs := int(time.duration_seconds(time.since(start)))
    return fmt.tprintf("%02d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
}

@(private="file")
output_pill_label :: proc(c: ^Controls_State) -> cstring {
    switch {
    case c.streaming: return fmt.ctprintf("%s LIVE %s", ICON_RECORD, elapsed_string(c.stream_started))
    case c.recording: return fmt.ctprintf("%s REC %s", ICON_RECORD, elapsed_string(c.rec_started))
    case c.finalizing: return "Finalizing..."
    }
    return nil
}

@(private="file")
status_right_label :: proc(c: ^Controls_State) -> cstring {
    switch {
    case c.streaming && c.recording: return fmt.ctprintf("LIVE + REC %s", elapsed_string(c.rec_started))
    case c.streaming:                return fmt.ctprintf("LIVE %s", elapsed_string(c.stream_started))
    case c.recording:                return fmt.ctprintf("REC %s", elapsed_string(c.rec_started))
    }
    return nil
}

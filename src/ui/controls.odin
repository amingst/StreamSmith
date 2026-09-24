package ui

import "core:time"

// Output state mirrored from main; the sidebar's buttons push output actions
// (see frame.odin), which main dispatches since it owns the encoder.
Controls_State :: struct {
    recording: bool, // mirrored from main each frame; ui can't query the encoder directly
    streaming: bool, // mirrored from main each frame
    finalizing: bool, // previous recording's MP4 sink still draining/finalizing

    // Stamped by the UI on the off->on edge, for the elapsed timers. Zero when idle.
    rec_started:    time.Time,
    stream_started: time.Time,
}

init_controls_state :: proc() -> Controls_State {
    return Controls_State{}
}

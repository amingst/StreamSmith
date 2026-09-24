package app

import "core:fmt"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "../action"
import "../applog"
import "../audio"
import "../config"
import "../encode"
import "../mp4"
import "../render"
import "../rtmp"
import "../show"

Action_Error :: enum {
	None, // ok
	Not_Found,
	Invalid_Argument,
	Already_Active,
	Not_Configured,
	Failed,
}

Action_Result :: struct {
	error:   Action_Error,
	message: string,     // temp-allocated or a literal; empty when ok
	value:   Maybe(bool), // toggles report the resulting state
}

Dispatch_Context :: struct {
	output:          ^Output_State,
	paths:           ^config.Paths,
	target:          ^render.Target,
	show_cfg:        ^show.Show,
	active_scene_id: ^string, // owned by main (allocated with context.allocator); see ensure_active_scene
	log_sink:        ^applog.Sink,
}

// Named action_ok/action_err rather than ok/err: `x, ok := ...` is common in
// this package and would shadow them.
@(private)
action_ok :: proc(value: Maybe(bool) = nil) -> Action_Result {
	return {value = value}
}

@(private)
action_err :: proc(e: Action_Error, format: string, args: ..any) -> Action_Result {
	return {error = e, message = fmt.tprintf(format, ..args)}
}

dispatch_action :: proc(env: ^action.Envelope, ctx: ^Dispatch_Context) -> Action_Result {
	result: Action_Result
	switch a in env.action {
	case action.Action_Start_Recording:       result = start_recording(ctx)
	case action.Action_Stop_Recording:        result = stop_recording(ctx)
	case action.Action_Toggle_Recording:      result = ctx.output.recording ? stop_recording(ctx) : start_recording(ctx)
	case action.Action_Start_Streaming:       result = start_streaming(ctx)
	case action.Action_Stop_Streaming:        result = stop_streaming(ctx)
	case action.Action_Toggle_Streaming:      result = ctx.output.streaming ? stop_streaming(ctx) : start_streaming(ctx)
	case action.Action_Set_Scene:             result = set_scene(ctx, a.scene_id)
	case action.Action_Set_Mute:              result = set_mute(ctx, a.source_id, a.muted)
	case action.Action_Toggle_Mute:           result = set_mute(ctx, a.source_id, nil)
	case action.Action_Set_Volume:            result = set_volume(ctx, a.source_id, a.volume)
	case action.Action_Set_Source_Visible:    result = set_visible(ctx, a.scene_id, a.source_id, a.visible)
	case action.Action_Toggle_Source_Visible: result = set_visible(ctx, a.scene_id, a.source_id, nil)
	case:                                     result = action_err(.Invalid_Argument, "empty action")
	}
	if result.error != .None {
		log.warnf("action %v from %v failed: %v %s", env.action, env.origin, result.error, result.message)
	}
	return result
}

// ---- Outputs ----
// First output start acquires the encoder, last output stop releases it.
// The show's single stream output feeds both recording and streaming, since
// there's one encode shared across everything, not one per output.

// Acquires the encoder on the first output start.
@(private)
ensure_encoder :: proc(ctx: ^Dispatch_Context, bitrate_kbps: int) -> bool {
	output := ctx.output
	if output.enc != nil do return true
	fps := ctx.show_cfg.video.fps
	if fps <= 0 {
		log.errorf("ensure_encoder: fps is %v, cannot compute frame_duration", fps)
		return false
	}
	encoder_cfg := encode.Encoder_Config{
		width              = ctx.target.width,
		height             = ctx.target.height,
		fps                = u32(fps),
		bitrate            = u32(bitrate_kbps) * 1000,
		audio_sample_rate  = 48000,
		audio_channels     = 2,
		audio_bitrate      = 16000,
		frame_duration     = i64(10_000_000) / i64(fps),
		log_sink           = ctx.log_sink,
	}
	enc, enc_ok := encode.encoder_acquire(encoder_cfg)
	if !enc_ok do return false
	output.enc = enc
	audio.mix_set_encoder(enc) // also restarts the audio block counter for the new timeline
	return true
}

@(private)
start_recording :: proc(ctx: ^Dispatch_Context) -> Action_Result {
	output := ctx.output
	if output.recording do return action_err(.Already_Active, "already recording")
	if output.finalizing_sink != nil {
		return action_err(.Already_Active, "previous recording is still finalizing")
	}
	if ctx.paths.videos == "" {
		return action_err(.Not_Configured, "no videos directory is available")
	}

	stream_output := show.ensure_output(ctx.show_cfg)
	if !ensure_encoder(ctx, stream_output.bitrate_kbps) {
		return action_err(.Failed, "encoder_acquire failed")
	}

	year, month, day := time.date(time.now())
	hour, min, sec := time.clock(time.now())
	filename := fmt.aprintf("recording_%4d-%02d-%02d_%02d-%02d-%02d.mp4",
		year, int(month), day, hour, min, sec)
	defer delete(filename)

	out_path, jerr := filepath.join({ctx.paths.videos, filename})
	if jerr != nil {
		maybe_release_encoder(output)
		return action_err(.Failed, "could not build recording output path: %v", jerr)
	}
	// mp4_sink_start (via mf.begin_mp4_sink -> MFCreateFile) converts this
	// to a wide string synchronously and doesn't retain the Odin string,
	// so it's safe to free right after the call returns.
	defer delete(out_path)

	sink, sink_ok := mp4.mp4_sink_start(output.enc, out_path)
	if !sink_ok {
		maybe_release_encoder(output)
		return action_err(.Failed, "failed to start recording (cause logged above)")
	}
	output.mp4_sink = sink
	output.recording = true
	log.infof("recording started (video+audio) -> %v", out_path)
	return action_ok()
}

// Stopping an output that isn't running is ok, so two stop presses in the
// same frame (e.g. UI and Deck) don't raise an error.
@(private)
stop_recording :: proc(ctx: ^Dispatch_Context) -> Action_Result {
	output := ctx.output
	if !output.recording do return action_ok()
	mp4.mp4_sink_signal_stop(output.mp4_sink)
	output.finalizing_sink = output.mp4_sink
	output.mp4_sink = nil
	output.recording = false
	log.info("recording stop signalled, finalizing")
	return action_ok()
}

@(private)
start_streaming :: proc(ctx: ^Dispatch_Context) -> Action_Result {
	output := ctx.output
	if output.streaming do return action_err(.Already_Active, "already streaming")

	stream_output := show.ensure_output(ctx.show_cfg)
	rtmp_data, is_rtmp := stream_output.data.(show.RTMP_Output_Data)
	if !stream_output.enabled || !is_rtmp || rtmp_data.url == "" || rtmp_data.key == "" {
		return action_err(.Not_Configured, "no stream destination is configured")
	}
	host, app, tc_url, port, parse_ok := rtmp.parse_url(rtmp_data.url, context.temp_allocator)
	if !parse_ok {
		return action_err(.Invalid_Argument,
			"the server URL %q could not be parsed (expected rtmp://host[:port]/app)", rtmp_data.url)
	}

	if !ensure_encoder(ctx, stream_output.bitrate_kbps) {
		return action_err(.Failed, "encoder_acquire failed")
	}

	STREAM_AUDIO_CHANNELS :: 2

	// stream_index 0: a single stream is all this build supports today.
	// A real id generator/registry belongs with fan-out, not here.
	stream, stream_ok := rtmp.rtmp_stream_start(
		output.enc, app, host, port, tc_url,
		rtmp_data.key, STREAM_AUDIO_CHANNELS,
		ctx.log_sink, 0)
	if !stream_ok {
		maybe_release_encoder(output)
		return action_err(.Failed, "failed to start streaming (cause logged above)")
	}
	output.rtmp_stream = stream
	output.streaming = true
	log.infof("streaming started -> %v:%v/%v", host, port, app)
	return action_ok()
}

@(private)
stop_streaming :: proc(ctx: ^Dispatch_Context) -> Action_Result {
	output := ctx.output
	if !output.streaming do return action_ok()
	rtmp.rtmp_stream_close(output.rtmp_stream)
	output.rtmp_stream = nil
	output.streaming = false
	maybe_release_encoder(output)
	log.info("streaming stopped")
	return action_ok()
}

// ---- Scene ----

@(private)
set_scene :: proc(ctx: ^Dispatch_Context, scene_id: string) -> Action_Result {
	sc := show.find_scene(ctx.show_cfg, scene_id)
	if sc == nil do return action_err(.Not_Found, "no scene with id %s", scene_id)
	// Already live is ok, not Already_Active: that code is for outputs only.
	if ctx.active_scene_id^ == sc.id do return action_ok()
	// Keep an owned copy: the action's scene_id is freed after dispatch, and the
	// scene's own id is freed if the UI deletes the scene.
	delete(ctx.active_scene_id^)
	ctx.active_scene_id^ = strings.clone(sc.id)
	return action_ok()
}

// Called each frame after dispatch. Points the active scene at the show's
// first scene when it names no scene in the show: at startup, after a show
// switch, or once the last scene is deleted (then it becomes "").
ensure_active_scene :: proc(active_scene_id: ^string, s: ^show.Show) {
	if show.find_scene(s, active_scene_id^) != nil do return
	if active_scene_id^ == "" && len(s.scenes) == 0 do return
	delete(active_scene_id^)
	active_scene_id^ = len(s.scenes) > 0 ? strings.clone(s.scenes[0].id) : ""
	log.debugf("active scene reset to %q", active_scene_id^)
}

// ---- Audio ----

@(private)
audio_source :: proc(ctx: ^Dispatch_Context, source_id: string) -> (^show.Audio_Source_Data, Action_Result) {
	src := show.find_source(ctx.show_cfg, source_id)
	if src == nil do return nil, action_err(.Not_Found, "no source with id %s", source_id)
	d, is_audio := &src.data.(show.Audio_Source_Data)
	if !is_audio do return nil, action_err(.Invalid_Argument, "source %s has no audio", source_id)
	return d, action_ok()
}

// muted == nil toggles. Base source mute only; placement mute_override isn't touched.
@(private)
set_mute :: proc(ctx: ^Dispatch_Context, source_id: string, muted: Maybe(bool)) -> Action_Result {
	d, result := audio_source(ctx, source_id)
	if result.error != .None do return result
	d.muted = muted.? or_else !d.muted
	return action_ok(d.muted)
}

// Linear 0..1, same as params.volume. Out-of-range is rejected, not clamped,
// so a misbehaving client sees an error.
@(private)
set_volume :: proc(ctx: ^Dispatch_Context, source_id: string, volume: f32) -> Action_Result {
	d, result := audio_source(ctx, source_id)
	if result.error != .None do return result
	if math.is_nan(volume) || volume < 0 || volume > 1 {
		return action_err(.Invalid_Argument, "volume %v is outside 0..1", volume)
	}
	d.volume = volume
	return action_ok()
}

// ---- Visibility ----

// visible == nil toggles. Applies to every placement of the source in the
// scene; a toggle resolves from the first one so they end up in sync.
@(private)
set_visible :: proc(ctx: ^Dispatch_Context, scene_id: string, source_id: string, visible: Maybe(bool)) -> Action_Result {
	sc := show.find_scene(ctx.show_cfg, scene_id)
	if sc == nil do return action_err(.Not_Found, "no scene with id %s", scene_id)

	found := false
	resolved: bool
	for &p in sc.sources {
		if p.source_id != source_id do continue
		if !found do resolved = visible.? or_else !p.visible
		found = true
		p.visible = resolved
	}
	if !found {
		return action_err(.Not_Found, "no source with id %s in scene %s", source_id, scene_id)
	}
	return action_ok(resolved)
}

package app

import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:time"

import "../action"
import "../remote"
import "../remote/protocol"
import "../show"

// A dragged slider changes volume every frame; clients only need ~10 Hz.
VOLUME_EVENT_INTERVAL :: 100 * time.Millisecond

// The main-loop half of the remote server: it answers the requests that were
// dispatched this frame, then rebuilds the state snapshot, turns the
// difference from last frame into events, and publishes the new snapshot for
// state.get.
//
// Events come from the diff rather than from the actions, so a change made in
// the UI, by a hotkey or by an output stopping by itself is reported exactly
// like a change a client asked for.
Remote_Bridge :: struct {
	server: ^remote.Server, // nil when the remote server is off; everything no-ops

	// Two arenas: the new snapshot is built into one while the previous one is
	// still needed for the diff, then they swap.
	arenas:  [2]virtual.Arena,
	current: int,
	prev:     protocol.Snapshot,
	has_prev: bool,

	volume_sent: map[string]Volume_Sent, // keyed by a source id owned by this map
	allocator:   mem.Allocator,
}

@(private)
Volume_Sent :: struct {
	value: f32,
	at:    time.Tick,
}

// One event before it is serialized; kept separate so the diff can be tested
// without a server.
@(private)
Diff_Event :: struct {
	name: protocol.Event_Name,
	data: json.Value,
}

bridge_init :: proc(bridge: ^Remote_Bridge, server: ^remote.Server, allocator := context.allocator) {
	bridge.server = server
	bridge.allocator = allocator
	bridge.volume_sent = make(map[string]Volume_Sent, 16, allocator)
	for &arena in bridge.arenas {
		if err := virtual.arena_init_growing(&arena); err != nil {
			log.errorf("remote bridge: arena_init_growing failed (%v); remote state updates are off", err)
			bridge.server = nil
			return
		}
	}
}

// Points the bridge at a different server (or none, after the remote settings
// turn it off). The next update republishes from scratch, so a client that
// connects to the new server gets a full snapshot.
bridge_set_server :: proc(bridge: ^Remote_Bridge, server: ^remote.Server) {
	bridge.server = server
	bridge.has_prev = false
	forget_volume_sent(&bridge.volume_sent, bridge.allocator)
}

bridge_destroy :: proc(bridge: ^Remote_Bridge) {
	for key in bridge.volume_sent {
		delete(key, bridge.allocator)
	}
	delete(bridge.volume_sent)
	for &arena in bridge.arenas {
		virtual.arena_destroy(&arena)
	}
	bridge^ = {}
}

// Routes one dispatched action's result back to the client that asked for it.
// Call it while the envelope is still alive, before queue_release.
bridge_respond :: proc(bridge: ^Remote_Bridge, env: ^action.Envelope, result: Action_Result) {
	if bridge.server == nil do return
	reply, is_remote := env.reply.?
	if !is_remote do return

	payload: []u8
	if result.error == .None {
		payload = protocol.encode_response_ok(
			reply.request_id, result_body(env.action, result, context.temp_allocator), context.temp_allocator)
	} else {
		payload = protocol.encode_response_err(
			reply.request_id, error_code_for(result.error), result.message, context.temp_allocator)
	}
	remote.server_respond(bridge.server, reply.client_id, payload)
}

// Snapshot, diff and publish. Runs once per frame, after the queue has been
// dispatched and the active scene repaired.
bridge_update :: proc(
	bridge:          ^Remote_Bridge,
	show_cfg:        ^show.Show,
	active_scene_id: string,
	output:          ^Output_State,
	tick: Maybe(time.Tick) = nil, // the tests pin this
) {
	if bridge.server == nil do return
	now := tick.? or_else time.tick_now()

	next := 1 - bridge.current
	virtual.arena_free_all(&bridge.arenas[next])
	snapshot := build_snapshot(
		show_cfg, active_scene_id, output, virtual.arena_allocator(&bridge.arenas[next]))

	if bridge.has_prev {
		for event in snapshot_diff(&bridge.prev, &snapshot, &bridge.volume_sent, now, bridge.allocator, context.temp_allocator) {
			payload := protocol.encode_event(event.name, event.data, context.temp_allocator)
			remote.server_broadcast(bridge.server, protocol.event_topics[event.name], payload)
		}
	} else {
		seed_volume_sent(&snapshot, &bridge.volume_sent, now, bridge.allocator)
	}

	// The snapshot is only re-serialized when something actually changed; at
	// 60 fps most frames change nothing.
	if !bridge.has_prev || !snapshots_equal(&bridge.prev, &snapshot) {
		remote.server_publish_snapshot(bridge.server, protocol.encode_snapshot(&snapshot, context.temp_allocator))
	}

	bridge.prev = snapshot
	bridge.has_prev = true
	bridge.current = next
}

// ---- Snapshot ----

@(private)
build_snapshot :: proc(
	show_cfg:        ^show.Show,
	active_scene_id: string,
	output:          ^Output_State,
	allocator:       mem.Allocator,
) -> (snapshot: protocol.Snapshot) {
	snapshot.show = {id = show_cfg.id, name = show_cfg.name}
	if active_scene_id != "" do snapshot.active_scene_id = active_scene_id

	scenes := make([dynamic]protocol.Snapshot_Scene, 0, len(show_cfg.scenes), allocator)
	for &scene in show_cfg.scenes {
		// One entry per distinct source, in the layer order of its first
		// placement -- the same view source.toggleVisible resolves from.
		sources := make([dynamic]protocol.Snapshot_Placement, 0, len(scene.sources), allocator)
		for placement in scene.sources {
			seen := false
			for existing in sources {
				if existing.source_id == placement.source_id {
					seen = true
					break
				}
			}
			if seen do continue
			append(&sources, protocol.Snapshot_Placement{
				source_id = placement.source_id,
				visible   = placement.visible,
			})
		}
		append(&scenes, protocol.Snapshot_Scene{id = scene.id, name = scene.name, sources = sources[:]})
	}
	snapshot.scenes = scenes[:]

	sources := make([dynamic]protocol.Snapshot_Source, 0, len(show_cfg.sources), allocator)
	for &src in show_cfg.sources {
		entry := protocol.Snapshot_Source{id = src.id, name = src.name, kind = source_kind(src.data)}
		if audio, is_audio := src.data.(show.Audio_Source_Data); is_audio {
			entry.audio = protocol.Snapshot_Audio{muted = audio.muted, volume = audio.volume}
		}
		append(&sources, entry)
	}
	snapshot.sources = sources[:]

	snapshot.outputs = {
		recording  = output.recording,
		finalizing = output.finalizing_sink != nil,
		streaming  = output.streaming,
	}
	return
}

@(private)
source_kind :: proc(data: show.Show_Source_Data) -> string {
	switch d in data {
	case show.Audio_Source_Data:
		return d.is_loopback ? protocol.SOURCE_KIND_AUDIO_OUTPUT : protocol.SOURCE_KIND_AUDIO_INPUT
	case show.Camera_Source_Data:  return protocol.SOURCE_KIND_CAMERA
	case show.Color_Source_Data:   return protocol.SOURCE_KIND_COLOR
	case show.Display_Source_Data: return protocol.SOURCE_KIND_DISPLAY
	case show.Image_Source_Data:   return protocol.SOURCE_KIND_IMAGE
	case show.Window_Source_Data:  return protocol.SOURCE_KIND_WINDOW
	}
	return protocol.SOURCE_KIND_COLOR
}

// ---- Diff ----

// Events for what changed between two snapshots. volume_sent carries the
// throttle state and is updated here; its keys are owned by key_allocator.
@(private)
snapshot_diff :: proc(
	prev, curr:    ^protocol.Snapshot,
	volume_sent:   ^map[string]Volume_Sent,
	now:           time.Tick,
	key_allocator: mem.Allocator,
	allocator:     mem.Allocator,
) -> []Diff_Event {
	events := make([dynamic]Diff_Event, 0, 8, allocator)

	// A different show invalidates every id, so clients re-fetch instead of
	// being walked through changes that no longer mean anything.
	if prev.show.id != curr.show.id {
		append(&events, Diff_Event{.Show_Changed, protocol.event_show_changed(curr.show.id, curr.show.name, allocator)})
		forget_volume_sent(volume_sent, key_allocator)
		seed_volume_sent(curr, volume_sent, now, key_allocator)
		return events[:]
	}

	if prev.show.name != curr.show.name {
		append(&events, Diff_Event{.Show_Changed, protocol.event_show_changed(curr.show.id, curr.show.name, allocator)})
	}

	prev_scene, had_scene := prev.active_scene_id.?
	curr_scene, has_scene := curr.active_scene_id.?
	if had_scene != has_scene || prev_scene != curr_scene {
		append(&events, Diff_Event{.Scene_Changed, protocol.event_scene_changed(curr.active_scene_id, allocator)})
	}

	if scene_list_changed(prev.scenes, curr.scenes) {
		append(&events, Diff_Event{.Scenes_List_Changed, protocol.event_empty(allocator)})
	}

	// Visibility, for scenes and sources that exist in both snapshots.
	for &scene in curr.scenes {
		old_scene := find_scene_entry(prev.scenes, scene.id)
		if old_scene == nil do continue
		for placement in scene.sources {
			old := find_placement_entry(old_scene.sources, placement.source_id)
			if old == nil || old.visible == placement.visible do continue
			append(&events, Diff_Event{
				.Source_Visibility_Changed,
				protocol.event_visibility_changed(scene.id, placement.source_id, placement.visible, allocator),
			})
		}
	}

	if source_list_changed(prev.sources, curr.sources) {
		append(&events, Diff_Event{.Sources_List_Changed, protocol.event_empty(allocator)})
	}

	for &src in curr.sources {
		audio, has_audio := src.audio.?
		if !has_audio do continue

		old := find_source_entry(prev.sources, src.id)
		if old != nil {
			if old_audio, had_audio := old.audio.?; had_audio && old_audio.muted != audio.muted {
				append(&events, Diff_Event{.Audio_Mute_Changed, protocol.event_mute_changed(src.id, audio.muted, allocator)})
			}
		}

		// Volume is throttled against the last value actually sent, so a
		// dragged slider produces ~10 events/second and always ends on the
		// final value.
		sent, tracked := volume_sent[src.id]
		if !tracked {
			volume_sent[strings.clone(src.id, key_allocator)] = Volume_Sent{value = audio.volume, at = now}
			continue
		}
		if sent.value == audio.volume do continue
		if time.tick_diff(sent.at, now) < VOLUME_EVENT_INTERVAL do continue
		append(&events, Diff_Event{.Audio_Volume_Changed, protocol.event_volume_changed(src.id, audio.volume, allocator)})
		volume_sent[src.id] = Volume_Sent{value = audio.volume, at = now}
	}

	prune_volume_sent(curr, volume_sent, key_allocator)

	if prev.outputs.recording != curr.outputs.recording || prev.outputs.finalizing != curr.outputs.finalizing {
		append(&events, Diff_Event{
			.Recording_Changed,
			protocol.event_recording_changed(curr.outputs.recording, curr.outputs.finalizing, allocator),
		})
	}
	if prev.outputs.streaming != curr.outputs.streaming {
		append(&events, Diff_Event{.Streaming_Changed, protocol.event_streaming_changed(curr.outputs.streaming, allocator)})
	}

	return events[:]
}

@(private)
scene_list_changed :: proc(prev, curr: []protocol.Snapshot_Scene) -> bool {
	if len(prev) != len(curr) do return true
	for scene, i in curr {
		old := prev[i]
		if old.id != scene.id || old.name != scene.name do return true
		if len(old.sources) != len(scene.sources) do return true
		for placement, j in scene.sources {
			if old.sources[j].source_id != placement.source_id do return true
		}
	}
	return false
}

@(private)
source_list_changed :: proc(prev, curr: []protocol.Snapshot_Source) -> bool {
	if len(prev) != len(curr) do return true
	for src, i in curr {
		old := prev[i]
		if old.id != src.id || old.name != src.name || old.kind != src.kind do return true
		_, old_audio := old.audio.?
		_, new_audio := src.audio.?
		if old_audio != new_audio do return true
	}
	return false
}

@(private)
snapshots_equal :: proc(prev, curr: ^protocol.Snapshot) -> bool {
	if prev.show != curr.show do return false
	if prev.active_scene_id != curr.active_scene_id do return false
	if prev.outputs != curr.outputs do return false
	if scene_list_changed(prev.scenes, curr.scenes) do return false
	if source_list_changed(prev.sources, curr.sources) do return false

	for &scene, i in curr.scenes {
		for placement, j in scene.sources {
			if prev.scenes[i].sources[j].visible != placement.visible do return false
		}
	}
	for &src, i in curr.sources {
		if prev.sources[i].audio != src.audio do return false
	}
	return true
}

@(private)
find_scene_entry :: proc(scenes: []protocol.Snapshot_Scene, id: string) -> ^protocol.Snapshot_Scene {
	for &scene in scenes {
		if scene.id == id do return &scene
	}
	return nil
}

@(private)
find_placement_entry :: proc(placements: []protocol.Snapshot_Placement, source_id: string) -> ^protocol.Snapshot_Placement {
	for &placement in placements {
		if placement.source_id == source_id do return &placement
	}
	return nil
}

@(private)
find_source_entry :: proc(sources: []protocol.Snapshot_Source, id: string) -> ^protocol.Snapshot_Source {
	for &src in sources {
		if src.id == id do return &src
	}
	return nil
}

// Records every audio source's current volume as already sent, so the first
// diff after a fresh start or a show switch doesn't fire an event for it.
@(private)
seed_volume_sent :: proc(
	snapshot:      ^protocol.Snapshot,
	volume_sent:   ^map[string]Volume_Sent,
	now:           time.Tick,
	key_allocator: mem.Allocator,
) {
	for &src in snapshot.sources {
		audio, has_audio := src.audio.?
		if !has_audio do continue
		if _, tracked := volume_sent[src.id]; tracked do continue
		volume_sent[strings.clone(src.id, key_allocator)] = Volume_Sent{value = audio.volume, at = now}
	}
}

@(private)
prune_volume_sent :: proc(snapshot: ^protocol.Snapshot, volume_sent: ^map[string]Volume_Sent, key_allocator: mem.Allocator) {
	// Collected first: removing entries while ranging over the map is not allowed.
	stale := make([dynamic]string, 0, 4, context.temp_allocator)
	for key in volume_sent {
		if find_source_entry(snapshot.sources, key) == nil do append(&stale, key)
	}
	for key in stale {
		delete_key(volume_sent, key)
		delete(key, key_allocator)
	}
}

@(private)
forget_volume_sent :: proc(volume_sent: ^map[string]Volume_Sent, key_allocator: mem.Allocator) {
	for key in volume_sent {
		delete(key, key_allocator)
	}
	clear(volume_sent)
}

// ---- Responses ----

@(private)
error_code_for :: proc(err: Action_Error) -> protocol.Error_Code {
	switch err {
	case .None, .Failed:    return .Failed
	case .Not_Found:        return .Not_Found
	case .Invalid_Argument: return .Invalid_Argument
	case .Already_Active:   return .Already_Active
	case .Not_Configured:   return .Not_Configured
	}
	return .Failed
}

// Toggles report the value they settled on, so a client doesn't have to wait
// for the event to know what happened.
@(private)
result_body :: proc(a: action.Action, result: Action_Result, allocator: mem.Allocator) -> json.Value {
	value, has_value := result.value.?
	if !has_value do return nil

	key: string
	#partial switch _ in a {
	case action.Action_Set_Mute, action.Action_Toggle_Mute:
		key = "muted"
	case action.Action_Set_Source_Visible, action.Action_Toggle_Source_Visible:
		key = "visible"
	case:
		return nil
	}

	obj := make(json.Object, allocator)
	obj[key] = json.Boolean(value)
	return obj
}

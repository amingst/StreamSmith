// src/app/remote_bridge_test.odin
package app

import "core:crypto"
import "core:encoding/json"
import "core:testing"
import "core:time"

import "../action"
import "../remote/protocol"
import "../show"

@(private="file")
snap_of :: proc(t: ^testing.T, show_cfg: ^show.Show, active: string, output: ^Output_State) -> protocol.Snapshot {
	return build_snapshot(show_cfg, active, output, context.temp_allocator)
}

@(private="file")
diff_of :: proc(prev, curr: ^protocol.Snapshot, sent: ^map[string]Volume_Sent, now: time.Tick) -> []Diff_Event {
	return snapshot_diff(prev, curr, sent, now, context.temp_allocator, context.temp_allocator)
}

@(private="file")
event_names :: proc(events: []Diff_Event) -> (names: [dynamic]protocol.Event_Name) {
	names = make([dynamic]protocol.Event_Name, 0, len(events), context.temp_allocator)
	for e in events do append(&names, e.name)
	return
}

@(private="file")
has_event :: proc(events: []Diff_Event, name: protocol.Event_Name) -> (json.Object, bool) {
	for e in events {
		if e.name == name do return e.data.(json.Object) or_else nil, true
	}
	return nil, false
}

// actions_test.odin's Fixture is file-private, so the bridge tests carry
// their own: two scenes, a mic placed twice in the first, and a display.
@(private="file")
Fixture :: struct {
	show_cfg:      show.Show,
	active_scene:  string,
	scene_id:      string,
	other_scene_id: string,
	mic_id:        string,
	image_id:      string,
}

@(private="file")
bridge_fixture :: proc(f: ^Fixture) {
	context.random_generator = crypto.random_generator()
	f.show_cfg = show.create_default()
	f.scene_id = show.create_scene(&f.show_cfg, "Main")
	f.other_scene_id = show.create_scene(&f.show_cfg, "Alt")
	f.mic_id = show.create_source(&f.show_cfg, "Mic", show.Audio_Source_Data{params = {volume = 1}})
	f.image_id = show.create_source(&f.show_cfg, "Screen", show.Display_Source_Data{})
	sc := show.find_scene(&f.show_cfg, f.scene_id)
	show.place_source(sc, f.mic_id)
	show.place_source(sc, f.mic_id) // same source twice: one snapshot entry
	show.place_source(sc, f.image_id)
	f.active_scene = f.scene_id
}

@(test)
snapshot_mirrors_the_show :: proc(t: ^testing.T) {
	f: Fixture
	bridge_fixture(&f)
	defer show.destroy_show(&f.show_cfg)

	output := Output_State{recording = true}
	snap := snap_of(t, &f.show_cfg, f.active_scene, &output)

	testing.expect_value(t, snap.show.id, f.show_cfg.id)
	testing.expect_value(t, snap.active_scene_id.? or_else "", f.scene_id)
	testing.expect_value(t, len(snap.scenes), 2) // Main and Alt

	scene := find_scene_entry(snap.scenes, f.scene_id)
	if !testing.expect(t, scene != nil, "scene missing") do return
	testing.expect_value(t, len(scene.sources), 2) // the mic collapses to one entry
	testing.expect_value(t, scene.sources[0].source_id, f.mic_id)
	testing.expect(t, scene.sources[0].visible, "placement should start visible")

	mic := find_source_entry(snap.sources, f.mic_id)
	if !testing.expect(t, mic != nil, "mic missing") do return
	testing.expect_value(t, mic.kind, protocol.SOURCE_KIND_AUDIO_INPUT)
	audio, has_audio := mic.audio.?
	testing.expect(t, has_audio, "mic should carry audio")
	testing.expect_value(t, audio.volume, 1)

	screen := find_source_entry(snap.sources, f.image_id)
	testing.expect_value(t, screen.kind, protocol.SOURCE_KIND_DISPLAY)
	_, screen_audio := screen.audio.?
	testing.expect(t, !screen_audio, "a display has no audio")

	testing.expect(t, snap.outputs.recording, "recording")
	testing.expect(t, !snap.outputs.finalizing, "not finalizing")
}

@(test)
diff_reports_scene_mute_and_visibility :: proc(t: ^testing.T) {
	f: Fixture
	bridge_fixture(&f)
	defer show.destroy_show(&f.show_cfg)
	output: Output_State
	sent := make(map[string]Volume_Sent, 8, context.temp_allocator)
	now := time.tick_now()

	prev := snap_of(t, &f.show_cfg, f.active_scene, &output)
	seed_volume_sent(&prev, &sent, now, context.temp_allocator)

	// Scene switch, mute, and hide the mic in that scene.
	other := f.other_scene_id
	mic := &show.find_source(&f.show_cfg, f.mic_id).data.(show.Audio_Source_Data)
	mic.muted = true
	sc := show.find_scene(&f.show_cfg, f.scene_id)
	for &p in sc.sources {
		if p.source_id == f.mic_id do p.visible = false
	}

	curr := snap_of(t, &f.show_cfg, other, &output)
	events := diff_of(&prev, &curr, &sent, now)

	scene_data, has_scene := has_event(events, .Scene_Changed)
	testing.expect(t, has_scene, "expected scene.changed")
	testing.expect_value(t, scene_data["sceneId"].(json.String) or_else "", other)

	mute_data, has_mute := has_event(events, .Audio_Mute_Changed)
	testing.expect(t, has_mute, "expected audio.muteChanged")
	testing.expect(t, mute_data["muted"].(json.Boolean) or_else false, "muted should be true")

	vis_data, has_vis := has_event(events, .Source_Visibility_Changed)
	testing.expect(t, has_vis, "expected source.visibilityChanged")
	testing.expect_value(t, vis_data["sceneId"].(json.String) or_else "", f.scene_id)
	testing.expect_value(t, vis_data["sourceId"].(json.String) or_else "", f.mic_id)
	testing.expect(t, !(vis_data["visible"].(json.Boolean) or_else true), "visible should be false")

	// Nothing changed since curr: no events at all.
	again := snap_of(t, &f.show_cfg, other, &output)
	testing.expect_value(t, len(diff_of(&curr, &again, &sent, now)), 0)
	testing.expect(t, snapshots_equal(&curr, &again), "snapshots should compare equal")
}

@(test)
diff_reports_output_and_list_changes :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator() // new ids are UUID v4
	f: Fixture
	bridge_fixture(&f)
	defer show.destroy_show(&f.show_cfg)
	output: Output_State
	sent := make(map[string]Volume_Sent, 8, context.temp_allocator)
	now := time.tick_now()

	prev := snap_of(t, &f.show_cfg, f.active_scene, &output)
	output.recording = true
	curr := snap_of(t, &f.show_cfg, f.active_scene, &output)
	rec, has_rec := has_event(diff_of(&prev, &curr, &sent, now), .Recording_Changed)
	testing.expect(t, has_rec, "expected recording.changed")
	testing.expect(t, rec["recording"].(json.Boolean) or_else false, "recording should be true")

	// A new scene and a new source are list changes, so clients re-fetch.
	show.create_scene(&f.show_cfg, "Second")
	after_scene := snap_of(t, &f.show_cfg, f.active_scene, &output)
	_, has_scene_list := has_event(diff_of(&curr, &after_scene, &sent, now), .Scenes_List_Changed)
	testing.expect(t, has_scene_list, "expected scenes.listChanged")

	show.create_source(&f.show_cfg, "Cam", show.Camera_Source_Data{})
	after_source := snap_of(t, &f.show_cfg, f.active_scene, &output)
	_, has_source_list := has_event(diff_of(&after_scene, &after_source, &sent, now), .Sources_List_Changed)
	testing.expect(t, has_source_list, "expected sources.listChanged")
}

@(test)
a_show_switch_only_reports_show_changed :: proc(t: ^testing.T) {
	context.random_generator = crypto.random_generator() // new ids are UUID v4
	f: Fixture
	bridge_fixture(&f)
	defer show.destroy_show(&f.show_cfg)
	output: Output_State
	sent := make(map[string]Volume_Sent, 8, context.temp_allocator)
	now := time.tick_now()

	prev := snap_of(t, &f.show_cfg, f.active_scene, &output)
	seed_volume_sent(&prev, &sent, now, context.temp_allocator)

	// A different show: every id from the old one is meaningless now.
	other_show := show.create_default()
	defer show.destroy_show(&other_show)
	other_scene := show.create_scene(&other_show, "Fresh")
	curr := snap_of(t, &other_show, other_scene, &output)

	events := diff_of(&prev, &curr, &sent, now)
	testing.expect_value(t, len(events), 1)
	data, has_show := has_event(events, .Show_Changed)
	testing.expect(t, has_show, "expected show.changed")
	testing.expect_value(t, data["id"].(json.String) or_else "", other_show.id)

	// The old show's sources are no longer tracked for throttling.
	testing.expect_value(t, len(sent), 0)
}

@(test)
volume_events_are_throttled_but_land_on_the_last_value :: proc(t: ^testing.T) {
	f: Fixture
	bridge_fixture(&f)
	defer show.destroy_show(&f.show_cfg)
	output: Output_State
	sent := make(map[string]Volume_Sent, 8, context.temp_allocator)
	start := time.tick_now()

	mic := &show.find_source(&f.show_cfg, f.mic_id).data.(show.Audio_Source_Data)
	prev := snap_of(t, &f.show_cfg, f.active_scene, &output)
	seed_volume_sent(&prev, &sent, start, context.temp_allocator)

	// A dragged slider: many changes inside one throttle window.
	mic.volume = 0.9
	a := snap_of(t, &f.show_cfg, f.active_scene, &output)
	testing.expect_value(t, len(diff_of(&prev, &a, &sent, start)), 0)

	mic.volume = 0.8
	b := snap_of(t, &f.show_cfg, f.active_scene, &output)
	early := time.Tick{_nsec = start._nsec + i64(50 * time.Millisecond)}
	testing.expect_value(t, len(diff_of(&a, &b, &sent, early)), 0)

	// Once the window passes, the latest value goes out.
	mic.volume = 0.7
	c := snap_of(t, &f.show_cfg, f.active_scene, &output)
	late := time.Tick{_nsec = start._nsec + i64(150 * time.Millisecond)}
	data, has_volume := has_event(diff_of(&b, &c, &sent, late), .Audio_Volume_Changed)
	testing.expect(t, has_volume, "expected audio.volumeChanged")
	testing.expect_value(t, f32(data["volume"].(json.Float) or_else 0), f32(0.7))

	// Still at that value: nothing more to send.
	d := snap_of(t, &f.show_cfg, f.active_scene, &output)
	later := time.Tick{_nsec = start._nsec + i64(400 * time.Millisecond)}
	testing.expect_value(t, len(diff_of(&c, &d, &sent, later)), 0)
}

@(test)
responses_carry_toggle_values_and_error_codes :: proc(t: ^testing.T) {
	testing.expect_value(t, error_code_for(.Not_Found), protocol.Error_Code.Not_Found)
	testing.expect_value(t, error_code_for(.Invalid_Argument), protocol.Error_Code.Invalid_Argument)
	testing.expect_value(t, error_code_for(.Already_Active), protocol.Error_Code.Already_Active)
	testing.expect_value(t, error_code_for(.Not_Configured), protocol.Error_Code.Not_Configured)
	testing.expect_value(t, error_code_for(.Failed), protocol.Error_Code.Failed)

	muted := result_body(action.Action_Toggle_Mute{source_id = "mic"},
		Action_Result{value = true}, context.temp_allocator)
	obj := muted.(json.Object) or_else nil
	testing.expect(t, obj["muted"].(json.Boolean) or_else false, "expected muted = true")

	visible := result_body(action.Action_Toggle_Source_Visible{scene_id = "s", source_id = "src"},
		Action_Result{value = false}, context.temp_allocator)
	vis_obj := visible.(json.Object) or_else nil
	testing.expect(t, !(vis_obj["visible"].(json.Boolean) or_else true), "expected visible = false")

	// Actions without a toggle value send an empty result.
	testing.expect(t, result_body(action.Action_Start_Recording{}, Action_Result{}, context.temp_allocator) == nil,
		"expected no result body")
}

// The bridge must be safe to drive with the server off, which is how it runs
// when remote control is disabled in the settings.
@(test)
bridge_without_a_server_does_nothing :: proc(t: ^testing.T) {
	f: Fixture
	bridge_fixture(&f)
	defer show.destroy_show(&f.show_cfg)

	bridge: Remote_Bridge
	bridge_init(&bridge, nil)
	defer bridge_destroy(&bridge)

	output: Output_State
	env := action.Envelope{action = action.Action_Start_Recording{}, origin = .Remote}
	bridge_respond(&bridge, &env, Action_Result{})
	bridge_update(&bridge, &f.show_cfg, f.active_scene, &output)
	testing.expect(t, !bridge.has_prev, "nothing should have been built")
}

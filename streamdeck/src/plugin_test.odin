// streamdeck/src/plugin_test.odin
package streamdeck_plugin

import "core:encoding/json"
import "core:testing"

import "../../src/remote/protocol"

SNAPSHOT_JSON :: `{
	"show": {"id": "show-1", "name": "Weekly"},
	"activeSceneId": "scene-a",
	"scenes": [
		{"id": "scene-a", "name": "Main", "sources": [
			{"sourceId": "mic", "visible": true},
			{"sourceId": "cam", "visible": false}
		]},
		{"id": "scene-b", "name": "BRB", "sources": []}
	],
	"sources": [
		{"id": "mic", "name": "Mic", "kind": "audio_input", "audio": {"muted": false, "volume": 0.8}},
		{"id": "cam", "name": "Cam", "kind": "camera"}
	],
	"outputs": {"recording": false, "finalizing": false, "streaming": true}
}`

// A Link holding the snapshot above, with no sockets involved.
@(private="file")
test_link :: proc(t: ^testing.T) -> (link: Link, ok: bool) {
	value, err := json.parse_string(SNAPSHOT_JSON, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if !testing.expectf(t, err == .None || err == .EOF, "snapshot parse: %v", err) do return
	obj := value.(json.Object) or_else nil

	snapshot, decoded := protocol.decode_snapshot(obj, context.temp_allocator)
	if !testing.expect(t, decoded, "decode_snapshot failed") do return

	link.snapshot = snapshot
	link.has_state = true
	link.state = .Ready
	link.allocator = context.temp_allocator
	return link, true
}

@(private="file")
event_of :: proc(t: ^testing.T, name: protocol.Event_Name, data_json: string) -> protocol.Server_Event {
	value, err := json.parse_string(data_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None || err == .EOF, "event data parse: %v", err)
	return protocol.Server_Event{name = name, data = value.(json.Object) or_else nil}
}

// ---- Stream Deck message parsing ----

@(test)
parses_will_appear :: proc(t: ^testing.T) {
	raw := `{"action":"com.streamsmith.remote.scene","context":"ctx-1","device":"dev",
		"event":"willAppear","payload":{"settings":{"sceneId":"scene-b"},"state":0,"isInMultiAction":false}}`
	event, ok := parse_deck_event(transmute([]u8)raw, context.temp_allocator)
	if !testing.expect(t, ok, "willAppear should parse") do return

	testing.expect_value(t, event.kind, Deck_Event_Kind.Will_Appear)
	testing.expect_value(t, event.action, "com.streamsmith.remote.scene")
	testing.expect_value(t, event.context_, "ctx-1")
	scene_id, has_scene := json_string(event.settings, "sceneId")
	testing.expect(t, has_scene, "settings should carry sceneId")
	testing.expect_value(t, scene_id, "scene-b")
}

@(test)
parses_key_down_and_settings_and_send_to_plugin :: proc(t: ^testing.T) {
	key_down := `{"action":"com.streamsmith.remote.mute","context":"ctx-2","event":"keyDown","payload":{"settings":{}}}`
	event, ok := parse_deck_event(transmute([]u8)key_down, context.temp_allocator)
	testing.expect(t, ok, "keyDown should parse")
	testing.expect_value(t, event.kind, Deck_Event_Kind.Key_Down)

	settings := `{"action":"com.streamsmith.remote.volume","context":"ctx-3","event":"didReceiveSettings","payload":{"settings":{"sourceId":"mic","step":0.1,"direction":"down"}}}`
	event2, ok2 := parse_deck_event(transmute([]u8)settings, context.temp_allocator)
	testing.expect(t, ok2, "didReceiveSettings should parse")
	testing.expect_value(t, event2.kind, Deck_Event_Kind.Did_Receive_Settings)

	to_plugin := `{"action":"com.streamsmith.remote.scene","context":"ctx-4","event":"sendToPlugin","payload":{"action":"setPort","port":4470}}`
	event3, ok3 := parse_deck_event(transmute([]u8)to_plugin, context.temp_allocator)
	testing.expect(t, ok3, "sendToPlugin should parse")
	testing.expect_value(t, event3.kind, Deck_Event_Kind.Send_To_Plugin)
	port, has_port := json_number(event3.payload, "port")
	testing.expect(t, has_port, "payload should carry port")
	testing.expect_value(t, int(port), 4470)
}

@(test)
ignores_events_it_does_not_handle :: proc(t: ^testing.T) {
	for raw in ([]string{
		`{"event":"deviceDidConnect","device":"dev"}`,
		`{"event":"titleParametersDidChange","context":"ctx"}`,
		`{"no":"event"}`,
		`not json at all`,
	}) {
		_, ok := parse_deck_event(transmute([]u8)raw, context.temp_allocator)
		testing.expectf(t, !ok, "%q should be ignored", raw)
	}
}

@(test)
action_uuids_map_to_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, action_kind_from_uuid(ACTION_SCENE), Action_Kind.Scene)
	testing.expect_value(t, action_kind_from_uuid(ACTION_STREAMING), Action_Kind.Streaming)
	testing.expect_value(t, action_kind_from_uuid(ACTION_RECORDING), Action_Kind.Recording)
	testing.expect_value(t, action_kind_from_uuid(ACTION_MUTE), Action_Kind.Mute)
	testing.expect_value(t, action_kind_from_uuid(ACTION_VOLUME), Action_Kind.Volume)
	testing.expect_value(t, action_kind_from_uuid(ACTION_VISIBILITY), Action_Kind.Visibility)
	testing.expect_value(t, action_kind_from_uuid("com.example.other"), Action_Kind.Unknown)
}

@(test)
settings_become_button_fields :: proc(t: ^testing.T) {
	raw := `{"sceneId":"scene-a","sourceId":"mic","step":0.2,"direction":"down"}`
	value, _ := json.parse_string(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)

	button: Button
	defer button_destroy(&button)
	button_apply_settings(&button, value.(json.Object) or_else nil)

	testing.expect_value(t, button.scene_id, "scene-a")
	testing.expect_value(t, button.source_id, "mic")
	testing.expect_value(t, button.step, f32(0.2))
	testing.expect_value(t, button.direction, -1)

	// Defaults when the page hasn't set them.
	empty, _ := json.parse_string(`{}`, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	button_apply_settings(&button, empty.(json.Object) or_else nil)
	testing.expect_value(t, button.step, f32(DEFAULT_VOLUME_STEP))
	testing.expect_value(t, button.direction, 1)
	testing.expect_value(t, button.source_id, "")
}

@(test)
titles_are_escaped :: proc(t: ^testing.T) {
	quoted := json_quote(`He said "hi"\ and left`, context.temp_allocator)
	testing.expect_value(t, quoted, `"He said \"hi\"\\ and left"`)
	testing.expect_value(t, json_quote("line\nbreak", context.temp_allocator), `"line\nbreak"`)
}

// ---- Button appearance ----

@(test)
button_look_follows_server_state :: proc(t: ^testing.T) {
	link, ok := test_link(t)
	if !ok do return

	active := Button{kind = .Scene, scene_id = "scene-a"}
	testing.expect_value(t, button_look(&active, &link).state, 1)

	idle := Button{kind = .Scene, scene_id = "scene-b"}
	testing.expect_value(t, button_look(&idle, &link).state, 0)

	// An id from another show.
	gone := Button{kind = .Scene, scene_id = "scene-gone"}
	testing.expect_value(t, button_look(&gone, &link).title, "?")

	streaming := Button{kind = .Streaming}
	testing.expect_value(t, button_look(&streaming, &link).state, 1) // streaming = true

	recording := Button{kind = .Recording}
	testing.expect_value(t, button_look(&recording, &link).state, 0)

	mute := Button{kind = .Mute, source_id = "mic"}
	testing.expect_value(t, button_look(&mute, &link).state, 0) // not muted

	volume := Button{kind = .Volume, source_id = "mic"}
	testing.expect_value(t, button_look(&volume, &link).title, "80%")

	// A visual source has no audio, so a mute button pointed at it is broken.
	bad_mute := Button{kind = .Mute, source_id = "cam"}
	testing.expect_value(t, button_look(&bad_mute, &link).title, "?")

	// State 1 is the hidden look.
	shown := Button{kind = .Visibility, scene_id = "scene-a", source_id = "mic"}
	testing.expect_value(t, button_look(&shown, &link).state, 0)
	hidden := Button{kind = .Visibility, scene_id = "scene-a", source_id = "cam"}
	testing.expect_value(t, button_look(&hidden, &link).state, 1)
}

@(test)
button_look_reports_offline_and_finalizing :: proc(t: ^testing.T) {
	link, ok := test_link(t)
	if !ok do return

	link.snapshot.outputs.finalizing = true
	recording := Button{kind = .Recording}
	testing.expect_value(t, button_look(&recording, &link).title, "Saving")

	link.state = .Offline
	testing.expect_value(t, button_look(&recording, &link).title, "Offline")

	link.state = .Version_Clash
	testing.expect_value(t, button_look(&recording, &link).title, "Update\nplugin")
}

// ---- Events applied to the local snapshot ----

@(test)
events_update_the_local_snapshot :: proc(t: ^testing.T) {
	link, ok := test_link(t)
	if !ok do return

	testing.expect(t, link_apply_event(&link, event_of(t, .Scene_Changed, `{"sceneId":"scene-b"}`)), "scene change")
	testing.expect_value(t, link_active_scene(&link), "scene-b")

	testing.expect(t, link_apply_event(&link, event_of(t, .Audio_Mute_Changed, `{"sourceId":"mic","muted":true}`)), "mute change")
	mic := link_find_source(&link, "mic")
	testing.expect(t, mic != nil, "mic missing")
	audio, has_audio := mic.audio.?
	testing.expect(t, has_audio && audio.muted, "mic should be muted")

	testing.expect(t, link_apply_event(&link, event_of(t, .Audio_Volume_Changed, `{"sourceId":"mic","volume":0.25}`)), "volume change")
	audio2, _ := link_find_source(&link, "mic").audio.?
	testing.expect_value(t, audio2.volume, f32(0.25))

	testing.expect(t, link_apply_event(&link,
		event_of(t, .Source_Visibility_Changed, `{"sceneId":"scene-a","sourceId":"mic","visible":false}`)), "visibility change")
	visible, found := link_source_visible(&link, "scene-a", "mic")
	testing.expect(t, found, "placement missing")
	testing.expect(t, !visible, "mic should be hidden")

	testing.expect(t, link_apply_event(&link, event_of(t, .Recording_Changed, `{"recording":true,"finalizing":false}`)), "recording change")
	testing.expect(t, link.snapshot.outputs.recording, "recording should be on")

	testing.expect(t, link_apply_event(&link, event_of(t, .Streaming_Changed, `{"streaming":false}`)), "streaming change")
	testing.expect(t, !link.snapshot.outputs.streaming, "streaming should be off")

	// A scene with no active scene comes through as null.
	testing.expect(t, link_apply_event(&link, event_of(t, .Scene_Changed, `{"sceneId":null}`)), "scene cleared")
	testing.expect_value(t, link_active_scene(&link), "")
}

@(test)
snapshot_decodes_every_field :: proc(t: ^testing.T) {
	link, ok := test_link(t)
	if !ok do return

	testing.expect_value(t, link.snapshot.show.name, "Weekly")
	testing.expect_value(t, len(link.snapshot.scenes), 2)
	testing.expect_value(t, len(link.snapshot.sources), 2)
	testing.expect_value(t, link_active_scene(&link), "scene-a")

	cam := link_find_source(&link, "cam")
	testing.expect(t, cam != nil, "cam missing")
	_, has_audio := cam.audio.?
	testing.expect(t, !has_audio, "a camera has no audio")

	visible, found := link_source_visible(&link, "scene-a", "cam")
	testing.expect(t, found, "cam placement missing")
	testing.expect(t, !visible, "cam starts hidden in this fixture")
}

@(test)
inspector_payload_lists_scenes_and_sources :: proc(t: ^testing.T) {
	link, ok := test_link(t)
	if !ok do return

	payload := build_inspector_payload(&link, 4460, context.temp_allocator)
	value, err := json.parse_string(payload, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if !testing.expectf(t, err == .None || err == .EOF, "payload is not valid JSON: %v (%s)", err, payload) do return

	obj := value.(json.Object) or_else nil
	testing.expect(t, obj["online"].(json.Boolean) or_else false, "should report online")
	scenes := obj["scenes"].(json.Array) or_else nil
	testing.expect_value(t, len(scenes), 2)
	sources := obj["sources"].(json.Array) or_else nil
	testing.expect_value(t, len(sources), 2)

	first := sources[0].(json.Object) or_else nil
	testing.expect_value(t, first["name"].(json.String) or_else "", "Mic")
	testing.expect(t, first["audio"].(json.Boolean) or_else false, "the mic carries audio")
}

package protocol

import "core:encoding/json"
import "core:testing"

@(private="file")
reparse :: proc(t: ^testing.T, data: []u8) -> (json.Object, bool) {
	value, err := json.parse_string(string(data), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if !testing.expectf(t, err == .None || err == .EOF, "%s: %v", string(data), err) do return {}, false
	obj, is_obj := value.(json.Object)
	if !testing.expectf(t, is_obj, "%s: not an object", string(data)) do return {}, false
	return obj, true
}

@(private="file")
field :: proc(obj: json.Object, key: string) -> (json.Value, bool) {
	value, present := obj[key]
	return value, present
}

@(private="file")
str :: proc(obj: json.Object, key: string) -> string {
	s, _ := obj[key].(json.String)
	return string(s)
}

@(test)
welcome_matches_spec :: proc(t: ^testing.T) {
	obj, ok := reparse(t, encode_welcome("StreamSmith v0.1.0-alpha", context.temp_allocator))
	if !ok do return

	testing.expect_value(t, str(obj, "type"), "welcome")
	testing.expect_value(t, obj["protocol"].(json.Integer), 1)
	testing.expect_value(t, str(obj, "server"), "StreamSmith v0.1.0-alpha")
}

@(test)
response_ok_always_has_a_result_object :: proc(t: ^testing.T) {
	obj, ok := reparse(t, encode_response_ok(7, nil, context.temp_allocator))
	if !ok do return

	testing.expect_value(t, str(obj, "type"), "response")
	testing.expect_value(t, obj["id"].(json.Integer), 7)
	testing.expect_value(t, obj["ok"].(json.Boolean), true)

	result, has_result := field(obj, "result")
	testing.expect(t, has_result, "result must be present even when empty")
	inner, is_obj := result.(json.Object)
	testing.expect(t, is_obj, "result must be an object")
	testing.expect_value(t, len(inner), 0)

	_, has_error := field(obj, "error")
	testing.expect(t, !has_error, "a success carries no error")
}

@(test)
response_ok_carries_its_payload :: proc(t: ^testing.T) {
	payload := make(json.Object, context.temp_allocator)
	payload["muted"] = json.Boolean(true)

	obj, ok := reparse(t, encode_response_ok(8, payload, context.temp_allocator))
	if !ok do return

	result := obj["result"].(json.Object)
	testing.expect_value(t, result["muted"].(json.Boolean), true)
}

@(test)
response_err_has_code_and_no_result :: proc(t: ^testing.T) {
	obj, ok := reparse(t, encode_response_err(9, .Not_Found, "no scene with id abc", context.temp_allocator))
	if !ok do return

	testing.expect_value(t, obj["ok"].(json.Boolean), false)
	_, has_result := field(obj, "result")
	testing.expect(t, !has_result, "an error carries no result")

	body := obj["error"].(json.Object)
	testing.expect_value(t, str(body, "code"), "not_found")
	testing.expect_value(t, str(body, "message"), "no scene with id abc")
}

@(test)
every_error_code_has_a_wire_name :: proc(t: ^testing.T) {
	for name, code in error_code_names {
		testing.expectf(t, name != "", "%v has no wire name", code)

		obj, ok := reparse(t, encode_response_err(1, code, "m", context.temp_allocator))
		if !ok do continue
		testing.expect_value(t, str(obj["error"].(json.Object), "code"), name)
	}
}

@(test)
error_message_lists_supported_only_for_protocol :: proc(t: ^testing.T) {
	unsupported := Fault{code = .Unsupported_Protocol, message = "protocol 2 is not supported"}
	obj, ok := reparse(t, encode_fault(unsupported, context.temp_allocator))
	if !ok do return

	testing.expect_value(t, str(obj, "type"), "error")
	testing.expect_value(t, str(obj, "code"), "unsupported_protocol")
	supported := obj["supported"].(json.Array)
	testing.expect_value(t, len(supported), 1)
	testing.expect_value(t, supported[0].(json.Integer), 1)

	plain := Fault{code = .Bad_Request, message = "bad json"}
	obj2, ok2 := reparse(t, encode_fault(plain, context.temp_allocator))
	if !ok2 do return
	_, has_supported := field(obj2, "supported")
	testing.expect(t, !has_supported, "only unsupported_protocol lists versions")
}

@(test)
fault_with_id_becomes_a_response :: proc(t: ^testing.T) {
	fault := Fault{code = .Unknown_Method, message = "unknown method scene.explode", id = 6}
	obj, ok := reparse(t, encode_fault(fault, context.temp_allocator))
	if !ok do return

	testing.expect_value(t, str(obj, "type"), "response")
	testing.expect_value(t, obj["id"].(json.Integer), 6)
	testing.expect_value(t, str(obj["error"].(json.Object), "code"), "unknown_method")
}

@(test)
events_carry_their_names_and_data :: proc(t: ^testing.T) {
	obj, ok := reparse(t, encode_event(.Scene_Changed, event_scene_changed("B", context.temp_allocator), context.temp_allocator))
	if !ok do return

	testing.expect_value(t, str(obj, "type"), "event")
	testing.expect_value(t, str(obj, "event"), "scene.changed")
	testing.expect_value(t, str(obj["data"].(json.Object), "sceneId"), "B")
}

@(test)
scene_changed_is_null_without_scenes :: proc(t: ^testing.T) {
	obj, ok := reparse(t, encode_event(.Scene_Changed, event_scene_changed(nil, context.temp_allocator), context.temp_allocator))
	if !ok do return

	data := obj["data"].(json.Object)
	value, present := field(data, "sceneId")
	testing.expect(t, present, "sceneId must be present")
	_, is_null := value.(json.Null)
	testing.expect(t, is_null, "sceneId must be null")
}

@(test)
every_event_name_is_set :: proc(t: ^testing.T) {
	for name, event in event_names {
		testing.expectf(t, name != "", "%v has no wire name", event)

		obj, ok := reparse(t, encode_event(event, event_empty(context.temp_allocator), context.temp_allocator))
		if !ok do continue
		testing.expect_value(t, str(obj, "event"), name)
	}
}

@(test)
event_payloads_match_spec :: proc(t: ^testing.T) {
	{
		data := event_recording_changed(true, false, context.temp_allocator).(json.Object)
		testing.expect_value(t, data["recording"].(json.Boolean), true)
		testing.expect_value(t, data["finalizing"].(json.Boolean), false)
	}
	{
		data := event_streaming_changed(true, context.temp_allocator).(json.Object)
		testing.expect_value(t, data["streaming"].(json.Boolean), true)
	}
	{
		data := event_mute_changed("MIC", true, context.temp_allocator).(json.Object)
		testing.expect_value(t, str(data, "sourceId"), "MIC")
		testing.expect_value(t, data["muted"].(json.Boolean), true)
	}
	{
		data := event_visibility_changed("S", "A", false, context.temp_allocator).(json.Object)
		testing.expect_value(t, str(data, "sceneId"), "S")
		testing.expect_value(t, str(data, "sourceId"), "A")
		testing.expect_value(t, data["visible"].(json.Boolean), false)
	}
	{
		data := event_show_changed("id", "Weekly Stream", context.temp_allocator).(json.Object)
		testing.expect_value(t, str(data, "id"), "id")
		testing.expect_value(t, str(data, "name"), "Weekly Stream")
	}
	{
		data := event_empty(context.temp_allocator).(json.Object)
		testing.expect_value(t, len(data), 0)
	}
}

@(test)
volume_is_rounded_for_the_wire :: proc(t: ^testing.T) {
	data := event_volume_changed("A", 0.1, context.temp_allocator).(json.Object)
	testing.expect_value(t, data["volume"].(json.Float), 0.1)

	loud := event_volume_changed("A", 1, context.temp_allocator).(json.Object)
	testing.expect_value(t, loud["volume"].(json.Float), 1)
}

@(test)
snapshot_matches_spec :: proc(t: ^testing.T) {
	snap := Snapshot{
		show = {id = "show-1", name = "Weekly Stream"},
		active_scene_id = "scene-1",
		scenes = {
			{
				id = "scene-1",
				name = "Main",
				sources = {{source_id = "src-1", visible = true}, {source_id = "src-2", visible = false}},
			},
		},
		sources = {
			{id = "src-1", name = "Mic", kind = SOURCE_KIND_AUDIO_INPUT, audio = Snapshot_Audio{muted = false, volume = 0.8}},
			{id = "src-2", name = "Desktop", kind = SOURCE_KIND_DISPLAY},
		},
		outputs = {recording = false, finalizing = false, streaming = true},
	}

	obj, ok := reparse(t, encode_snapshot(&snap, context.temp_allocator))
	if !ok do return

	testing.expect_value(t, str(obj["show"].(json.Object), "name"), "Weekly Stream")
	testing.expect_value(t, str(obj, "activeSceneId"), "scene-1")

	scenes := obj["scenes"].(json.Array)
	testing.expect_value(t, len(scenes), 1)
	scene := scenes[0].(json.Object)
	testing.expect_value(t, str(scene, "name"), "Main")

	placements := scene["sources"].(json.Array)
	testing.expect_value(t, len(placements), 2)
	first := placements[0].(json.Object)
	testing.expect_value(t, str(first, "sourceId"), "src-1")
	testing.expect_value(t, first["visible"].(json.Boolean), true)

	sources := obj["sources"].(json.Array)
	mic := sources[0].(json.Object)
	testing.expect_value(t, str(mic, "kind"), "audio_input")
	audio := mic["audio"].(json.Object)
	testing.expect_value(t, audio["muted"].(json.Boolean), false)

	desktop := sources[1].(json.Object)
	_, has_audio := field(desktop, "audio")
	testing.expect(t, !has_audio, "a video source carries no audio")

	outputs := obj["outputs"].(json.Object)
	testing.expect_value(t, outputs["streaming"].(json.Boolean), true)
	testing.expect_value(t, outputs["recording"].(json.Boolean), false)
}

@(test)
snapshot_active_scene_is_null_when_empty :: proc(t: ^testing.T) {
	snap := Snapshot{show = {id = "s", name = "Empty"}}
	obj, ok := reparse(t, encode_snapshot(&snap, context.temp_allocator))
	if !ok do return

	value, present := field(obj, "activeSceneId")
	testing.expect(t, present, "activeSceneId must always be present")
	_, is_null := value.(json.Null)
	testing.expect(t, is_null, "activeSceneId must be null for a show with no scenes")
}

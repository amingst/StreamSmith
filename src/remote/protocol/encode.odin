package protocol

import "core:encoding/json"
import "core:fmt"
import "core:math"

encode_welcome :: proc(server: string, allocator := context.allocator) -> []u8 {
	data, err := json.marshal(
		Welcome{
			type = "welcome",
			protocol = PROTOCOL_VERSION,
			server = server
		},
		allocator = allocator
	)
	// TODO: add logging
	if err != nil do return nil
	return data
}

encode_response_ok :: proc(id: i64, result: json.Value = nil, allocator := context.allocator) -> []u8 {
	result := result
	if result == nil do result = make(json.Object, allocator)

	data, err := json.marshal(
		Response{
			type = "response",
			id = id,
			ok = true,
			result = result
		},
		allocator = allocator
	)
	if err != nil do return nil
	return data
}

// Wraps an already-serialized result, so state.get can answer from the
// published snapshot bytes without parsing them again.
encode_response_raw :: proc(id: i64, result_json: []u8, allocator := context.allocator) -> []u8 {
	return transmute([]u8)fmt.aprintf(
		`{{"type":"response","id":%d,"ok":true,"result":%s}}`,
		id, string(result_json), allocator = allocator)
}

encode_response_err :: proc(id: i64, code: Error_Code, message: string, allocator := context.allocator) -> []u8 {
	data, err := json.marshal(
		Response{
			type = "response",
			id = id,
			ok = false,
			error = Error_Body{code = error_code_names[code], message = message}
		},
		allocator = allocator
	)
	if err != nil do return nil
	return data
}

encode_error :: proc(code: Error_Code, message: string, supported: []int = nil, allocator := context.allocator) -> []u8 {
	data, err := json.marshal(
		Error_Message{
			type = "error",
			code = error_code_names[code],
			message = message,
			supported = supported
		},
		allocator = allocator
	)
	if err != nil do return nil
	return data
}

encode_event :: proc(event: Event_Name, data: json.Value, allocator := context.allocator) -> []u8 {
	bytes, err := json.marshal(
		Event{
			type = "event",
			event = event_names[event],
			data = data
		},
		allocator = allocator
	)
	if err != nil do return nil
	return bytes
}

encode_snapshot :: proc(snap: ^Snapshot, allocator := context.allocator) -> []u8 {
	data, err := json.marshal(snap^, allocator = allocator)
	if err != nil do return nil
	return data
}

encode_fault :: proc(fault: Fault, allocator := context.allocator) -> []u8 {
	if id, ok := fault.id.?; ok {
		return encode_response_err(id, fault.code, fault.message, allocator)
	}
	supported := fault.code == .Unsupported_Protocol ? []int{PROTOCOL_VERSION} : nil
	return encode_error(fault.code, fault.message, supported, allocator)
}

event_scene_changed :: proc(scene_id: Maybe(string), allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	if id, has_id := scene_id.?; has_id {
		obj["sceneId"] = json.String(id)
	} else {
		obj["sceneId"] = json.Null{}
	}
	return obj
}

event_recording_changed :: proc(recording, finalizing: bool, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	obj["recording"]  = json.Boolean(recording)
	obj["finalizing"] = json.Boolean(finalizing)
	return obj
}

event_streaming_changed :: proc(streaming: bool, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	obj["streaming"] = json.Boolean(streaming)
	return obj
}

event_mute_changed :: proc(source_id: string, muted: bool, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	obj["sourceId"] = json.String(source_id)
	obj["muted"]    = json.Boolean(muted)
	return obj
}

event_volume_changed :: proc(source_id: string, volume: f32, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	obj["sourceId"] = json.String(source_id)
	obj["volume"]   = json.Float(wire_volume(volume))
	return obj
}

event_visibility_changed :: proc(scene_id, source_id: string, visible: bool, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	obj["sceneId"]  = json.String(scene_id)
	obj["sourceId"] = json.String(source_id)
	obj["visible"]  = json.Boolean(visible)
	return obj
}

event_show_changed :: proc(id, name: string, allocator := context.allocator) -> json.Value {
	obj := make(json.Object, allocator)
	obj["id"]   = json.String(id)
	obj["name"] = json.String(name)
	return obj
}

event_empty :: proc(allocator := context.allocator) -> json.Value {
	return make(json.Object, allocator)
}

@(private)
wire_volume :: proc(volume: f32) -> f64 {
	return math.round(f64(volume) * 10000) / 10000
}

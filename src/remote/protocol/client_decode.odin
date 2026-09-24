package protocol

// The client half of the wire format: what StreamSmith sends and a client
// (the Stream Deck plugin) has to read. Kept next to the server-side decoder
// so both ends of protocol 1 change together.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Server_Welcome :: struct {
	protocol: int,
	server:   string,
}

Server_Response :: struct {
	id:      i64,
	ok:      bool,
	result:  json.Object, // nil when ok is false
	code:    string,      // error code, empty when ok
	message: string,
}

Server_Event :: struct {
	name: Event_Name,
	data: json.Object,
}

// A standalone error message (not a response to a request).
Server_Error :: struct {
	code:      string,
	message:   string,
	supported: []int,
}

Outbound :: union {
	Server_Welcome,
	Server_Response,
	Server_Event,
	Server_Error,
}

// Decodes one message from the server. `err` is set only when the message is
// unusable; an unknown event name or message type returns ok = false with no
// error, so a client written against protocol 1 ignores additions quietly.
decode_outbound :: proc(data: []u8, allocator := context.allocator) -> (msg: Outbound, ok: bool, err: string) {
	value, parse_err := json.parse_string(string(data), json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None && parse_err != .EOF {
		return nil, false, "message is not valid JSON"
	}

	obj, is_obj := value.(json.Object)
	if !is_obj do return nil, false, "message is not a JSON object"

	kind, has_kind := require_string(obj, "type")
	if !has_kind do return nil, false, "message has no type"

	switch kind {
	case "welcome":
		version, _ := require_integer(obj, "protocol")
		server, _ := require_string(obj, "server")
		return Server_Welcome{protocol = int(version), server = server}, true, ""

	case "response":
		id, has_id := require_integer(obj, "id")
		if !has_id do return nil, false, "response has no id"
		response := Server_Response{id = id}
		response.ok, _ = require_bool(obj, "ok")
		if response.ok {
			response.result, _ = obj["result"].(json.Object)
		} else if error_obj, has_error := obj["error"].(json.Object); has_error {
			response.code, _ = require_string(error_obj, "code")
			response.message, _ = require_string(error_obj, "message")
		}
		return response, true, ""

	case "event":
		name, has_name := require_string(obj, "event")
		if !has_name do return nil, false, "event has no name"
		event_name, known := event_from_string(name)
		if !known do return nil, false, "" // a protocol-1 client ignores unknown events
		data_obj, _ := obj["data"].(json.Object)
		return Server_Event{name = event_name, data = data_obj}, true, ""

	case "error":
		code, _ := require_string(obj, "code")
		message, _ := require_string(obj, "message")
		supported: []int
		if list, has_list := obj["supported"].(json.Array); has_list {
			versions := make([dynamic]int, 0, len(list), allocator)
			for entry in list {
				if n, is_int := entry.(json.Integer); is_int do append(&versions, int(n))
			}
			supported = versions[:]
		}
		return Server_Error{code = code, message = message, supported = supported}, true, ""
	}

	return nil, false, "" // unknown message type: ignored, not an error
}

event_from_string :: proc(s: string) -> (Event_Name, bool) {
	for name, event in event_names {
		if name == s do return event, true
	}
	return {}, false
}

// ---- Snapshot ----

// Reads a state.get result into an owned Snapshot. Decoded by hand rather than
// with json.unmarshal so the optional pieces (null activeSceneId, sources
// without audio) are unambiguous, and so every string belongs to allocator.
decode_snapshot :: proc(obj: json.Object, allocator := context.allocator) -> (snapshot: Snapshot, ok: bool) {
	if show_obj, has_show := obj["show"].(json.Object); has_show {
		id, _ := require_string(show_obj, "id")
		name, _ := require_string(show_obj, "name")
		snapshot.show = {id = strings.clone(id, allocator), name = strings.clone(name, allocator)}
	}

	if scene_id, has_scene := require_string(obj, "activeSceneId"); has_scene {
		snapshot.active_scene_id = strings.clone(scene_id, allocator)
	}

	if scene_list, has_scenes := obj["scenes"].(json.Array); has_scenes {
		scenes := make([dynamic]Snapshot_Scene, 0, len(scene_list), allocator)
		for entry in scene_list {
			scene_obj, is_obj := entry.(json.Object)
			if !is_obj do continue
			id, _ := require_string(scene_obj, "id")
			name, _ := require_string(scene_obj, "name")
			scene := Snapshot_Scene{id = strings.clone(id, allocator), name = strings.clone(name, allocator)}

			if placements, has_placements := scene_obj["sources"].(json.Array); has_placements {
				sources := make([dynamic]Snapshot_Placement, 0, len(placements), allocator)
				for placement_entry in placements {
					placement_obj, placement_is_obj := placement_entry.(json.Object)
					if !placement_is_obj do continue
					source_id, _ := require_string(placement_obj, "sourceId")
					visible, _ := require_bool(placement_obj, "visible")
					append(&sources, Snapshot_Placement{
						source_id = strings.clone(source_id, allocator),
						visible   = visible,
					})
				}
				scene.sources = sources[:]
			}
			append(&scenes, scene)
		}
		snapshot.scenes = scenes[:]
	}

	if source_list, has_sources := obj["sources"].(json.Array); has_sources {
		sources := make([dynamic]Snapshot_Source, 0, len(source_list), allocator)
		for entry in source_list {
			source_obj, is_obj := entry.(json.Object)
			if !is_obj do continue
			id, _ := require_string(source_obj, "id")
			name, _ := require_string(source_obj, "name")
			kind, _ := require_string(source_obj, "kind")
			source := Snapshot_Source{
				id   = strings.clone(id, allocator),
				name = strings.clone(name, allocator),
				kind = strings.clone(kind, allocator),
			}
			if audio_obj, has_audio := source_obj["audio"].(json.Object); has_audio {
				muted, _ := require_bool(audio_obj, "muted")
				volume, _ := require_number(audio_obj, "volume")
				source.audio = Snapshot_Audio{muted = muted, volume = f32(volume)}
			}
			append(&sources, source)
		}
		snapshot.sources = sources[:]
	}

	if outputs_obj, has_outputs := obj["outputs"].(json.Object); has_outputs {
		snapshot.outputs.recording, _ = require_bool(outputs_obj, "recording")
		snapshot.outputs.finalizing, _ = require_bool(outputs_obj, "finalizing")
		snapshot.outputs.streaming, _ = require_bool(outputs_obj, "streaming")
	}

	return snapshot, true
}

destroy_snapshot :: proc(snapshot: ^Snapshot, allocator := context.allocator) {
	delete(snapshot.show.id, allocator)
	delete(snapshot.show.name, allocator)
	if id, has_id := snapshot.active_scene_id.?; has_id do delete(id, allocator)

	for scene in snapshot.scenes {
		delete(scene.id, allocator)
		delete(scene.name, allocator)
		for placement in scene.sources {
			delete(placement.source_id, allocator)
		}
		delete(scene.sources, allocator)
	}
	delete(snapshot.scenes, allocator)

	for source in snapshot.sources {
		delete(source.id, allocator)
		delete(source.name, allocator)
		delete(source.kind, allocator)
	}
	delete(snapshot.sources, allocator)
	snapshot^ = {}
}

// ---- Requests ----

// Builds a request. params_json is spliced in as-is, so callers can use the
// small helpers below rather than building a json.Object.
encode_request :: proc(id: i64, method: Method, params_json := "", allocator := context.allocator) -> []u8 {
	if params_json == "" {
		return transmute([]u8)fmt.aprintf(
			`{{"type":"request","id":%d,"method":"%s"}}`, id, method_names[method], allocator = allocator)
	}
	return transmute([]u8)fmt.aprintf(
		`{{"type":"request","id":%d,"method":"%s","params":%s}}`,
		id, method_names[method], params_json, allocator = allocator)
}

encode_hello :: proc(client: string, allocator := context.allocator) -> []u8 {
	return transmute([]u8)fmt.aprintf(
		`{{"type":"hello","protocol":%d,"client":"%s"}}`, PROTOCOL_VERSION, client, allocator = allocator)
}

package protocol

import "core:encoding/json"
import "core:fmt"

decode_inbound :: proc(data: []u8, allocator := context.allocator) -> (msg: Inbound, fault: Maybe(Fault)) {
	value, parse_err := json.parse_string(string(data), json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None && parse_err != .EOF {
		return nil, Fault{code = .Bad_Request, message = "message is not valid JSON"}
	}

	obj, is_obj := value.(json.Object)
	if !is_obj {
		return nil, Fault{code = .Bad_Request, message = "message must be a JSON object"}
	}

	kind, has_kind := require_string(obj, "type")
	if !has_kind {
		return nil, Fault{code = .Bad_Request, message = "message is missing a type"}
	}

	switch kind {
	case "hello":
		version, has_version := require_integer(obj, "protocol")
		if !has_version {
			return nil, Fault{code = .Bad_Request, message = "hello is missing an integer protocol"}
		}
		client, _ := require_string(obj, "client")
		return Hello{protocol = int(version), client = client}, nil

	case "request":
		id, has_id := require_integer(obj, "id")
		if !has_id {
			return nil, Fault{code = .Bad_Request, message = "request is missing an integer id"}
		}

		name, has_method := require_string(obj, "method")
		if !has_method {
			return nil, Fault{code = .Bad_Request, message = "request is missing a method", id = id}
		}

		method, known := method_from_string(name)
		if !known {
			return nil, Fault{
				code    = .Unknown_Method,
				message = fmt.tprintf("unknown method %s", name),
				id      = id,
			}
		}

		params_obj: json.Object
		if raw, present := obj["params"]; present {
			params, is_params_obj := raw.(json.Object)
			if !is_params_obj {
				return nil, Fault{code = .Bad_Request, message = "params must be an object", id = id}
			}
			params_obj = params
		}

		params, params_fault := decode_params(method, params_obj, id)
		if params_fault != nil do return nil, params_fault
		return Request{id = id, method = method, params = params}, nil
	}

	return nil, Fault{code = .Bad_Request, message = fmt.tprintf("unknown message type %s", kind)}
}

@(private)
decode_params :: proc(method: Method, obj: json.Object, id: i64) -> (params: Params, fault: Maybe(Fault)) {
	#partial switch method {
	case .Scene_Set:
		scene_id, ok := require_string(obj, "sceneId")
		if !ok do return nil, missing_param("sceneId", id)
		return Params_Scene_Set{scene_id = scene_id}, nil

	case .Events_Subscribe:
		topics := decode_topics(obj, id) or_return
		return Params_Subscribe{topics = topics}, nil

	case .Audio_Set_Mute:
		source_id, has_source := require_string(obj, "sourceId")
		if !has_source do return nil, missing_param("sourceId", id)
		muted, has_muted := require_bool(obj, "muted")
		if !has_muted do return nil, missing_param("muted", id)
		return Params_Mute{source_id = source_id, muted = muted}, nil

	case .Audio_Toggle_Mute:
		source_id, ok := require_string(obj, "sourceId")
		if !ok do return nil, missing_param("sourceId", id)
		return Params_Mute{source_id = source_id}, nil

	case .Audio_Set_Volume:
		source_id, has_source := require_string(obj, "sourceId")
		if !has_source do return nil, missing_param("sourceId", id)
		volume, has_volume := require_number(obj, "volume")
		if !has_volume do return nil, missing_param("volume", id)
		return Params_Volume{source_id = source_id, volume = f32(volume)}, nil

	case .Source_Set_Visible:
		scene_id, has_scene := require_string(obj, "sceneId")
		if !has_scene do return nil, missing_param("sceneId", id)
		source_id, has_source := require_string(obj, "sourceId")
		if !has_source do return nil, missing_param("sourceId", id)
		visible, has_visible := require_bool(obj, "visible")
		if !has_visible do return nil, missing_param("visible", id)
		return Params_Visible{scene_id = scene_id, source_id = source_id, visible = visible}, nil

	case .Source_Toggle_Visible:
		scene_id, has_scene := require_string(obj, "sceneId")
		if !has_scene do return nil, missing_param("sceneId", id)
		source_id, has_source := require_string(obj, "sourceId")
		if !has_source do return nil, missing_param("sourceId", id)
		return Params_Visible{scene_id = scene_id, source_id = source_id}, nil
	}

	return nil, nil
}

@(private)
missing_param :: proc(key: string, id: i64) -> Maybe(Fault) {
	return Fault{code = .Bad_Request, message = fmt.tprintf("params is missing %s", key), id = id}
}

@(private)
require_string :: proc(obj: json.Object, key: string) -> (string, bool) {
	value, present := obj[key]
	if !present do return "", false
	s, is_string := value.(json.String)
	return string(s), is_string
}

@(private)
require_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	value, present := obj[key]
	if !present do return false, false
	b, is_bool := value.(json.Boolean)
	return bool(b), is_bool
}

@(private)
require_integer :: proc(obj: json.Object, key: string) -> (i64, bool) {
	value, present := obj[key]
	if !present do return 0, false
	n, is_integer := value.(json.Integer)
	return i64(n), is_integer
}

@(private)
require_number :: proc(obj: json.Object, key: string) -> (f64, bool) {
	value, present := obj[key]
	if !present do return 0, false
	#partial switch n in value {
	case json.Float:
		return f64(n), true
	case json.Integer:
		return f64(n), true
	}
	return 0, false
}

@(private)
decode_topics :: proc(obj: json.Object, id: i64) -> (topics: Topic_Set, fault: Maybe(Fault)) {
	value, present := obj["events"]
	if !present {
		return {}, Fault{code = .Bad_Request, message = "params is missing events", id = id}
	}

	list, is_array := value.(json.Array)
	if !is_array {
		return {}, Fault{code = .Bad_Request, message = "events must be an array", id = id}
	}

	for entry in list {
		name, is_string := entry.(json.String)
		if !is_string {
			return {}, Fault{code = .Bad_Request, message = "events must hold strings", id = id}
		}
		topic, known := topic_from_string(string(name))
		if !known {
			return {}, Fault{
				code    = .Invalid_Argument,
				message = fmt.tprintf("unknown event topic %s", name),
				id      = id,
			}
		}
		topics += {topic}
	}

	return topics, nil
}

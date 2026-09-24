package streamdeck_plugin

// Per-button behaviour: what a press sends, and what the button should look
// like. Button state always comes from StreamSmith's state, never from
// guessing after a press.

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Action UUIDs, which must match manifest.json. Compiled in rather than read
// from the manifest: under DRM the plugin folder is encrypted at runtime.
PLUGIN_UUID        :: "com.streamsmith.remote"
ACTION_SCENE       :: PLUGIN_UUID + ".scene"
ACTION_STREAMING   :: PLUGIN_UUID + ".streaming"
ACTION_RECORDING   :: PLUGIN_UUID + ".recording"
ACTION_MUTE        :: PLUGIN_UUID + ".mute"
ACTION_VOLUME      :: PLUGIN_UUID + ".volume"
ACTION_VISIBILITY  :: PLUGIN_UUID + ".visibility"

PLUGIN_CLIENT_NAME :: "streamsmith-streamdeck/0.1.0"

DEFAULT_VOLUME_STEP :: 0.05

Action_Kind :: enum {
	Unknown,
	Scene,
	Streaming,
	Recording,
	Mute,
	Volume,
	Visibility,
}

action_kind_from_uuid :: proc(uuid: string) -> Action_Kind {
	switch uuid {
	case ACTION_SCENE:      return .Scene
	case ACTION_STREAMING:  return .Streaming
	case ACTION_RECORDING:  return .Recording
	case ACTION_MUTE:       return .Mute
	case ACTION_VOLUME:     return .Volume
	case ACTION_VISIBILITY: return .Visibility
	}
	return .Unknown
}

// One visible button. Settings are ids, so they survive renames; a missing id
// means the button was set up for a source or scene that no longer exists.
Button :: struct {
	context_:  string, // owned
	kind:      Action_Kind,
	scene_id:  string, // owned
	source_id: string, // owned
	step:      f32,    // Volume only
	direction: int,    // Volume only: +1 up, -1 down

	last_state: int,
	last_title: string, // owned; only re-sent when it changes
}

button_destroy :: proc(button: ^Button) {
	delete(button.context_)
	delete(button.scene_id)
	delete(button.source_id)
	delete(button.last_title)
	button^ = {}
}

button_apply_settings :: proc(button: ^Button, settings: json.Object) {
	delete(button.scene_id)
	delete(button.source_id)
	button.scene_id = ""
	button.source_id = ""

	if id, ok := json_string(settings, "sceneId"); ok do button.scene_id = strings.clone(id)
	if id, ok := json_string(settings, "sourceId"); ok do button.source_id = strings.clone(id)

	button.step = DEFAULT_VOLUME_STEP
	if step, ok := json_number(settings, "step"); ok && step > 0 do button.step = f32(step)

	button.direction = 1
	if dir, ok := json_string(settings, "direction"); ok && dir == "down" do button.direction = -1
}

// ---- Presses ----

// Sends what the press means. Returns false when the button can't act, in
// which case the caller shows an alert.
button_press :: proc(button: ^Button, link: ^Link) -> bool {
	if link.state != .Ready do return false

	switch button.kind {
	case .Scene:
		if link_find_scene(link, button.scene_id) == nil do return false
		link_request(link, .Scene_Set, fmt.tprintf(`{{"sceneId":%s}}`, json_quote(button.scene_id, context.temp_allocator)))
		return true

	case .Streaming:
		link_request(link, .Streaming_Toggle)
		return true

	case .Recording:
		link_request(link, .Recording_Toggle)
		return true

	case .Mute:
		if link_find_source(link, button.source_id) == nil do return false
		link_request(link, .Audio_Toggle_Mute, fmt.tprintf(`{{"sourceId":%s}}`, json_quote(button.source_id, context.temp_allocator)))
		return true

	case .Volume:
		source := link_find_source(link, button.source_id)
		if source == nil do return false
		audio, has_audio := source.audio.?
		if !has_audio do return false
		// Clamped here: the server rejects anything outside 0..1.
		target := clamp(audio.volume + f32(button.direction) * button.step, 0, 1)
		link_request(link, .Audio_Set_Volume, fmt.tprintf(`{{"sourceId":%s,"volume":%.4f}}`,
			json_quote(button.source_id, context.temp_allocator), target))
		return true

	case .Visibility:
		if _, found := link_source_visible(link, button.scene_id, button.source_id); !found do return false
		link_request(link, .Source_Toggle_Visible, fmt.tprintf(`{{"sceneId":%s,"sourceId":%s}}`,
			json_quote(button.scene_id, context.temp_allocator),
			json_quote(button.source_id, context.temp_allocator)))
		return true

	case .Unknown:
		return false
	}
	return false
}

// ---- Appearance ----

// State 0 is the "off" image, state 1 the "on" image.
Button_Look :: struct {
	state: int,
	title: string, // temp-allocated; "" leaves the user's own title alone
}

button_look :: proc(button: ^Button, link: ^Link) -> Button_Look {
	if link.state == .Version_Clash do return {0, "Update\nplugin"}
	if link.state != .Ready         do return {0, "Offline"}

	switch button.kind {
	case .Scene:
		scene := link_find_scene(link, button.scene_id)
		if scene == nil do return {0, "?"}
		return {link_active_scene(link) == button.scene_id ? 1 : 0, ""}

	case .Streaming:
		return {link.snapshot.outputs.streaming ? 1 : 0, ""}

	case .Recording:
		if link.snapshot.outputs.finalizing do return {0, "Saving"}
		return {link.snapshot.outputs.recording ? 1 : 0, ""}

	case .Mute:
		source := link_find_source(link, button.source_id)
		if source == nil do return {0, "?"}
		audio, has_audio := source.audio.?
		if !has_audio do return {0, "?"}
		return {audio.muted ? 1 : 0, ""}

	case .Volume:
		source := link_find_source(link, button.source_id)
		if source == nil do return {0, "?"}
		audio, has_audio := source.audio.?
		if !has_audio do return {0, "?"}
		return {0, fmt.tprintf("%d%%", int(audio.volume * 100 + 0.5))}

	case .Visibility:
		visible, found := link_source_visible(link, button.scene_id, button.source_id)
		if !found do return {0, "?"}
		// State 1 is the hidden look, matching the app's eye-slash icon.
		return {visible ? 0 : 1, ""}

	case .Unknown:
		return {0, "?"}
	}
	return {0, ""}
}

// Pushes the look to the Stream Deck, skipping anything that hasn't changed:
// the app redraws on every setTitle, so this keeps idle buttons quiet.
button_refresh :: proc(button: ^Button, deck: ^Deck, link: ^Link) {
	look := button_look(button, link)

	if look.state != button.last_state {
		deck_set_state(deck, button.context_, look.state)
		button.last_state = look.state
	}
	if look.title != button.last_title {
		deck_set_title(deck, button.context_, look.title)
		delete(button.last_title)
		button.last_title = strings.clone(look.title)
	}
}

// ---- Property inspector payloads ----

// The scene and source lists the settings page fills its dropdowns from.
build_inspector_payload :: proc(link: ^Link, port: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"event":"streamsmith","online":`)
	strings.write_string(&b, link.state == .Ready ? "true" : "false")
	strings.write_string(&b, `,"port":`)
	strings.write_string(&b, fmt.tprintf("%d", port))

	strings.write_string(&b, `,"scenes":[`)
	if link.has_state {
		for scene, i in link.snapshot.scenes {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, fmt.tprintf(`{{"id":%s,"name":%s,"sources":[`,
				json_quote(scene.id, context.temp_allocator),
				json_quote(scene.name, context.temp_allocator)))
			for placement, j in scene.sources {
				if j > 0 do strings.write_byte(&b, ',')
				strings.write_string(&b, json_quote(placement.source_id, context.temp_allocator))
			}
			strings.write_string(&b, "]}")
		}
	}

	strings.write_string(&b, `],"sources":[`)
	if link.has_state {
		for source, i in link.snapshot.sources {
			if i > 0 do strings.write_byte(&b, ',')
			_, has_audio := source.audio.?
			strings.write_string(&b, fmt.tprintf(`{{"id":%s,"name":%s,"kind":%s,"audio":%s}}`,
				json_quote(source.id, context.temp_allocator),
				json_quote(source.name, context.temp_allocator),
				json_quote(source.kind, context.temp_allocator),
				has_audio ? "true" : "false"))
		}
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

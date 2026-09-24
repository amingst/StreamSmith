package streamdeck_plugin

// The Stream Deck side of the plugin: the WebSocket the Stream Deck app tells
// us to connect to, the events it sends, and the commands we send back.
// See https://docs.elgato.com/streamdeck/sdk/references/websocket/plugin/

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import ws "libs:websocket"

Deck :: struct {
	conn:        ws.WS_Connection,
	sock:        net.TCP_Socket,
	plugin_uuid: string, // -pluginUUID, echoed in the registration message
	send_mutex:  sync.Mutex,
	connected:   bool,
}

// What the plugin does with an incoming Stream Deck event. Anything not listed
// here is ignored.
Deck_Event_Kind :: enum {
	Will_Appear,
	Will_Disappear,
	Key_Down,
	Did_Receive_Settings,
	Did_Receive_Global_Settings,
	Property_Inspector_Did_Appear,
	Send_To_Plugin,
	System_Did_Wake_Up,
}

Deck_Event :: struct {
	kind:     Deck_Event_Kind,
	action:   string,      // action UUID, e.g. com.streamsmith.remote.scene
	context_: string,      // the button instance ("context" is a keyword)
	settings: json.Object, // per-button settings, or global settings
	payload:  json.Object, // the raw payload, for sendToPlugin
}

deck_connect :: proc(deck: ^Deck, port: int, plugin_uuid, register_event: string) -> bool {
	ep := net.Endpoint{address = net.IP4_Loopback, port = port}
	sock, dial_err := net.dial_tcp(ep)
	if dial_err != nil {
		log_line("deck: could not connect to 127.0.0.1:%v (%v)", port, dial_err)
		return false
	}

	buf, leftover, hs_err := ws.client_upgrade(sock, "127.0.0.1")
	defer delete(buf)
	if hs_err != .None {
		log_line("deck: handshake failed (%v)", hs_err)
		net.close(sock)
		return false
	}

	deck.sock = sock
	deck.plugin_uuid = strings.clone(plugin_uuid)
	ws.conn_init(&deck.conn, sock, .Client, 4 * 1024 * 1024, leftover)
	deck.connected = true

	// Registration: the event name Stream Deck passed on the command line,
	// plus our own UUID. Nothing else works until this is sent.
	deck_send(deck, fmt.tprintf(`{{"event":"%s","uuid":"%s"}}`, register_event, plugin_uuid))
	return true
}

deck_destroy :: proc(deck: ^Deck) {
	if !deck.connected do return
	ws.conn_destroy(&deck.conn)
	net.close(deck.sock)
	delete(deck.plugin_uuid)
	deck.connected = false
}

@(private)
deck_send :: proc(deck: ^Deck, text: string) {
	sync.guard(&deck.send_mutex)
	if err := ws.ws_send_text(&deck.conn, text); err != .None {
		log_line("deck: send failed (%v)", err)
	}
}

// ---- Commands ----

deck_set_state :: proc(deck: ^Deck, context_: string, state: int) {
	deck_send(deck, fmt.tprintf(
		`{{"event":"setState","context":"%s","payload":{{"state":%d}}}}`, context_, state))
}

deck_set_title :: proc(deck: ^Deck, context_: string, title: string) {
	deck_send(deck, fmt.tprintf(
		`{{"event":"setTitle","context":"%s","payload":{{"title":%s,"target":"both"}}}}`,
		context_, json_quote(title, context.temp_allocator)))
}

deck_show_alert :: proc(deck: ^Deck, context_: string) {
	deck_send(deck, fmt.tprintf(`{{"event":"showAlert","context":"%s"}}`, context_))
}

deck_show_ok :: proc(deck: ^Deck, context_: string) {
	deck_send(deck, fmt.tprintf(`{{"event":"showOk","context":"%s"}}`, context_))
}

deck_get_global_settings :: proc(deck: ^Deck) {
	deck_send(deck, fmt.tprintf(
		`{{"event":"getGlobalSettings","context":"%s"}}`, deck.plugin_uuid))
}

deck_set_global_settings :: proc(deck: ^Deck, payload_json: string) {
	deck_send(deck, fmt.tprintf(
		`{{"event":"setGlobalSettings","context":"%s","payload":%s}}`, deck.plugin_uuid, payload_json))
}

deck_send_to_property_inspector :: proc(deck: ^Deck, context_: string, payload_json: string) {
	deck_send(deck, fmt.tprintf(
		`{{"event":"sendToPropertyInspector","context":"%s","payload":%s}}`, context_, payload_json))
}

deck_log :: proc(deck: ^Deck, message: string) {
	deck_send(deck, fmt.tprintf(
		`{{"event":"logMessage","payload":{{"message":%s}}}}`, json_quote(message, context.temp_allocator)))
}

// ---- Events ----

// Parses one message from the Stream Deck app. ok is false for events this
// plugin doesn't handle, which is most of them.
parse_deck_event :: proc(data: []u8, allocator := context.allocator) -> (event: Deck_Event, ok: bool) {
	value, parse_err := json.parse_string(string(data), json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None && parse_err != .EOF do return {}, false

	obj, is_obj := value.(json.Object)
	if !is_obj do return {}, false

	name, has_name := json_string(obj, "event")
	if !has_name do return {}, false

	kind: Deck_Event_Kind
	switch name {
	case "willAppear":                 kind = .Will_Appear
	case "willDisappear":              kind = .Will_Disappear
	case "keyDown":                    kind = .Key_Down
	case "didReceiveSettings":         kind = .Did_Receive_Settings
	case "didReceiveGlobalSettings":   kind = .Did_Receive_Global_Settings
	case "propertyInspectorDidAppear": kind = .Property_Inspector_Did_Appear
	case "sendToPlugin":               kind = .Send_To_Plugin
	case "systemDidWakeUp":            kind = .System_Did_Wake_Up
	case:                              return {}, false
	}

	event.kind = kind
	event.action, _ = json_string(obj, "action")
	event.context_, _ = json_string(obj, "context")
	if payload, has_payload := obj["payload"].(json.Object); has_payload {
		event.payload = payload
		event.settings, _ = payload["settings"].(json.Object)
	}
	return event, true
}

// ---- Small JSON helpers ----

json_string :: proc(obj: json.Object, key: string) -> (string, bool) {
	value, present := obj[key]
	if !present do return "", false
	s, is_string := value.(json.String)
	return string(s), is_string
}

json_number :: proc(obj: json.Object, key: string) -> (f64, bool) {
	value, present := obj[key]
	if !present do return 0, false
	#partial switch n in value {
	case json.Float:   return f64(n), true
	case json.Integer: return f64(n), true
	}
	return 0, false
}

// Titles come from show names, so they can hold quotes and backslashes.
json_quote :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case:
			if r < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", int(r)))
			} else {
				strings.write_rune(&b, r)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

package streamdeck_plugin

// streamsmith-streamdeck.exe: the Stream Deck app launches this, and it sits
// between that app and StreamSmith's remote API.
//
//   Stream Deck app  <--ws-->  this exe  <--ws-->  StreamSmith (127.0.0.1:4460)
//
// One thread. The Stream Deck socket is read with a short timeout, then the
// StreamSmith socket is polled, so both connections are serviced without
// sharing any state across threads.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ws "libs:websocket"

DECK_READ_TIMEOUT :: 100 * time.Millisecond
DEFAULT_PORT      :: 4460

Plugin :: struct {
	deck:    Deck,
	link:    Link,
	buttons: [dynamic]Button,

	port:            int, // StreamSmith's port, from the plugin's global settings
	inspector:       string, // context of the open property inspector, if any
	last_link_state: Link_State,
}

main :: proc() {
	args := parse_args()
	if args.port == 0 {
		fmt.eprintln("streamsmith-streamdeck: run me from the Stream Deck app (-port, -pluginUUID, -registerEvent, -info)")
		os.exit(2)
	}

	log_open()
	defer log_close()
	log_line("plugin starting (pid %v, deck port %v)", os.get_pid(), args.port)

	plugin: Plugin
	plugin.port = DEFAULT_PORT
	plugin.buttons = make([dynamic]Button, 0, 8)
	defer {
		for &button in plugin.buttons do button_destroy(&button)
		delete(plugin.buttons)
	}

	if !deck_connect(&plugin.deck, args.port, args.plugin_uuid, args.register_event) {
		os.exit(1)
	}
	defer deck_destroy(&plugin.deck)

	// The port lives in the plugin's global settings; until the answer comes
	// back, the default is used.
	deck_get_global_settings(&plugin.deck)

	link_init(&plugin.link, plugin.port)
	defer link_destroy(&plugin.link)

	net.set_option(plugin.deck.sock, .Receive_Timeout, DECK_READ_TIMEOUT)

	for {
		// 1. Anything the Stream Deck app has to say.
		msg, err := ws.ws_read_message(&plugin.deck.conn)
		#partial switch err {
		case .None:
			if msg.kind == .Text {
				if event, ok := parse_deck_event(msg.payload, context.temp_allocator); ok {
					handle_deck_event(&plugin, event)
				}
			}
		case .Timeout:
			// Nothing pending, which is the normal case.
		case:
			// The Stream Deck app closed the socket or went away: exit, and it
			// will start us again when it needs us.
			log_line("deck: connection ended (%v), exiting", err)
			return
		}

		// 2. StreamSmith: connect when it's time, then drain what arrived.
		if link_maybe_connect(&plugin.link) {
			refresh_all(&plugin)
		}
		if link_poll(&plugin.link) {
			refresh_all(&plugin)
		}

		// A link state change is worth a line in the log and a fresh inspector.
		if plugin.link.state != plugin.last_link_state {
			plugin.last_link_state = plugin.link.state
			push_inspector(&plugin)
		}

		free_all(context.temp_allocator)
	}
}

// ---- Stream Deck events ----

@(private)
handle_deck_event :: proc(plugin: ^Plugin, event: Deck_Event) {
	switch event.kind {
	case .Will_Appear:
		button := find_button(plugin, event.context_)
		if button == nil {
			append(&plugin.buttons, Button{
				context_ = strings.clone(event.context_),
				kind     = action_kind_from_uuid(event.action),
				// A fresh button has no look yet; -1 forces the first push.
				last_state = -1,
			})
			button = &plugin.buttons[len(plugin.buttons) - 1]
		}
		button_apply_settings(button, event.settings)
		button_refresh(button, &plugin.deck, &plugin.link)

	case .Will_Disappear:
		for &button, i in plugin.buttons {
			if button.context_ != event.context_ do continue
			button_destroy(&button)
			unordered_remove(&plugin.buttons, i)
			break
		}

	case .Did_Receive_Settings:
		button := find_button(plugin, event.context_)
		if button == nil do return
		button_apply_settings(button, event.settings)
		button.last_state = -1 // the target changed, so re-push even if it looks the same
		button_refresh(button, &plugin.deck, &plugin.link)

	case .Key_Down:
		button := find_button(plugin, event.context_)
		if button == nil do return
		if !button_press(button, &plugin.link) {
			deck_show_alert(&plugin.deck, event.context_)
		}

	case .Did_Receive_Global_Settings:
		port := DEFAULT_PORT
		if settings, has_settings := event.payload["settings"].(json.Object); has_settings {
			if value, ok := json_number(settings, "port"); ok && value >= 1 && value <= 65535 {
				port = int(value)
			}
		}
		if port != plugin.port {
			log_line("link: port set to %v", port)
			plugin.port = port
			link_set_port(&plugin.link, port)
			refresh_all(plugin)
		}

	case .Property_Inspector_Did_Appear:
		plugin.inspector = strings.clone(event.context_)
		push_inspector(plugin)

	case .Send_To_Plugin:
		// The settings page asks for the lists, or sets the port.
		if action, ok := json_string(event.payload, "action"); ok {
			switch action {
			case "getData":
				plugin.inspector = strings.clone(event.context_)
				push_inspector(plugin)
			case "setPort":
				if value, has_port := json_number(event.payload, "port"); has_port && value >= 1 && value <= 65535 {
					deck_set_global_settings(&plugin.deck, fmt.tprintf(`{{"port":%d}}`, int(value)))
					plugin.port = int(value)
					link_set_port(&plugin.link, plugin.port)
				}
			}
		}

	case .System_Did_Wake_Up:
		// Sockets rarely survive sleep; drop and let the backoff reconnect.
		log_line("link: system woke up, reconnecting")
		link_set_port(&plugin.link, plugin.port)
	}
}

@(private)
find_button :: proc(plugin: ^Plugin, context_: string) -> ^Button {
	for &button in plugin.buttons {
		if button.context_ == context_ do return &button
	}
	return nil
}

@(private)
refresh_all :: proc(plugin: ^Plugin) {
	for &button in plugin.buttons {
		button_refresh(&button, &plugin.deck, &plugin.link)
	}
	push_inspector(plugin)
}

@(private)
push_inspector :: proc(plugin: ^Plugin) {
	if plugin.inspector == "" do return
	payload := build_inspector_payload(&plugin.link, plugin.port, context.temp_allocator)
	deck_send_to_property_inspector(&plugin.deck, plugin.inspector, payload)
}

// ---- Command line ----

Args :: struct {
	port:           int,
	plugin_uuid:    string,
	register_event: string,
	info:           string,
}

// Stream Deck starts the plugin with:
//   -port <n> -pluginUUID <uuid> -registerEvent <event> -info <json>
@(private)
parse_args :: proc() -> (args: Args) {
	rest := os.args[1:]
	for i := 0; i + 1 < len(rest); i += 2 {
		value := rest[i + 1]
		switch rest[i] {
		case "-port":          args.port, _ = strconv.parse_int(value)
		case "-pluginUUID":    args.plugin_uuid = value
		case "-registerEvent": args.register_event = value
		case "-info":          args.info = value
		}
	}
	return
}

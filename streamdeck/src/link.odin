package streamdeck_plugin

// The StreamSmith side: one shared connection for every button, a local copy
// of the snapshot, and reconnection with backoff while StreamSmith is closed.

import "core:encoding/json"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import ws "libs:websocket"

import "../../src/remote/protocol"

RECONNECT_MIN :: 1 * time.Second
RECONNECT_MAX :: 10 * time.Second
READ_TIMEOUT  :: 1 * time.Second

Link_State :: enum {
	Offline,       // not connected, or connecting
	Connected,     // socket up, hello sent, waiting for welcome
	Ready,         // welcome received and the first snapshot is in
	Version_Clash, // the app speaks a protocol this plugin doesn't
}

Link :: struct {
	sock:      net.TCP_Socket,
	conn:      ws.WS_Connection,
	state:     Link_State,
	port:      int,
	next_id:   i64,
	snapshot:  protocol.Snapshot,
	has_state: bool,

	// The reader thread owns the socket; the main thread only reads `state`
	// and `snapshot`, which are updated between events it processes.
	mutex: sync.Mutex,

	retry_at:    time.Time,
	retry_delay: time.Duration,

	// Everything in `snapshot` is allocated here, including the strings the
	// events replace, so the tests can hand it a temp allocator.
	allocator: mem.Allocator,
}

link_init :: proc(link: ^Link, port: int, allocator := context.allocator) {
	link.allocator = allocator
	link.port = port
	link.state = .Offline
	link.retry_delay = RECONNECT_MIN
	link.retry_at = time.now()
}

link_destroy :: proc(link: ^Link) {
	link_disconnect(link)
	if link.has_state {
		protocol.destroy_snapshot(&link.snapshot, link.allocator)
		link.has_state = false
	}
}

link_set_port :: proc(link: ^Link, port: int) {
	if link.port == port do return
	link.port = port
	link_disconnect(link)
	link.retry_at = time.now() // try the new port straight away
	link.retry_delay = RECONNECT_MIN
}

@(private)
link_disconnect :: proc(link: ^Link) {
	if link.state == .Offline do return
	ws.ws_send_close(&link.conn, 1000)
	ws.conn_destroy(&link.conn)
	net.close(link.sock)
	link.state = .Offline
}

// Tries to open the connection when the backoff allows it. Returns true when
// a connection was made this call.
link_maybe_connect :: proc(link: ^Link) -> bool {
	if link.state != .Offline do return false
	if time.diff(time.now(), link.retry_at) > 0 do return false

	link.retry_at = time.time_add(time.now(), link.retry_delay)
	link.retry_delay = min(link.retry_delay * 2, RECONNECT_MAX)

	ep := net.Endpoint{address = net.IP4_Loopback, port = link.port}
	sock, dial_err := net.dial_tcp(ep)
	if dial_err != nil do return false // StreamSmith isn't running; try again later

	buf, leftover, hs_err := ws.client_upgrade(sock, "127.0.0.1")
	defer delete(buf)
	if hs_err != .None {
		net.close(sock)
		return false
	}

	net.set_option(sock, .Receive_Timeout, READ_TIMEOUT)
	link.sock = sock
	ws.conn_init(&link.conn, sock, .Client, 4 * 1024 * 1024, leftover)
	link.state = .Connected
	link.next_id = 1

	link_send(link, protocol.encode_hello(PLUGIN_CLIENT_NAME, context.temp_allocator))
	log_line("link: connected to StreamSmith on port %v", link.port)
	return true
}

@(private)
link_send :: proc(link: ^Link, payload: []u8) {
	if link.state == .Offline do return
	if err := ws.ws_send_text(&link.conn, string(payload)); err != .None {
		log_line("link: send failed (%v)", err)
		link_drop(link)
	}
}

@(private)
link_drop :: proc(link: ^Link) {
	if link.state == .Offline do return
	ws.conn_destroy(&link.conn)
	net.close(link.sock)
	link.state = .Offline
	link.retry_at = time.time_add(time.now(), RECONNECT_MIN)
	link.retry_delay = RECONNECT_MIN
	log_line("link: disconnected from StreamSmith")
}

// Sends a method with no params.
link_request :: proc(link: ^Link, method: protocol.Method, params_json := "") {
	if link.state == .Offline || link.state == .Version_Clash do return
	id := link.next_id
	link.next_id += 1
	link_send(link, protocol.encode_request(id, method, params_json, context.temp_allocator))
}

// Reads whatever has arrived without blocking for long, applying it to the
// local snapshot. Returns true when the state changed and buttons need a
// refresh.
link_poll :: proc(link: ^Link) -> (changed: bool) {
	if link.state == .Offline do return false

	for {
		msg, err := ws.ws_read_message(&link.conn)
		#partial switch err {
		case .Timeout:
			return changed
		case .None:
			if msg.kind != .Text do continue
			if link_apply(link, msg.payload) do changed = true
			continue
		case:
			link_drop(link)
			return true // buttons go to the offline look
		}
	}
}

@(private)
link_apply :: proc(link: ^Link, payload: []u8) -> (changed: bool) {
	msg, ok, err := protocol.decode_outbound(payload, context.temp_allocator)
	if !ok {
		if err != "" do log_line("link: %s", err)
		return false
	}

	switch m in msg {
	case protocol.Server_Welcome:
		if m.protocol != protocol.PROTOCOL_VERSION {
			log_line("link: StreamSmith speaks protocol %v, this plugin speaks %v", m.protocol, protocol.PROTOCOL_VERSION)
			link.state = .Version_Clash
			return true
		}
		link.state = .Ready
		log_line("link: %s", m.server)
		// Everything, so the buttons can mirror any change.
		link_request(link, .Events_Subscribe, `{"events":["scene","outputs","audio","sources","show"]}`)
		link_request(link, .State_Get)
		return true

	case protocol.Server_Response:
		if !m.ok {
			log_line("link: request %v failed: %s (%s)", m.id, m.code, m.message)
			return false
		}
		// The only request whose result we read is state.get; everything else
		// shows up as an event.
		if m.result != nil && ("scenes" in m.result || "show" in m.result) {
			link_replace_snapshot(link, m.result)
			return true
		}
		return false

	case protocol.Server_Event:
		return link_apply_event(link, m)

	case protocol.Server_Error:
		log_line("link: server error %s: %s", m.code, m.message)
		if m.code == "unsupported_protocol" do link.state = .Version_Clash
		return true
	}
	return false
}

@(private)
link_replace_snapshot :: proc(link: ^Link, result: json.Object) {
	sync.guard(&link.mutex)
	if link.has_state do protocol.destroy_snapshot(&link.snapshot, link.allocator)
	snapshot, ok := protocol.decode_snapshot(result, link.allocator)
	link.snapshot = snapshot
	link.has_state = ok
}

// Events carry the final value, so they are applied straight onto the local
// copy. The list and show events invalidate too much to patch, so they trigger
// a re-fetch instead.
@(private)
link_apply_event :: proc(link: ^Link, event: protocol.Server_Event) -> (changed: bool) {
	#partial switch event.name {
	case .Scenes_List_Changed, .Sources_List_Changed:
		link_request(link, .State_Get)
		return false

	case .Show_Changed:
		// Every id from the old show is meaningless now.
		link_request(link, .State_Get)
		return true
	}

	if !link.has_state do return false
	sync.guard(&link.mutex)

	#partial switch event.name {
	case .Scene_Changed:
		if id, has_id := deck_json_string(event.data, "sceneId"); has_id {
			link_set_active_scene(link, id)
		} else {
			link_set_active_scene(link, "")
		}
		return true

	case .Recording_Changed:
		link.snapshot.outputs.recording, _ = deck_json_bool(event.data, "recording")
		link.snapshot.outputs.finalizing, _ = deck_json_bool(event.data, "finalizing")
		return true

	case .Streaming_Changed:
		link.snapshot.outputs.streaming, _ = deck_json_bool(event.data, "streaming")
		return true

	case .Audio_Mute_Changed:
		source_id, _ := deck_json_string(event.data, "sourceId")
		muted, _ := deck_json_bool(event.data, "muted")
		for &source in link.snapshot.sources {
			if source.id != source_id do continue
			if audio, has_audio := source.audio.?; has_audio {
				audio.muted = muted
				source.audio = audio
			}
		}
		return true

	case .Audio_Volume_Changed:
		source_id, _ := deck_json_string(event.data, "sourceId")
		volume, _ := deck_json_number(event.data, "volume")
		for &source in link.snapshot.sources {
			if source.id != source_id do continue
			if audio, has_audio := source.audio.?; has_audio {
				audio.volume = f32(volume)
				source.audio = audio
			}
		}
		return true

	case .Source_Visibility_Changed:
		scene_id, _ := deck_json_string(event.data, "sceneId")
		source_id, _ := deck_json_string(event.data, "sourceId")
		visible, _ := deck_json_bool(event.data, "visible")
		for &scene in link.snapshot.scenes {
			if scene.id != scene_id do continue
			for &placement in scene.sources {
				if placement.source_id == source_id do placement.visible = visible
			}
		}
		return true
	}
	return false
}

@(private)
link_set_active_scene :: proc(link: ^Link, scene_id: string) {
	if old, has_old := link.snapshot.active_scene_id.?; has_old do delete(old, link.allocator)
	link.snapshot.active_scene_id = scene_id == "" ? nil : strings.clone(scene_id, link.allocator)
}

// ---- Lookups used by the button logic ----

link_active_scene :: proc(link: ^Link) -> string {
	if !link.has_state do return ""
	return link.snapshot.active_scene_id.? or_else ""
}

link_find_source :: proc(link: ^Link, id: string) -> ^protocol.Snapshot_Source {
	if !link.has_state do return nil
	for &source in link.snapshot.sources {
		if source.id == id do return &source
	}
	return nil
}

link_find_scene :: proc(link: ^Link, id: string) -> ^protocol.Snapshot_Scene {
	if !link.has_state do return nil
	for &scene in link.snapshot.scenes {
		if scene.id == id do return &scene
	}
	return nil
}

// Visibility of a source in a scene, using the first placement -- the same one
// source.toggleVisible resolves from.
link_source_visible :: proc(link: ^Link, scene_id, source_id: string) -> (visible: bool, found: bool) {
	scene := link_find_scene(link, scene_id)
	if scene == nil do return false, false
	for placement in scene.sources {
		if placement.source_id == source_id do return placement.visible, true
	}
	return false, false
}

// Small wrappers so link.odin doesn't depend on deck.odin's helper names.
@(private)
deck_json_string :: proc(obj: json.Object, key: string) -> (string, bool) {
	return json_string(obj, key)
}

@(private)
deck_json_number :: proc(obj: json.Object, key: string) -> (f64, bool) {
	return json_number(obj, key)
}

@(private)
deck_json_bool :: proc(obj: json.Object, key: string) -> (bool, bool) {
	value, present := obj[key]
	if !present do return false, false
	b, is_bool := value.(json.Boolean)
	return bool(b), is_bool
}

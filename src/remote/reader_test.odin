package remote

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"
import ws "libs:websocket"

import "../action"
import "protocol"

HELLO :: `{"type":"hello","protocol":1,"client":"tests"}`

@(private="file")
peer_send :: proc(t: ^testing.T, peer: ^Peer, text: string) -> bool {
	return testing.expectf(t, ws.ws_send_text(&peer.conn, text) == .None, "send %v", text)
}

// Reads one message and parses it as a JSON object.
@(private="file")
peer_expect_json :: proc(t: ^testing.T, peer: ^Peer) -> (obj: json.Object, ok: bool) {
	msg, err := ws.ws_read_message(&peer.conn)
	if !testing.expectf(t, err == .None, "read: %v", err) do return
	value, parse_err := json.parse_string(string(msg.payload), allocator = context.temp_allocator)
	if !testing.expectf(t, parse_err == .None || parse_err == .EOF, "parse %v: %v", string(msg.payload), parse_err) do return
	obj, ok = value.(json.Object)
	testing.expectf(t, ok, "not an object: %v", string(msg.payload))
	return
}

// json.parse_string yields Float for numbers unless integers are requested,
// so read both shapes.
@(private="file")
json_number :: proc(v: json.Value) -> i64 {
	#partial switch n in v {
	case json.Integer: return i64(n)
	case json.Float:   return i64(n)
	}
	return 0
}

@(private="file")
peer_greet :: proc(t: ^testing.T, peer: ^Peer) -> bool {
	if !peer_send(t, peer, HELLO) do return false
	obj := peer_expect_json(t, peer) or_return
	return testing.expect_value(t, obj["type"].(json.String) or_else "", "welcome")
}

// Drains the action queue, which the main loop would normally do each frame.
@(private="file")
await_action :: proc(h: ^Harness) -> (env: action.Envelope, ok: bool) {
	for _ in 0 ..< 200 {
		action.queue_drain(&h.queue, &h.batch)
		if len(h.batch) > 0 {
			env = h.batch[0]
			// Kept out of the batch so queue_release doesn't free its strings.
			ordered_remove(&h.batch, 0)
			return env, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return {}, false
}

@(private="file")
release_action :: proc(h: ^Harness, env: action.Envelope) {
	env := env
	append(&h.batch, env)
	action.queue_release(&h.queue, &h.batch)
}

@(test)
hello_gets_a_welcome :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47321) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return

	if !peer_send(t, &peer, HELLO) do return
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect_value(t, obj["type"].(json.String) or_else "", "welcome")
	testing.expect_value(t, int(json_number(obj["protocol"])), protocol.PROTOCOL_VERSION)
	testing.expect_value(t, obj["server"].(json.String) or_else "", "test")
}

@(test)
unsupported_protocol_is_refused :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47322) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return

	if !peer_send(t, &peer, `{"type":"hello","protocol":99}`) do return
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect_value(t, obj["type"].(json.String) or_else "", "error")
	testing.expect_value(t, obj["code"].(json.String) or_else "", "unsupported_protocol")

	msg, err := ws.ws_read_message(&peer.conn)
	testing.expect_value(t, err, ws.Conn_Error.Closed)
	testing.expect_value(t, msg.code, u16(protocol.CLOSE_UNSUPPORTED_VERSION))
}

@(test)
a_request_before_hello_is_refused :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47323) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return

	if !peer_send(t, &peer, `{"type":"request","id":1,"method":"recording.start"}`) do return

	msg, err := ws.ws_read_message(&peer.conn)
	testing.expect_value(t, err, ws.Conn_Error.Closed)
	testing.expect_value(t, msg.code, u16(protocol.CLOSE_HANDSHAKE_REQUIRED))
}

@(test)
a_second_hello_is_an_error_but_stays_open :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47324) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return

	if !peer_send(t, &peer, HELLO) do return
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect_value(t, obj["type"].(json.String) or_else "", "error")
	testing.expect_value(t, obj["code"].(json.String) or_else "", "bad_request")

	// Still usable.
	if !peer_send(t, &peer, `{"type":"request","id":7,"method":"events.subscribe","params":{"events":[]}}`) do return
	reply, reply_ok := peer_expect_json(t, &peer)
	if !reply_ok do return
	testing.expect_value(t, int(json_number(reply["id"])), 7)
}

@(test)
an_action_request_is_queued_with_its_reply_handle :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47325) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return
	await_clients(&h, 1)

	if !peer_send(t, &peer, `{"type":"request","id":42,"method":"scene.set","params":{"sceneId":"scene-a"}}`) do return

	env, got := await_action(&h)
	if !testing.expect(t, got, "no action reached the queue") do return
	defer release_action(&h, env)

	set_scene, is_set_scene := env.action.(action.Action_Set_Scene)
	testing.expect(t, is_set_scene, "wrong action type")
	testing.expect_value(t, set_scene.scene_id, "scene-a")
	testing.expect_value(t, env.origin, action.Envelope_Origin.Remote)

	reply, has_reply := env.reply.?
	testing.expect(t, has_reply, "no reply handle")
	testing.expect_value(t, reply.request_id, i64(42))
	testing.expect_value(t, reply.client_id, first_client(&h).id)

	// No response until the bridge sends one.
	server_respond(&h.server, reply.client_id,
		protocol.encode_response_ok(reply.request_id, nil, context.temp_allocator))
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect_value(t, int(json_number(obj["id"])), 42)
	testing.expect(t, obj["ok"].(json.Boolean) or_else false, "not ok")
}

@(test)
state_get_returns_the_published_snapshot :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47326) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return

	// Before any publish.
	if !peer_send(t, &peer, `{"type":"request","id":1,"method":"state.get"}`) do return
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect(t, !(obj["ok"].(json.Boolean) or_else true), "expected a failure")
	err_obj := obj["error"].(json.Object) or_else nil
	testing.expect_value(t, err_obj["code"].(json.String) or_else "", "failed")

	server_publish_snapshot(&h.server, transmute([]u8)string(`{"activeSceneId":"scene-a"}`))

	if !peer_send(t, &peer, `{"type":"request","id":2,"method":"state.get"}`) do return
	obj2, ok2 := peer_expect_json(t, &peer)
	if !ok2 do return
	testing.expect(t, obj2["ok"].(json.Boolean) or_else false, "not ok")
	result := obj2["result"].(json.Object) or_else nil
	testing.expect_value(t, result["activeSceneId"].(json.String) or_else "", "scene-a")

	// Nothing reached the queue.
	action.queue_drain(&h.queue, &h.batch)
	testing.expect_value(t, len(h.batch), 0)
}

@(test)
subscribe_sets_the_topics_used_by_broadcast :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47327) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return
	await_clients(&h, 1)

	if !peer_send(t, &peer, `{"type":"request","id":3,"method":"events.subscribe","params":{"events":["scene","audio"]}}`) do return
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect(t, obj["ok"].(json.Boolean) or_else false, "not ok")

	client := first_client(&h)
	if !testing.expect(t, client != nil, "no client") do return
	testing.expect(t, client.topics == {.Scene, .Audio}, fmt.tprintf("topics %v", client.topics))

	server_broadcast(&h.server, .Show, transmute([]u8)string("unsubscribed"))
	server_broadcast(&h.server, .Scene, transmute([]u8)string("subscribed"))
	peer_expect_text(t, &peer, "subscribed")
}

@(test)
faults_after_the_handshake_keep_the_connection :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47328) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return

	// Unknown method: a response, since the id could be read.
	if !peer_send(t, &peer, `{"type":"request","id":5,"method":"scene.explode"}`) do return
	obj, ok := peer_expect_json(t, &peer)
	if !ok do return
	testing.expect_value(t, obj["type"].(json.String) or_else "", "response")
	testing.expect_value(t, int(json_number(obj["id"])), 5)
	err_obj := obj["error"].(json.Object) or_else nil
	testing.expect_value(t, err_obj["code"].(json.String) or_else "", "unknown_method")

	// Malformed JSON: no id to answer, so a standalone error message.
	if !peer_send(t, &peer, `{"type":"request",`) do return
	obj2, ok2 := peer_expect_json(t, &peer)
	if !ok2 do return
	testing.expect_value(t, obj2["type"].(json.String) or_else "", "error")
	testing.expect_value(t, obj2["code"].(json.String) or_else "", "bad_request")

	// Missing params: a response against the request's id.
	if !peer_send(t, &peer, `{"type":"request","id":6,"method":"scene.set","params":{}}`) do return
	obj3, ok3 := peer_expect_json(t, &peer)
	if !ok3 do return
	testing.expect_value(t, int(json_number(obj3["id"])), 6)
	err3 := obj3["error"].(json.Object) or_else nil
	testing.expect_value(t, err3["code"].(json.String) or_else "", "bad_request")

	action.queue_drain(&h.queue, &h.batch)
	testing.expect_value(t, len(h.batch), 0)
}

@(test)
a_binary_frame_closes_the_connection :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47329) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return

	testing.expect_value(t, ws.ws_send_binary(&peer.conn, []u8{1, 2, 3}), ws.Conn_Error.None)

	msg, err := ws.ws_read_message(&peer.conn)
	testing.expect_value(t, err, ws.Conn_Error.Closed)
	testing.expect_value(t, msg.code, u16(protocol.CLOSE_UNSUPPORTED_DATA))
}

@(test)
request_to_action_covers_every_method :: proc(t: ^testing.T) {
	Case :: struct {
		method: protocol.Method,
		params: protocol.Params,
		want:   action.Action,
	}
	cases := []Case{
		{.State_Get, nil, nil},
		{.Events_Subscribe, protocol.Params_Subscribe{topics = {.Scene}}, nil},
		{.Scene_Set, protocol.Params_Scene_Set{scene_id = "s"}, action.Action_Set_Scene{scene_id = "s"}},
		{.Recording_Start, nil, action.Action_Start_Recording{}},
		{.Recording_Stop, nil, action.Action_Stop_Recording{}},
		{.Recording_Toggle, nil, action.Action_Toggle_Recording{}},
		{.Streaming_Start, nil, action.Action_Start_Streaming{}},
		{.Streaming_Stop, nil, action.Action_Stop_Streaming{}},
		{.Streaming_Toggle, nil, action.Action_Toggle_Streaming{}},
		{.Audio_Set_Mute, protocol.Params_Mute{source_id = "mic", muted = true},
			action.Action_Set_Mute{source_id = "mic", muted = true}},
		{.Audio_Toggle_Mute, protocol.Params_Mute{source_id = "mic"},
			action.Action_Toggle_Mute{source_id = "mic"}},
		{.Audio_Set_Volume, protocol.Params_Volume{source_id = "mic", volume = 0.5},
			action.Action_Set_Volume{source_id = "mic", volume = 0.5}},
		{.Source_Set_Visible, protocol.Params_Visible{scene_id = "s", source_id = "src", visible = false},
			action.Action_Set_Source_Visible{scene_id = "s", source_id = "src", visible = false}},
		{.Source_Toggle_Visible, protocol.Params_Visible{scene_id = "s", source_id = "src"},
			action.Action_Toggle_Source_Visible{scene_id = "s", source_id = "src"}},
	}
	for c in cases {
		got := request_to_action(c.method, c.params)
		testing.expectf(t, got == c.want, "%v: want %v, got %v", c.method, c.want, got)
	}
	testing.expect_value(t, len(cases), len(protocol.Method))
}

// ---- keepalive and reaping ----

@(test)
a_client_that_never_greets_is_closed :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47331, Server_Config{hello_deadline = 150 * time.Millisecond}) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return

	msg, err := ws.ws_read_message(&peer.conn)
	testing.expect_value(t, err, ws.Conn_Error.Closed)
	testing.expect_value(t, msg.code, u16(protocol.CLOSE_HANDSHAKE_REQUIRED))

	await_client_loss(&h, 0)
	testing.expect_value(t, client_count(&h.server), 0)
}

@(test)
a_client_that_stops_answering_is_dropped :: proc(t: ^testing.T) {
	h: Harness
	cfg := Server_Config{ping_interval = 50 * time.Millisecond, pong_timeout = 200 * time.Millisecond}
	if !harness_open(t, &h, 47332, cfg) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return
	await_clients(&h, 1)

	// The peer never reads, so it never pongs.
	await_client_loss(&h, 0)
	testing.expect_value(t, client_count(&h.server), 0)
}

@(test)
a_reading_client_stays_connected :: proc(t: ^testing.T) {
	h: Harness
	cfg := Server_Config{ping_interval = 30 * time.Millisecond, pong_timeout = 150 * time.Millisecond}
	if !harness_open(t, &h, 47333, cfg) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	if !peer_greet(t, &peer) do return
	await_clients(&h, 1)

	// ws_read_message answers pings with pongs; the reads time out otherwise.
	net.set_option(peer.sock, .Receive_Timeout, 100 * time.Millisecond)
	for _ in 0 ..< 6 {
		_, err := ws.ws_read_message(&peer.conn)
		if !testing.expectf(t, err == .Timeout, "unexpected read: %v", err) do return
	}

	testing.expect_value(t, client_count(&h.server), 1)
}

// Slots have to come back, or the 8-client cap would lock the server out
// after enough reconnections.
@(test)
disconnected_clients_free_their_slot :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47334) do return
	defer harness_close(&h)

	for i in 0 ..< MAX_CLIENTS + 4 {
		peer: Peer
		if !testing.expectf(t, peer_connect(t, &h, &peer), "connection %v refused", i) do return
		if !peer_greet(t, &peer) do return
		await_clients(&h, 1)
		peer_close(&peer)
		await_client_loss(&h, 0)
		testing.expectf(t, client_count(&h.server) == 0, "connection %v left a client behind", i)
	}
}

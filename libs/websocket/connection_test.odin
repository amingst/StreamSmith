package websocket

import "core:net"
import "core:slice"
import "core:testing"
import "core:thread"
import "core:time"

// Sends raw bytes from the client end, bypassing ws_send_* so a test can put
// malformed or hand-built frames on the wire.
@(private="file")
raw_send :: proc(p: ^Conn_Pair, bytes: ..u8) {
	buf := slice.clone(bytes)
	defer delete(buf)
	net.send_tcp(p.lb.client, buf)
}

// Reads exactly one frame off the socket, below the connection layer, so a
// test can assert on control frames the reader would otherwise swallow.
@(private="file")
recv_one_frame :: proc(t: ^testing.T, sock: net.TCP_Socket) -> (op: Opcode, payload: []u8) {
	// A frame goes out as a header write then a payload write, so it can
	// arrive in several segments.
	buf: [1024]u8
	have := 0

	h: Frame_Header
	header_len: int
	for {
		n, err := net.recv_tcp(sock, buf[have:])
		if !testing.expect_value(t, err, nil) do return
		if !testing.expect(t, n > 0, "peer closed before a whole frame arrived") do return
		have += n

		frame_err: Frame_Error
		h, header_len, frame_err = decode_header(buf[:have])
		if frame_err == .Need_More do continue
		if !testing.expect_value(t, frame_err, Frame_Error.None) do return
		if have >= header_len + int(h.payload_len) do break
	}

	body := buf[header_len:header_len + int(h.payload_len)]
	if h.masked do apply_mask(body, h.mask_key)
	return h.opcode, slice.clone(body)
}

// A masked client frame, built by hand.
@(private="file")
client_frame :: proc(opcode: Opcode, fin: bool, payload: []u8, allocator := context.allocator) -> []u8 {
	h := Frame_Header{
		fin         = fin,
		opcode      = opcode,
		masked      = true,
		mask_key    = {0x11, 0x22, 0x33, 0x44},
		payload_len = u64(len(payload)),
	}
	header: [MAX_HEADER]u8
	n := encode_header(h, &header)

	out := make([]u8, n + len(payload), allocator)
	copy(out, header[:n])
	copy(out[n:], payload)
	apply_mask(out[n:], h.mask_key)
	return out
}

// ---- round trips ----

@(test)
text_round_trip_each_size :: proc(t: ^testing.T) {
	sizes := []int{0, 1, 5, 125, 126, 1024, 0xFFFF, 0x1_0000}

	for size in sizes {
		p, ok := conn_pair_open(t)
		defer conn_pair_close(&p)
		if !ok do return

		sent := make([]u8, size)
		defer delete(sent)
		for &b, i in sent do b = u8('a' + i % 26)

		send_err := ws_send_text(&p.client_ws, string(sent))
		testing.expectf(t, send_err == .None, "size %v: send %v", size, send_err)

		msg, err := ws_read_message(&p.server_ws)
		testing.expectf(t, err == .None, "size %v: read %v", size, err)
		testing.expectf(t, msg.kind == .Text, "size %v: kind %v", size, msg.kind)
		testing.expectf(t, slice.equal(msg.payload, sent), "size %v: payload mismatch", size)
	}
}

// Server to client: the server never masks, so this covers the other role.
@(test)
server_to_client_round_trip :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	testing.expect_value(t, ws_send_text(&p.server_ws, "hello from the server"), Conn_Error.None)

	msg, err := ws_read_message(&p.client_ws)
	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "hello from the server")
}

// Two messages in one TCP segment: the second must survive the first read.
@(test)
two_messages_in_one_write :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	first := client_frame(.Text, true, transmute([]u8)string("one"))
	defer delete(first)
	second := client_frame(.Text, true, transmute([]u8)string("two"))
	defer delete(second)

	both := make([]u8, len(first) + len(second))
	defer delete(both)
	copy(both, first)
	copy(both[len(first):], second)
	net.send_tcp(p.lb.client, both)

	msg1, err1 := ws_read_message(&p.server_ws)
	testing.expect_value(t, err1, Conn_Error.None)
	testing.expect_value(t, string(msg1.payload), "one")

	msg2, err2 := ws_read_message(&p.server_ws)
	testing.expect_value(t, err2, Conn_Error.None)
	testing.expect_value(t, string(msg2.payload), "two")
}

@(test)
message_split_byte_by_byte :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	frame := client_frame(.Text, true, transmute([]u8)string("dribbled in one byte at a time"))
	defer delete(frame)

	Drip :: struct { sock: net.TCP_Socket, data: []u8 }
	drip := Drip{p.lb.client, frame}
	sender := thread.create_and_start_with_poly_data(&drip, proc(d: ^Drip) {
		for i in 0 ..< len(d.data) {
			net.send_tcp(d.sock, d.data[i:i + 1])
			time.sleep(time.Millisecond)
		}
	})
	defer thread.destroy(sender)

	msg, err := ws_read_message(&p.server_ws)
	thread.join(sender)

	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "dribbled in one byte at a time")
}

// ---- fragmentation ----

@(test)
fragments_are_reassembled :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	f1 := client_frame(.Text, false, transmute([]u8)string("frag"))
	defer delete(f1)
	f2 := client_frame(.Continuation, false, transmute([]u8)string("ment"))
	defer delete(f2)
	f3 := client_frame(.Continuation, true, transmute([]u8)string("ed!"))
	defer delete(f3)

	net.send_tcp(p.lb.client, f1)
	net.send_tcp(p.lb.client, f2)
	net.send_tcp(p.lb.client, f3)

	msg, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "fragmented!")
}

// A ping between two fragments is answered without disturbing reassembly.
@(test)
ping_between_fragments :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	f1 := client_frame(.Text, false, transmute([]u8)string("before "))
	defer delete(f1)
	ping := client_frame(.Ping, true, transmute([]u8)string("pingdata"))
	defer delete(ping)
	f2 := client_frame(.Continuation, true, transmute([]u8)string("after"))
	defer delete(f2)

	net.send_tcp(p.lb.client, f1)
	net.send_tcp(p.lb.client, ping)
	net.send_tcp(p.lb.client, f2)

	msg, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "before after")

	// The server answered the ping while reassembling, so a pong is waiting.
	op, payload := recv_one_frame(t, p.lb.client)
	defer delete(payload)
	testing.expect_value(t, op, Opcode.Pong)
	testing.expect_value(t, string(payload), "pingdata")
}

@(test)
continuation_without_message_is_rejected :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	stray := client_frame(.Continuation, true, transmute([]u8)string("nope"))
	defer delete(stray)
	net.send_tcp(p.lb.client, stray)

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Bad_Continuation)
}

@(test)
new_data_frame_mid_message_is_rejected :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	f1 := client_frame(.Text, false, transmute([]u8)string("open"))
	defer delete(f1)
	f2 := client_frame(.Text, true, transmute([]u8)string("again"))
	defer delete(f2)
	net.send_tcp(p.lb.client, f1)
	net.send_tcp(p.lb.client, f2)

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Bad_Continuation)
}

// ---- control frames ----

@(test)
ping_is_answered_with_matching_pong :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	testing.expect_value(t, ws_send_ping(&p.client_ws, transmute([]u8)string("keepalive")), Conn_Error.None)

	// A ping is answered from inside a read, so the server end needs to be
	// reading; it returns once the text below arrives.
	Reader :: struct { c: ^WS_Connection, got: string }
	r := Reader{&p.server_ws, ""}
	reader := thread.create_and_start_with_poly_data(&r, proc(r: ^Reader) {
		msg, _ := ws_read_message(r.c)
		r.got = string(msg.payload)
	})
	defer thread.destroy(reader)

	op, payload := recv_one_frame(t, p.lb.client)
	defer delete(payload)
	testing.expect_value(t, op, Opcode.Pong)
	testing.expect_value(t, string(payload), "keepalive")

	ws_send_text(&p.client_ws, "done")
	thread.join(reader)
	testing.expect_value(t, r.got, "done")
}

// A pong read back through ws_read_message sets got_pong and is not returned.
@(test)
pong_sets_got_pong :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	pong := client_frame(.Pong, true, transmute([]u8)string("x"))
	defer delete(pong)
	text := client_frame(.Text, true, transmute([]u8)string("after the pong"))
	defer delete(text)
	net.send_tcp(p.lb.client, pong)
	net.send_tcp(p.lb.client, text)

	msg, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "after the pong")
	testing.expect_value(t, p.server_ws.got_pong, true)
}

@(test)
close_is_echoed_and_reported :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	testing.expect_value(t, ws_send_close(&p.client_ws, 1001, "going away"), Conn_Error.None)

	msg, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Closed)
	testing.expect_value(t, msg.kind, Message_Kind.Close)
	testing.expect_value(t, msg.code, 1001)
	testing.expect_value(t, msg.reason, "going away")
	testing.expect_value(t, p.server_ws.close_sent, true)

	echoed, echo_err := ws_read_message(&p.client_ws)
	testing.expect_value(t, echo_err, Conn_Error.Closed)
	testing.expect_value(t, echoed.code, 1001)
}

@(test)
close_without_payload_is_1005 :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	empty := client_frame(.Close, true, nil)
	defer delete(empty)
	net.send_tcp(p.lb.client, empty)

	msg, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Closed)
	testing.expect_value(t, msg.code, 1005)
	testing.expect_value(t, msg.reason, "")
}

@(test)
close_is_sent_only_once :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	testing.expect_value(t, ws_send_close(&p.server_ws, 1000), Conn_Error.None)
	testing.expect_value(t, ws_send_close(&p.server_ws, 1011), Conn_Error.None)

	msg, err := ws_read_message(&p.client_ws)
	testing.expect_value(t, err, Conn_Error.Closed)
	testing.expect_value(t, msg.code, 1000)
}

// ---- protocol violations ----

@(test)
server_rejects_unmasked_client_frame :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	raw_send(&p, 0x81, 0x03, 'a', 'b', 'c') // FIN|Text, unmasked

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Protocol)
	testing.expect_value(t, p.server_ws.close_code, 1002)
}

@(test)
client_rejects_masked_server_frame :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	masked := client_frame(.Text, true, transmute([]u8)string("abc"))
	defer delete(masked)
	net.send_tcp(p.lb.server, masked)

	_, err := ws_read_message(&p.client_ws)
	testing.expect_value(t, err, Conn_Error.Protocol)
	testing.expect_value(t, p.client_ws.close_code, 1002)
}

@(test)
frame_error_sets_close_code :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	raw_send(&p, 0xC1, 0x80, 0, 0, 0, 0) // RSV1 set, masked, empty payload

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Protocol)
	testing.expect_value(t, p.server_ws.close_code, 1002)
}

@(test)
oversized_message_is_rejected :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t, max_message = 1024)
	defer conn_pair_close(&p)
	if !ok do return

	big := make([]u8, 2048)
	defer delete(big)
	frame := client_frame(.Binary, true, big)
	defer delete(frame)
	net.send_tcp(p.lb.client, frame)

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Too_Large)
	testing.expect_value(t, p.server_ws.close_code, 1009)
}

// Fragments each fit, but together they don't.
@(test)
oversized_across_fragments_is_rejected :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t, max_message = 1024)
	defer conn_pair_close(&p)
	if !ok do return

	half := make([]u8, 800)
	defer delete(half)
	f1 := client_frame(.Text, false, half)
	defer delete(f1)
	f2 := client_frame(.Continuation, true, half)
	defer delete(f2)
	net.send_tcp(p.lb.client, f1)
	net.send_tcp(p.lb.client, f2)

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Too_Large)
}

@(test)
invalid_utf8_text_is_rejected :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	bad := []u8{0xC3, 0x28} // truncated two-byte sequence
	frame := client_frame(.Text, true, bad)
	defer delete(frame)
	net.send_tcp(p.lb.client, frame)

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Bad_Utf8)
	testing.expect_value(t, p.server_ws.close_code, 1007)
}

// The same bytes are fine in a binary frame.
@(test)
invalid_utf8_binary_is_allowed :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	bad := []u8{0xC3, 0x28}
	frame := client_frame(.Binary, true, bad)
	defer delete(frame)
	net.send_tcp(p.lb.client, frame)

	msg, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, msg.kind, Message_Kind.Binary)
	testing.expect(t, slice.equal(msg.payload, bad))
}

@(test)
peer_close_without_frame_is_closed :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	net.close(p.lb.client)
	p.lb.client = 0

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Closed)
}

// ---- client handshake ----

@(test)
client_upgrade_completes_against_server_upgrade :: proc(t: ^testing.T) {
	lb, ok := loopback_open(t)
	defer loopback_close(&lb)
	if !ok do return

	// The server half runs in a thread: both sides block on each other.
	Server_Side :: struct { sock: net.TCP_Socket, err: Handshake_Error }
	ss := Server_Side{lb.server, .None}
	server := thread.create_and_start_with_poly_data(&ss, proc(s: ^Server_Side) {
		req, err := read_http_request(s.sock)
		defer http_request_destroy(&req)
		if err != .None {
			s.err = err
			return
		}
		s.err = server_upgrade(s.sock, &req)
		if s.err == .None {
			// A frame right behind the response, to land in leftover.
			c: WS_Connection
			conn_init(&c, s.sock, .Server, 64 * 1024)
			defer conn_destroy(&c)
			ws_send_text(&c, "first")
		}
	})
	defer thread.destroy(server)

	buf, leftover, err := client_upgrade(lb.client, "127.0.0.1:4460")
	thread.join(server)

	testing.expect_value(t, ss.err, Handshake_Error.None)
	testing.expect_value(t, err, Handshake_Error.None)
	defer delete(buf)

	c: WS_Connection
	conn_init(&c, lb.client, .Client, 64 * 1024, leftover)
	defer conn_destroy(&c)

	msg, read_err := ws_read_message(&c)
	testing.expect_value(t, read_err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "first")
}

@(test)
client_upgrade_rejects_bad_responses :: proc(t: ^testing.T) {
	Case :: struct { response: string, want: Handshake_Error }
	cases := []Case{
		{"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", .Bad_Status},
		{"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", .Bad_Accept},
		{"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		 "Sec-WebSocket-Accept: wrong\r\n\r\n", .Bad_Accept},
		{"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: x\r\n\r\n", .Not_Upgrade},
	}

	for c in cases {
		lb, ok := loopback_open(t)
		defer loopback_close(&lb)
		if !ok do return

		Responder :: struct { sock: net.TCP_Socket, response: string }
		r := Responder{lb.server, c.response}
		server := thread.create_and_start_with_poly_data(&r, proc(r: ^Responder) {
			req, _ := read_http_request(r.sock)
			http_request_destroy(&req)
			net.send_tcp(r.sock, transmute([]u8)r.response)
		})
		defer thread.destroy(server)

		buf, _, err := client_upgrade(lb.client, "127.0.0.1:4460")
		thread.join(server)
		delete(buf)

		testing.expectf(t, err == c.want, "%q: want %v, got %v", c.response, c.want, err)
	}
}

// Nothing to read: the loop gets .Timeout so it can run its keepalive timers,
// and the connection stays usable.
@(test)
read_between_messages_times_out :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	net.set_option(p.lb.server, .Receive_Timeout, 100 * time.Millisecond)

	_, err := ws_read_message(&p.server_ws)
	testing.expect_value(t, err, Conn_Error.Timeout)

	testing.expect_value(t, ws_send_text(&p.client_ws, "after the timeout"), Conn_Error.None)
	msg, err2 := ws_read_message(&p.server_ws)
	testing.expect_value(t, err2, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "after the timeout")
}

// A timeout part-way through a fragmented message can't be reported: the
// reassembly state is local to ws_read_message. It keeps waiting instead.
@(test)
read_waits_through_a_mid_message_timeout :: proc(t: ^testing.T) {
	p, ok := conn_pair_open(t)
	defer conn_pair_close(&p)
	if !ok do return

	net.set_option(p.lb.server, .Receive_Timeout, 100 * time.Millisecond)

	f1 := client_frame(.Text, false, transmute([]u8)string("frag-"))
	defer delete(f1)
	f2 := client_frame(.Continuation, true, transmute([]u8)string("one"))
	defer delete(f2)
	net.send_tcp(p.lb.client, f1)

	Late :: struct { sock: net.TCP_Socket, data: []u8 }
	late := Late{p.lb.client, f2}
	sender := thread.create_and_start_with_poly_data(&late, proc(d: ^Late) {
		time.sleep(300 * time.Millisecond) // outlasts the receive timeout
		net.send_tcp(d.sock, d.data)
	})
	defer thread.destroy(sender)

	msg, err := ws_read_message(&p.server_ws)
	thread.join(sender)

	testing.expect_value(t, err, Conn_Error.None)
	testing.expect_value(t, string(msg.payload), "frag-one")
}

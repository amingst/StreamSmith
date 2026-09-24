package websocket

import "core:crypto"
import "core:encoding/endian"
import "core:net"
import "core:slice"
import "core:sync"
import "core:unicode/utf8"

WS_Role :: enum {
	Server,
	Client,
}

WS_Connection :: struct {
	sock:        net.TCP_Socket,
	role:        WS_Role,
	max_message: int,        // 64 KiB for the server
	send_mutex:  sync.Mutex, // guards whole frames
	recv_buf:    [dynamic]u8,

	// Bytes of recv_buf already consumed by completed messages. The buffer is
	// compacted (tail copied down to 0) once a message is returned.
	read_pos:    int,

	close_sent:  bool, // a Close frame has gone out; never send a second
	close_code:  u16,  // what to send after a failed read; set from close_code_for
	got_pong:    bool, // set by ws_read_message on a Pong; the keepalive timer clears it
}

Message_Kind :: enum {
	Text,
	Binary,
	Close,
}

Conn_Error :: enum {
	None,
	Closed,          // peer sent Close, or the socket ended cleanly
	Timeout,         // the socket's receive timeout elapsed between messages
	Network,         // recv/send failed
	Protocol,        // frame-level violation; close_code carries which
	Too_Large,       // reassembled message over max_message
	Bad_Utf8,        // text payload isn't valid UTF-8
	Bad_Continuation,// continuation with no message open, or a new data frame mid-message
}

Message :: struct {
	kind:    Message_Kind,   // Text, Binary or Close
	payload: []u8,           // borrowed from conn.recv_buf; valid until the next read
	code:    u16,            // Close only; 1005 when the peer sent no code
	reason:  string,         // Close only, borrowed
}

// leftover is whatever the HTTP handshake read past the blank line -- the
// start of the first frame. It is copied, so the caller can free its buffer.
conn_init :: proc(
	c: ^WS_Connection,
	sock: net.TCP_Socket,
	role: WS_Role,
	max_message: int,
	leftover: []u8 = nil,
	allocator := context.allocator,
) {
	c^ = {
		sock        = sock,
		role        = role,
		max_message = max_message,
		recv_buf    = make([dynamic]u8, 0, 2 * 1024, allocator),
	}
	append(&c.recv_buf, ..leftover)
}

conn_destroy :: proc(c: ^WS_Connection) {
	delete(c.recv_buf)
	c^ = {}
}

// Returns the next complete application message. Control frames never come
// out of here: a Ping is answered with a Pong, a Pong sets got_pong, and a
// Close is echoed and then reported as .Closed with msg filled in.
//
// Blocks until a whole message arrives, the socket times out between messages
// (.Timeout, so the caller can run its keepalive timers), or it fails.
// On .Protocol, .Too_Large and .Bad_Utf8, c.close_code holds the code to
// send before closing. msg.payload borrows recv_buf and stays valid until
// the next call on this connection.
ws_read_message :: proc(c: ^WS_Connection) -> (msg: Message, err: Conn_Error) {
	compact(c) // the previous message's payload dies here, not on the way out

	msg_kind:  Message_Kind
	msg_start: int
	msg_len:   int
	msg_open:  bool

	for {
		h: Frame_Header
		header_len: int
		for {
			frame_err: Frame_Error
			// recv_buf can move underneath us, so re-slice every attempt.
			h, header_len, frame_err = decode_header(c.recv_buf[c.read_pos:])
			if frame_err == .None do break
			if frame_err != .Need_More {
				c.close_code = close_code_for(frame_err)
				return {}, .Protocol
			}
			recv_more_between(c, msg_open) or_return
		}

		// Clients mask, servers don't; either side sending the wrong thing is
		// a protocol violation rather than something to work around.
		if h.masked != (c.role == .Server) {
			c.close_code = 1002
			return {}, .Protocol
		}

		// Checked before buffering, so an absurd length claim costs nothing.
		if int(h.payload_len) > c.max_message || msg_len + int(h.payload_len) > c.max_message {
			c.close_code = 1009
			return {}, .Too_Large
		}

		need := c.read_pos + header_len + int(h.payload_len)
		for len(c.recv_buf) < need {
			recv_more_between(c, msg_open) or_return
		}

		payload := c.recv_buf[c.read_pos + header_len:need]
		if h.masked do apply_mask(payload, h.mask_key)

		if is_control(h.opcode) {
			#partial switch h.opcode {
			case .Ping:
				ws_send_pong(c, payload) or_return
			case .Pong:
				c.got_pong = true
			case .Close:
				return close_message(c, payload)
			}
			c.read_pos = need
			continue // control frames can arrive between fragments
		}

		#partial switch h.opcode {
		case .Text, .Binary:
			if msg_open {
				c.close_code = 1002
				return {}, .Bad_Continuation
			}
			msg_kind  = h.opcode == .Text ? .Text : .Binary
			msg_start = c.read_pos + header_len
			msg_len   = 0
			msg_open  = true
		case .Continuation:
			if !msg_open {
				c.close_code = 1002
				return {}, .Bad_Continuation
			}
		}

		// Fragments are moved down so the finished message is one slice; the
		// first fragment is already in place.
		if dst := msg_start + msg_len; dst != c.read_pos + header_len {
			copy(c.recv_buf[dst:], payload)
		}
		msg_len += len(payload)
		c.read_pos = need

		if h.fin {
			assembled := c.recv_buf[msg_start:][:msg_len]
			if msg_kind == .Text && !utf8.valid_string(string(assembled)) {
				c.close_code = 1007
				return {}, .Bad_Utf8
			}
			return {kind = msg_kind, payload = assembled}, .None
		}
	}
}

// A Close payload is empty, or a 2-byte code with an optional UTF-8 reason.
@(private)
close_message :: proc(c: ^WS_Connection, payload: []u8) -> (msg: Message, err: Conn_Error) {
	msg.kind = .Close
	switch {
	case len(payload) == 0:
		msg.code = 1005 // "no status received"; never sent back on the wire
	case len(payload) == 1:
		c.close_code = 1002
		return {}, .Protocol
	case:
		msg.code, _ = endian.get_u16(payload[:2], .Big)
		msg.reason = string(payload[2:])
		if !utf8.valid_string(msg.reason) {
			c.close_code = 1007
			return {}, .Bad_Utf8
		}
	}

	if !c.close_sent {
		ws_send_close(c, msg.code == 1005 ? 1000 : msg.code)
	}
	return msg, .Closed
}

ws_send_text :: proc(c: ^WS_Connection, s: string) -> Conn_Error {
	return send_frame(c, .Text, transmute([]u8)s)
}

// The server rejects binary frames, but a client may need to send them and
// the tests use it to check that rejection.
ws_send_binary :: proc(c: ^WS_Connection, payload: []u8) -> Conn_Error {
	return send_frame(c, .Binary, payload)
}

ws_send_ping :: proc(c: ^WS_Connection, payload: []u8 = nil) -> Conn_Error {
	return send_frame(c, .Ping, payload)
}

ws_send_pong :: proc(c: ^WS_Connection, payload: []u8 = nil) -> Conn_Error {
	return send_frame(c, .Pong, payload)
}

// Sends a Close frame with a 2-byte big-endian code and an optional reason,
// truncated to fit a control frame. Only the first call sends anything.
ws_send_close :: proc(c: ^WS_Connection, code: u16 = 1000, reason := "") -> Conn_Error {
	if c.close_sent do return .None
	c.close_sent = true

	buf: [MAX_CONTROL_PAYLOAD]u8
	_ = endian.put_u16(buf[:2], .Big, code)
	n := 2 + copy(buf[2:], reason)
	return send_frame(c, .Close, buf[:n])
}

@(private)
send_frame :: proc(c: ^WS_Connection, opcode: Opcode, payload: []u8) -> Conn_Error {
	h := Frame_Header{
		fin         = true,
		opcode      = opcode,
		masked      = c.role == .Client,
		payload_len = u64(len(payload)),
	}

	body := payload
	if h.masked {
		crypto.rand_bytes(h.mask_key[:])
		// Masking is in place, so a client works on a copy of the caller's bytes.
		body = slice.clone(payload, context.temp_allocator)
		apply_mask(body, h.mask_key)
	}

	header: [MAX_HEADER]u8
	header_len := encode_header(h, &header)

	sync.guard(&c.send_mutex)
	send_all(c.sock, header[:header_len]) or_return
	if len(body) > 0 {
		send_all(c.sock, body) or_return
	}
	return .None
}

@(private)
send_all :: proc(sock: net.TCP_Socket, buf: []u8) -> Conn_Error {
	for sent := 0; sent < len(buf); {
		n, err := net.send_tcp(sock, buf[sent:])
		if err != nil do return .Network
		sent += n
	}
	return .None
}

@(private)
recv_more :: proc(c: ^WS_Connection) -> Conn_Error {
	chunk: [4 * 1024]u8
	n, err := net.recv_tcp(c.sock, chunk[:])
	if err == net.TCP_Recv_Error.Timeout do return .Timeout
	if err != nil do return .Network
	if n == 0 do return .Closed
	append(&c.recv_buf, ..chunk[:n])
	return .None
}

// A timeout is only reportable between messages: the reassembly state lives in
// ws_read_message's locals, so returning mid-message would lose the fragments
// read so far. Partial *frames* are fine -- they stay in recv_buf and the next
// call decodes them again from read_pos.
@(private)
recv_more_between :: proc(c: ^WS_Connection, msg_open: bool) -> Conn_Error {
	for {
		err := recv_more(c)
		if err == .Timeout && msg_open do continue
		return err
	}
}

@(private)
compact :: proc(c: ^WS_Connection) {
	if c.read_pos == 0 do return
	copy(c.recv_buf[:], c.recv_buf[c.read_pos:])
	resize(&c.recv_buf, len(c.recv_buf) - c.read_pos)
	c.read_pos = 0
}

package remote

import "base:intrinsics"
import "core:slice"
import ws "libs:websocket"
import "../action"
import "protocol"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:thread"

Client :: struct {
	id:        u32,
	conn:      ws.WS_Connection,
	topics:    protocol.Topic_Set,
	topics_mu: sync.Mutex,

	out:       [dynamic][]u8,
	out_mu:    sync.Mutex,
	out_cond:  sync.Cond,

	allocator: mem.Allocator,

	reader:    ^thread.Thread,
	writer:    ^thread.Thread,
	alive:     bool,
	last_rx:   time.Time,
	last_ping: time.Time,
	server:    ^Server,
	greeted:   bool,
	connected_at: time.Time,

	// Resolved from Server_Config at admit, so tests can shorten them.
	hello_deadline: time.Duration,
	ping_interval:  time.Duration,
	pong_timeout:   time.Duration,

	// Set by the reader as its very last act; the reaper waits for it before
	// joining the threads and freeing the client.
	reader_done: bool,
}

MAX_CLIENTS :: 8
MAX_MESSAGE :: 64 * 1024
MAX_OUT :: 256

// docs/remote-protocol.md section 10.
HELLO_DEADLINE :: 10 * time.Second
PING_INTERVAL  :: 15 * time.Second
PONG_TIMEOUT   :: 45 * time.Second
READ_TIMEOUT   :: 1 * time.Second // how often the reader wakes to run the timers
SEND_TIMEOUT   :: 2 * time.Second // a send to a peer that stopped reading fails after this

client_admit :: proc(server: ^Server, sock: net.TCP_Socket) -> bool {
	hello_deadline := server.cfg.hello_deadline if server.cfg.hello_deadline > 0 else HELLO_DEADLINE
	net.set_option(sock, .Receive_Timeout, hello_deadline)

	req, req_err := ws.read_http_request(sock)
	defer ws.http_request_destroy(&req)
	if req_err != .None {
		ws.write_http_error(sock, ws.http_status_for(req_err))
		return false
	}

	if req.path != "/" {
		ws.write_http_error(sock, ws.Http_Status{404, "Not Found", ""})
		return false
	}

	if origin, has_origin := ws.http_header(&req, "Origin"); has_origin && !origin_allowed(server, origin) {
		log.warnf("remote: rejected a connection from origin %q", origin)
		ws.write_http_error(sock, ws.Http_Status{403, "Forbidden", ""})
		return false
	}

	if client_count(server) >= MAX_CLIENTS {
		log.warnf("remote: refused a connection, %v clients already attached", MAX_CLIENTS)
		ws.write_http_error(sock, ws.Http_Status{503, "Service Unavailable", ""})
		return false
	}

	if up_err := ws.server_upgrade(sock, &req); up_err != .None {
		ws.write_http_error(sock, ws.http_status_for(up_err))
		return false
	}

	net.set_option(sock, .Receive_Timeout, READ_TIMEOUT)
	// A peer that stops reading must not pin the connection's send mutex --
	// shutdown takes that mutex to send its close frame.
	net.set_option(sock, .Send_Timeout, SEND_TIMEOUT)

	client := new(Client, server.allocator)
	client.allocator = server.allocator
	client.alive = true
	client.last_rx = time.now()
	client.last_ping = client.last_rx
	client.out = make([dynamic][]u8, 0, 16, server.allocator)
	client.server = server
	client.connected_at = client.last_rx // greeted stays false until a valid hello
	client.hello_deadline = hello_deadline
	client.ping_interval = server.cfg.ping_interval if server.cfg.ping_interval > 0 else PING_INTERVAL
	client.pong_timeout = server.cfg.pong_timeout if server.cfg.pong_timeout > 0 else PONG_TIMEOUT
	ws.conn_init(&client.conn, sock, .Server, MAX_MESSAGE, req.leftover, server.allocator)


	sync.lock(&server.clients_mu)
	server.next_id += 1
	client.id = server.next_id
	append(&server.clients, client)
	sync.unlock(&server.clients_mu)

	client.writer = thread.create_and_start_with_poly_data(client, writer_loop)
	client.reader = thread.create_and_start_with_poly_data(client, reader_loop)
	log.infof("remote: client %v attached", client.id)
	return true
}

client_kill :: proc(client: ^Client) {
	sync.lock(&client.out_mu)
	client.alive = false
	sync.unlock(&client.out_mu)
	sync.cond_broadcast(&client.out_cond)
}

client_is_alive :: proc(client: ^Client) -> bool {
	sync.guard(&client.out_mu)
	return client.alive
}

// Tells a client to go away without freeing it: the close frame goes out, the
// writer stops, and closing the socket unblocks the reader. The reader then
// hands the client to the server's reaping list (see client_unregister).
client_signal_stop :: proc(client: ^Client, code: u16) {
	ws.ws_send_close(&client.conn, code)
	client_kill(client)
	net.close(client.conn.sock)
}

// Joins the client's threads and frees it. Only the reaper calls this, and
// only once client.reader_done is set -- a reader can't join itself.
client_free :: proc(client: ^Client) {
	// The reader may have left without killing the client (e.g. on shutdown),
	// and the writer waits on out_cond until it does.
	client_kill(client)

	if client.reader != nil {
		thread.join(client.reader)
		thread.destroy(client.reader)
		client.reader = nil
	}

	if client.writer != nil {
		thread.join(client.writer)
		thread.destroy(client.writer)
		client.writer = nil
	}

	ws.conn_destroy(&client.conn)

	for payload in client.out {
		delete(payload, client.allocator)
	}
	delete(client.out)
	free(client, client.allocator)
}

client_enqueue :: proc(client: ^Client, payload: []u8) -> bool {
	sync.lock(&client.out_mu)

	if !client.alive {
		sync.unlock(&client.out_mu)
		return false
	}

	if len(client.out) >= MAX_OUT {
		client.alive = false
		sync.unlock(&client.out_mu)
		sync.cond_broadcast(&client.out_cond)
		log.warnf("remote: client %v fell %v messages behind, dropping it", client.id, MAX_OUT)
		return false
	}

	append(&client.out, slice.clone(payload, client.allocator))
	sync.unlock(&client.out_mu)
	sync.cond_signal(&client.out_cond)
	return true
}

writer_loop :: proc(client: ^Client) {
	for {
		sync.lock(&client.out_mu)
		for client.alive && len(client.out) == 0 {
			sync.cond_wait(&client.out_cond, &client.out_mu)
		}
		if !client.alive {
			sync.unlock(&client.out_mu)
			return
		}
		batch := client.out
		client.out = make([dynamic][]u8, 0, 16, client.allocator)
		sync.unlock(&client.out_mu)

		failed: ws.Conn_Error
		for payload in batch {
			if failed == .None {
				failed = ws.ws_send_text(&client.conn, string(payload))
			}
			delete(payload, client.allocator)
		}
		delete(batch)

		if failed != .None {
			log.debugf("remote: client %v send failed (%v), dropping it", client.id, failed)
			client_kill(client)
			return
		}
	}
}

// Owns the connection's read side. conn, greeted, last_rx and last_ping are
// only touched here, so they need no lock; sends go through client_enqueue so
// the writer thread keeps them in order.
reader_loop :: proc(client: ^Client) {
	// Declared first so it runs last: after it, the reaper may free the client.
	defer client_unregister(client)
	defer free_all(context.temp_allocator)

	for client_is_alive(client) && intrinsics.atomic_load(&client.server.running) {
		msg, err := ws.ws_read_message(&client.conn)

		switch err {
		case .None:
			client.last_rx = time.now()
			switch msg.kind {
			case .Text:
				if !reader_handle_text(client, msg.payload) do return
			case .Binary:
				reader_close(client, 1003) // text frames only, see docs/remote-protocol.md
				return
			case .Close:
				return // ws_read_message already echoed it
			}

		case .Timeout:
			if !reader_tick(client) do return

		case .Closed:
			return

		case .Protocol, .Too_Large, .Bad_Utf8, .Bad_Continuation:
			// close_code is set by the connection: 1002, 1009 or 1007.
			reader_close(client, client.conn.close_code)
			return

		case .Network:
			log.debugf("remote: client %v read failed, dropping it", client.id)
			client_kill(client) // socket is unusable, so no close frame
			return
		}

		free_all(context.temp_allocator) // decoding is per-message scratch
	}
}

// Runs whenever a read times out, so the timers tick even on an idle
// connection. Returns false when the client is finished.
@(private)
reader_tick :: proc(client: ^Client) -> (keep_going: bool) {
	now := time.now()

	if !client.greeted && time.diff(client.connected_at, now) > client.hello_deadline {
		log.debugf("remote: client %v sent no hello in time", client.id)
		reader_close(client, protocol.CLOSE_HANDSHAKE_REQUIRED)
		return false
	}

	// Any frame counts as proof of life; ws_read_message sets got_pong.
	if client.conn.got_pong {
		client.conn.got_pong = false
		client.last_rx = now
	}

	if time.diff(client.last_rx, now) > client.pong_timeout {
		log.infof("remote: client %v stopped answering, dropping it", client.id)
		client_kill(client) // no close frame: the peer isn't listening
		return false
	}

	if time.diff(client.last_ping, now) >= client.ping_interval {
		if ws.ws_send_ping(&client.conn) != .None {
			client_kill(client)
			return false
		}
		client.last_ping = now
	}

	return true
}

// Takes the client out of the server's list -- freeing its slot against
// MAX_CLIENTS and stopping any further respond/broadcast -- and hands it to
// the reaping list. reader_done goes last: it's what lets the reaper free it.
@(private)
client_unregister :: proc(client: ^Client) {
	client_kill(client) // the writer has nothing left to send for a gone reader
	server := client.server

	sync.lock(&server.clients_mu)
	for c, i in server.clients {
		if c == client {
			ordered_remove(&server.clients, i)
			break
		}
	}
	append(&server.reaping, client)
	sync.unlock(&server.clients_mu)

	log.debugf("remote: client %v detached", client.id)
	intrinsics.atomic_store(&client.reader_done, true)
}

// Closes the connection with a code and stops the writer.
@(private)
reader_close :: proc(client: ^Client, code: u16) {
	ws.ws_send_close(&client.conn, code)
	client_kill(client)
}

// Handles one text message. Returns false when the connection is finished.
// Everything it sends goes through client_enqueue so the writer thread keeps
// replies in order; the one exception is noted below.
@(private)
reader_handle_text :: proc(client: ^Client, payload: []u8) -> (keep_going: bool) {
	inbound, fault := protocol.decode_inbound(payload, context.temp_allocator)

	if f, bad := fault.?; bad {
		// Nothing but a valid hello may come first.
		if !client.greeted {
			log.debugf("remote: client %v sent %v before a hello", client.id, f.code)
			reader_close(client, protocol.CLOSE_HANDSHAKE_REQUIRED)
			return false
		}
		// A fault with a request id becomes a response, otherwise an error message.
		client_enqueue(client, protocol.encode_fault(f, context.temp_allocator))
		return true
	}

	switch m in inbound {
	case protocol.Hello:   return reader_handle_hello(client, m)
	case protocol.Request: return reader_handle_request(client, m)
	}
	return true
}

@(private)
reader_handle_hello :: proc(client: ^Client, hello: protocol.Hello) -> (keep_going: bool) {
	if client.greeted {
		client_enqueue(client, protocol.encode_error(
			.Bad_Request, "already greeted", nil, context.temp_allocator))
		return true
	}

	if hello.protocol != protocol.PROTOCOL_VERSION {
		// Sent straight down the socket: the close frame follows immediately,
		// so there's no time for the writer thread to pick it up.
		bytes := protocol.encode_error(
			.Unsupported_Protocol,
			fmt.tprintf("protocol %v is not supported", hello.protocol),
			{protocol.PROTOCOL_VERSION},
			context.temp_allocator)
		ws.ws_send_text(&client.conn, string(bytes))
		reader_close(client, protocol.CLOSE_UNSUPPORTED_VERSION)
		return false
	}

	client.greeted = true
	log.infof("remote: client %v is %q (protocol %v)", client.id, hello.client, hello.protocol)
	client_enqueue(client, protocol.encode_welcome(client.server.cfg.server_name, context.temp_allocator))
	return true
}

@(private)
reader_handle_request :: proc(client: ^Client, req: protocol.Request) -> (keep_going: bool) {
	if !client.greeted {
		log.debugf("remote: client %v sent a request before a hello", client.id)
		reader_close(client, protocol.CLOSE_HANDSHAKE_REQUIRED)
		return false
	}

	// These two are answered here rather than queued: they don't touch show
	// state, so they don't have to wait for the main loop.
	#partial switch req.method {
	case .State_Get:
		snapshot, has_snapshot := server_snapshot_copy(client.server, context.temp_allocator)
		if !has_snapshot {
			client_enqueue(client, protocol.encode_response_err(
				req.id, .Failed, "no state snapshot has been published yet", context.temp_allocator))
			return true
		}
		client_enqueue(client, protocol.encode_response_raw(req.id, snapshot, context.temp_allocator))
		return true

	case .Events_Subscribe:
		topics := req.params.(protocol.Params_Subscribe).topics
		sync.lock(&client.topics_mu)
		client.topics = topics
		sync.unlock(&client.topics_mu)
		client_enqueue(client, protocol.encode_response_ok(req.id, nil, context.temp_allocator))
		return true
	}

	// Everything else runs on the main loop. The response is sent by the
	// bridge after dispatch, using the reply handle below; queue_push copies
	// the ids out of the temp-allocated JSON.
	action.queue_push(client.server.queue, action.Envelope{
		action = request_to_action(req.method, req.params),
		origin = .Remote,
		reply  = action.Envelope_Reply_Remote{client_id = client.id, request_id = req.id},
	})
	return true
}

@(private)
origin_allowed :: proc(server: ^Server, origin: string) -> bool {
	for allowed in server.cfg.allowed_origins {
		if allowed == origin do return true
	}
	return false
}

@(private)
client_count :: proc(server: ^Server) -> int {
	sync.guard(&server.clients_mu)
	return len(server.clients)
}

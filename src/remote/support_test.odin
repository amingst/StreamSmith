#+private
package remote

// Shared by the test files; only *_test.odin files are built by `odin test`.

import ws "libs:websocket"
import "base:runtime"
import "core:net"
import "core:sync"
import "core:testing"
import "core:time"

import "../action"

Harness :: struct {
	queue:  action.Envelope_Queue,
	server: Server,
	batch:  [dynamic]action.Envelope,
	port:   u16,
}

harness_open :: proc(t: ^testing.T, h: ^Harness, port: u16, cfg := Server_Config{}) -> bool {
	cfg := cfg
	cfg.port = port
	cfg.server_name = "test"
	h.port = port
	action.queue_init(&h.queue)
	h.server = server_init(cfg, &h.queue, runtime.default_allocator())
	return testing.expectf(t, server_start(&h.server), "server_start failed on port %v", port)
}

// Polls until the server has dropped down to count clients, or gives up.
await_client_loss :: proc(h: ^Harness, count: int, timeout := 3 * time.Second) {
	deadline := time.time_add(time.now(), timeout)
	for time.diff(time.now(), deadline) > 0 {
		if client_count(&h.server) <= count do return
		time.sleep(5 * time.Millisecond)
	}
}

harness_close :: proc(h: ^Harness) {
	server_stop(&h.server)
	action.queue_destroy(&h.queue, &h.batch)
}

Peer :: struct {
	sock: net.TCP_Socket,
	conn: ws.WS_Connection,
	buf:  [dynamic]u8,
}

peer_connect :: proc(t: ^testing.T, h: ^Harness, peer: ^Peer) -> bool {
	ep := net.Endpoint{address = net.IP4_Loopback, port = int(h.port)}

	dial_err: net.Network_Error
	peer.sock, dial_err = net.dial_tcp(ep)
	if !testing.expect_value(t, dial_err, nil) do return false
	net.set_option(peer.sock, .Receive_Timeout, 2 * time.Second)

	leftover: []u8
	hs_err: ws.Handshake_Error
	peer.buf, leftover, hs_err = ws.client_upgrade(peer.sock, "127.0.0.1")
	if !testing.expect_value(t, hs_err, ws.Handshake_Error.None) do return false

	ws.conn_init(&peer.conn, peer.sock, .Client, MAX_MESSAGE, leftover)
	return true
}

peer_close :: proc(peer: ^Peer) {
	ws.conn_destroy(&peer.conn)
	delete(peer.buf)
	if peer.sock != 0 do net.close(peer.sock)
}

peer_expect_text :: proc(t: ^testing.T, peer: ^Peer, want: string) {
	msg, err := ws.ws_read_message(&peer.conn)
	if !testing.expectf(t, err == .None, "read: %v", err) do return
	testing.expect_value(t, string(msg.payload), want)
}

await_clients :: proc(h: ^Harness, count: int) {
	for _ in 0 ..< 200 {
		if client_count(&h.server) == count do return
		time.sleep(5 * time.Millisecond)
	}
}

first_client :: proc(h: ^Harness) -> ^Client {
	sync.guard(&h.server.clients_mu)
	if len(h.server.clients) == 0 do return nil
	return h.server.clients[0]
}

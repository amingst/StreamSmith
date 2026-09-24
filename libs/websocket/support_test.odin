#+private
package websocket

// Shared by the test files; only *_test.odin files are built by `odin test`.

import "core:net"
import "core:testing"
import "core:time"

Loopback :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	server:   net.TCP_Socket,
}

loopback_open :: proc(t: ^testing.T) -> (lb: Loopback, ok: bool) {
	listen_err: net.Network_Error
	lb.listener, listen_err = net.listen_tcp({net.IP4_Loopback, 0})
	if !testing.expect_value(t, listen_err, nil) do return

	ep, ep_err := net.bound_endpoint(lb.listener)
	if !testing.expect_value(t, ep_err, nil) do return

	dial_err: net.Network_Error
	lb.client, dial_err = net.dial_tcp(ep)
	if !testing.expect_value(t, dial_err, nil) do return

	accept_err: net.Accept_Error
	lb.server, _, accept_err = net.accept_tcp(lb.listener)
	if !testing.expect_value(t, accept_err, nil) do return

	// Fail instead of hanging if a read never completes.
	net.set_option(lb.server, .Receive_Timeout, 2 * time.Second)
	net.set_option(lb.client, .Receive_Timeout, 2 * time.Second)
	return lb, true
}

loopback_close :: proc(lb: ^Loopback) {
	if lb.client != 0 do net.close(lb.client)
	if lb.server != 0 do net.close(lb.server)
	if lb.listener != 0 do net.close(lb.listener)
}

// A connected pair of WS_Connections over loopback, skipping the HTTP
// handshake: the server end reads masked frames, the client end unmasked.
Conn_Pair :: struct {
	using lb:   Loopback,
	server_ws:  WS_Connection,
	client_ws:  WS_Connection,
}

conn_pair_open :: proc(t: ^testing.T, max_message := 64 * 1024) -> (p: Conn_Pair, ok: bool) {
	p.lb = loopback_open(t) or_return
	conn_init(&p.server_ws, p.lb.server, .Server, max_message)
	conn_init(&p.client_ws, p.lb.client, .Client, max_message)
	return p, true
}

conn_pair_close :: proc(p: ^Conn_Pair) {
	conn_destroy(&p.server_ws)
	conn_destroy(&p.client_ws)
	loopback_close(&p.lb)
}

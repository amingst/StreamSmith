package websocket

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(private="file")
UPGRADE_REQUEST :: "GET / HTTP/1.1\r\n" +
	"Host: 127.0.0.1:4460\r\n" +
	"upgrade: websocket\r\n" +
	"Connection: keep-alive, Upgrade\r\n" +
	"Sec-WebSocket-Key:   dGhlIHNhbXBsZSBub25jZQ==  \r\n" +
	"Sec-WebSocket-Version: 13\r\n" +
	"\r\n"

// Builds a request from raw text without a socket.
@(private="file")
parse_raw :: proc(raw: string) -> (req: Http_Request, err: Handshake_Error) {
	append(&req.buf, raw)
	end := strings.index(raw, "\r\n\r\n")
	if end < 0 do return req, .Malformed
	return req, parse_http_request(&req, end)
}

@(test)
accept_key_matches_rfc6455 :: proc(t: ^testing.T) {
	key := accept_key("dGhlIHNhbXBsZSBub25jZQ==")
	defer delete(key)
	testing.expect_value(t, key, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@(test)
parse_reads_request_line_and_headers :: proc(t: ^testing.T) {
	req, err := parse_raw(UPGRADE_REQUEST + "\x81\x05")
	defer http_request_destroy(&req)

	testing.expect_value(t, err, Handshake_Error.None)
	testing.expect_value(t, req.method, "GET")
	testing.expect_value(t, req.path, "/")

	upgrade, ok := http_header(&req, "Upgrade")
	testing.expect(t, ok)
	testing.expect_value(t, upgrade, "websocket")

	key, _ := http_header(&req, "sec-websocket-key")
	testing.expect_value(t, key, "dGhlIHNhbXBsZSBub25jZQ==")

	_, missing := http_header(&req, "Origin")
	testing.expect(t, !missing)

	testing.expect_value(t, len(req.leftover), 2)
}

@(test)
parse_rejects_malformed :: proc(t: ^testing.T) {
	cases := []string{
		"GET / HTTP/1.1\r\nno colon here\r\n\r\n",
		"GET / SPDY/3\r\nHost: x\r\n\r\n",
		"GET\r\nHost: x\r\n\r\n",
		"GET / HTTP/1.1\r\n: empty name\r\n\r\n",
	}
	for raw in cases {
		req, err := parse_raw(raw)
		testing.expectf(t, err == .Malformed, "%q: got %v", raw, err)
		http_request_destroy(&req)
	}
}

@(test)
check_upgrade_accepts_valid_request :: proc(t: ^testing.T) {
	req, _ := parse_raw(UPGRADE_REQUEST)
	defer http_request_destroy(&req)
	testing.expect_value(t, check_upgrade(&req), Handshake_Error.None)
}

@(test)
check_upgrade_rejects :: proc(t: ^testing.T) {
	Case :: struct { raw: string, want: Handshake_Error }
	base :: "Host: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
	key :: "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
	cases := []Case{
		{"POST / HTTP/1.1\r\n" + base + key + "Sec-WebSocket-Version: 13\r\n\r\n", .Not_Get},
		{"GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\n" + key + "Sec-WebSocket-Version: 13\r\n\r\n", .Not_Upgrade},
		{"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: keep-alive\r\n" + key + "Sec-WebSocket-Version: 13\r\n\r\n", .Not_Upgrade},
		{"GET / HTTP/1.1\r\n" + base + key + "Sec-WebSocket-Version: 8\r\n\r\n", .Bad_Version},
		{"GET / HTTP/1.1\r\n" + base + key + "\r\n", .Bad_Version},
		{"GET / HTTP/1.1\r\n" + base + "Sec-WebSocket-Version: 13\r\n\r\n", .Bad_Key},
		{"GET / HTTP/1.1\r\n" + base + "Sec-WebSocket-Key: abc\r\nSec-WebSocket-Version: 13\r\n\r\n", .Bad_Key},
		{"GET / HTTP/1.1\r\n" + base + "Sec-WebSocket-Key: !!!!\r\nSec-WebSocket-Version: 13\r\n\r\n", .Bad_Key},
		// Right length for 16 bytes, but not base64.
		{"GET / HTTP/1.1\r\n" + base + "Sec-WebSocket-Key: !!!!!!!!!!!!!!!!!!!!!!==\r\nSec-WebSocket-Version: 13\r\n\r\n", .Bad_Key},
		// Valid base64, but 20 bytes.
		{"GET / HTTP/1.1\r\n" + base + "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\nSec-WebSocket-Version: 13\r\n\r\n", .Bad_Key},
	}
	for c in cases {
		req, parse_err := parse_raw(c.raw)
		testing.expect_value(t, parse_err, Handshake_Error.None)
		got := check_upgrade(&req)
		testing.expectf(t, got == c.want, "%q: want %v, got %v", c.raw, c.want, got)
		http_request_destroy(&req)
	}
}

@(test)
http_status_for_errors :: proc(t: ^testing.T) {
	testing.expect_value(t, http_status_for(.Bad_Version).code, 426)
	testing.expect(t, strings.contains(http_status_for(.Bad_Version).extra_headers, "Sec-WebSocket-Version: 13"))
	testing.expect_value(t, http_status_for(.Too_Large).code, 431)
	testing.expect_value(t, http_status_for(.Bad_Key).code, 400)
}

// ---- Socket tests ----
// Loopback helpers live in support_test.odin.

@(private="file")
Delayed_Send :: struct {
	sock: net.TCP_Socket,
	data: string,
}

@(test)
read_http_request_joins_split_writes :: proc(t: ^testing.T) {
	lb, ok := loopback_open(t)
	defer loopback_close(&lb)
	if !ok do return

	// Split inside the final "\r\n\r\n", with the second half sent after the
	// server has started waiting.
	raw := string(UPGRADE_REQUEST + "\x81")
	split := len(UPGRADE_REQUEST) - 3
	net.send_tcp(lb.client, transmute([]u8)raw[:split])
	rest := Delayed_Send{lb.client, raw[split:]}
	sender := thread.create_and_start_with_poly_data(&rest, proc(d: ^Delayed_Send) {
		time.sleep(50 * time.Millisecond)
		net.send_tcp(d.sock, transmute([]u8)d.data)
	})
	defer thread.destroy(sender)

	req, err := read_http_request(lb.server)
	defer http_request_destroy(&req)
	thread.join(sender)

	testing.expect_value(t, err, Handshake_Error.None)
	testing.expect_value(t, req.path, "/")
	testing.expect_value(t, check_upgrade(&req), Handshake_Error.None)
	testing.expect_value(t, len(req.leftover), 1)
}

@(test)
read_http_request_too_large :: proc(t: ^testing.T) {
	lb, ok := loopback_open(t)
	defer loopback_close(&lb)
	if !ok do return

	junk := make([]u8, 9 * 1024)
	defer delete(junk)
	for &b in junk do b = 'a'
	net.send_tcp(lb.client, junk)

	req, err := read_http_request(lb.server)
	defer http_request_destroy(&req)
	testing.expect_value(t, err, Handshake_Error.Too_Large)
}

@(test)
read_http_request_closed :: proc(t: ^testing.T) {
	lb, ok := loopback_open(t)
	defer loopback_close(&lb)
	if !ok do return

	net.send_tcp(lb.client, transmute([]u8)string("GET / HTTP/1.1\r\n"))
	net.close(lb.client)
	lb.client = 0

	req, err := read_http_request(lb.server)
	defer http_request_destroy(&req)
	testing.expect_value(t, err, Handshake_Error.Closed)
}

@(test)
server_upgrade_writes_101 :: proc(t: ^testing.T) {
	lb, ok := loopback_open(t)
	defer loopback_close(&lb)
	if !ok do return

	req, _ := parse_raw(UPGRADE_REQUEST)
	defer http_request_destroy(&req)
	testing.expect_value(t, server_upgrade(lb.server, &req), Handshake_Error.None)

	net.set_option(lb.client, .Receive_Timeout, 2 * time.Second)
	buf: [512]u8
	n, _ := net.recv_tcp(lb.client, buf[:])
	response := string(buf[:n])
	testing.expect(t, strings.has_prefix(response, "HTTP/1.1 101 Switching Protocols\r\n"))
	testing.expect(t, strings.contains(response, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
	testing.expect(t, strings.has_suffix(response, "\r\n\r\n"))
}

@(test)
write_http_error_426 :: proc(t: ^testing.T) {
	lb, ok := loopback_open(t)
	defer loopback_close(&lb)
	if !ok do return

	testing.expect_value(t, write_http_error(lb.server, http_status_for(.Bad_Version)), Handshake_Error.None)

	net.set_option(lb.client, .Receive_Timeout, 2 * time.Second)
	buf: [512]u8
	n, _ := net.recv_tcp(lb.client, buf[:])
	response := string(buf[:n])
	testing.expect(t, strings.has_prefix(response, "HTTP/1.1 426 Upgrade Required\r\n"))
	testing.expect(t, strings.contains(response, "Sec-WebSocket-Version: 13\r\n"))
	testing.expect(t, strings.has_suffix(response, "\r\n\r\n"))
}

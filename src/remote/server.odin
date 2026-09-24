package remote

import "core:mem"
import "core:net"
import "core:slice"
import "core:sync"
import "core:time"
import "core:thread"
import "base:intrinsics"
import "core:log"

import "../action"
import "protocol"

Server_Config :: struct {
	port:            u16,
	allowed_origins: []string,
	server_name:     string,

	// Keepalive, see docs/remote-protocol.md section 10. Zero means the
	// default; the tests shorten them.
	hello_deadline: time.Duration,
	ping_interval:  time.Duration,
	pong_timeout:   time.Duration,
}

Server :: struct {
	cfg:      Server_Config,
	listener: net.TCP_Socket,
	listener_thread: ^thread.Thread,
	ticker_thread:   ^thread.Thread,
	queue:    ^action.Envelope_Queue,
	clients:   [dynamic]^Client,
	// Clients whose reader has left the loop, waiting to be joined and freed.
	// A reader can't join itself, so it hands its client over here instead.
	reaping:   [dynamic]^Client,
	clients_mu: sync.Mutex,
	next_id:   u32,
	snapshot:    []u8,
	snapshot_mu: sync.Mutex,

	allocator: mem.Allocator,
	running: bool,
}

server_init :: proc(cfg: Server_Config, queue: ^action.Envelope_Queue, allocator := context.allocator) -> Server {
	return Server{cfg = cfg, queue = queue, allocator = allocator}
}

server_start :: proc(server: ^Server) -> bool {
	ep := net.Endpoint{
		address = net.IP4_Loopback,
		port    = int(server.cfg.port),
	}

	sock, sock_err := net.listen_tcp(ep)
	if sock_err != nil {
		return false
	}
	server.listener = sock
	server.clients = make([dynamic]^Client, 0, MAX_CLIENTS, server.allocator)
	server.reaping = make([dynamic]^Client, 0, MAX_CLIENTS, server.allocator)

	intrinsics.atomic_store(&server.running, true)
	server.listener_thread = thread.create_and_start_with_poly_data(server, listen_loop)
	if server.listener_thread == nil {
		log.warnf("listen_loop: server not running %v", server.running)
		return false
	}
	return true
}

server_stop :: proc(server: ^Server) {
	if !intrinsics.atomic_exchange(&server.running, false) do return

	net.close(server.listener)

	if server.listener_thread != nil {
		thread.join(server.listener_thread)
		thread.destroy(server.listener_thread)
		server.listener_thread = nil
	}

	if server.ticker_thread != nil {
		thread.join(server.ticker_thread)
		thread.destroy(server.ticker_thread)
		server.ticker_thread = nil
	}

	// Readers own their clients: signal every one, then let each reader finish
	// and hand its client to the reaping list, which is what actually frees it.
	// The list is copied first -- signalling waits on the connection's send
	// mutex, which a writer stuck on a full socket holds until SEND_TIMEOUT,
	// and holding clients_mu across that would block the readers' unregister.
	leaving: [dynamic]^Client
	{
		sync.guard(&server.clients_mu)
		leaving = slice.clone_to_dynamic(server.clients[:], server.allocator)
	}
	for client in leaving {
		client_signal_stop(client, protocol.CLOSE_GOING_AWAY)
	}
	delete(leaving)

	for _ in 0 ..< 2000 { // 10s ceiling; readers wake at their receive timeout
		server_reap(server)
		sync.lock(&server.clients_mu)
		done := len(server.clients) == 0 && len(server.reaping) == 0
		sync.unlock(&server.clients_mu)
		if done do break
		time.sleep(5 * time.Millisecond)
	}

	sync.lock(&server.clients_mu)
	stragglers := len(server.clients) + len(server.reaping)
	delete(server.clients)
	delete(server.reaping)
	server.clients = nil
	server.reaping = nil
	sync.unlock(&server.clients_mu)
	if stragglers > 0 do log.errorf("remote: %v client(s) did not shut down", stragglers)

	sync.guard(&server.snapshot_mu)
	delete(server.snapshot, server.allocator)
	server.snapshot = nil
}

// Called from the main loop after each frame's diff; the bytes are copied.
server_publish_snapshot :: proc(server: ^Server, snapshot_json: []u8) {
	fresh := slice.clone(snapshot_json, server.allocator)
	sync.guard(&server.snapshot_mu)
	delete(server.snapshot, server.allocator)
	server.snapshot = fresh
}

// The latest published snapshot, or ok = false before the first publish.
server_snapshot_copy :: proc(server: ^Server, allocator := context.allocator) -> (snapshot_json: []u8, ok: bool) {
	sync.guard(&server.snapshot_mu)
	if server.snapshot == nil do return nil, false
	return slice.clone(server.snapshot, allocator), true
}

// Joins and frees clients whose reader has finished. Runs on the listener
// thread between accepts, and repeatedly from server_stop.
server_reap :: proc(server: ^Server) {
	ready: [MAX_CLIENTS]^Client
	count: int

	sync.lock(&server.clients_mu)
	for i := len(server.reaping) - 1; i >= 0 && count < len(ready); i -= 1 {
		client := server.reaping[i]
		if !intrinsics.atomic_load(&client.reader_done) do continue
		ordered_remove(&server.reaping, i)
		ready[count] = client
		count += 1
	}
	sync.unlock(&server.clients_mu)

	for client in ready[:count] {
		client_free(client)
	}
}

server_respond :: proc(server: ^Server, client_id: u32, payload: []u8) {
	sync.lock(&server.clients_mu)
	for client in server.clients {
		if client.id == client_id {
			client_enqueue(client, payload)
			break
		}
	}
	sync.unlock(&server.clients_mu)
}

server_broadcast :: proc(server: ^Server, topic: protocol.Topic, payload: []u8) {
	sync.lock(&server.clients_mu)
	for client in server.clients {
		subscribed := false
		sync.lock(&client.topics_mu)
		subscribed = topic in client.topics
		sync.unlock(&client.topics_mu)
		if subscribed {
			client_enqueue(client, payload)
		}
	}
	sync.unlock(&server.clients_mu)
}

listen_loop :: proc(server: ^Server) {
	if server == nil {
		log.warnf("listen_loop: server is nil")
		return
	}

	for intrinsics.atomic_load(&server.running) {
		server_reap(server) // clients that dropped since the last connection

		sock, _, err := net.accept_tcp(server.listener)
		if err != nil {
			if !intrinsics.atomic_load(&server.running) do break
			continue
		}
		if !client_admit(server, sock) do net.close(sock)
	}
}

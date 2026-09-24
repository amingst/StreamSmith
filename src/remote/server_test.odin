package remote

import "core:sync"
import "core:testing"

import "protocol"

@(test)
start_and_stop_with_a_client :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47311) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return

	await_clients(&h, 1)
	testing.expect_value(t, client_count(&h.server), 1)

	server_stop(&h.server)
	testing.expect_value(t, client_count(&h.server), 0)
}

@(test)
stop_without_clients_is_idempotent :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47312) do return
	defer harness_close(&h)

	server_stop(&h.server)
	server_stop(&h.server)
}

@(test)
queued_messages_arrive_in_order :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47313) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	await_clients(&h, 1)

	client := first_client(&h)
	if !testing.expect(t, client != nil, "no client registered") do return

	testing.expect(t, client_enqueue(client, transmute([]u8)string("one")), "enqueue one")
	testing.expect(t, client_enqueue(client, transmute([]u8)string("two")), "enqueue two")
	testing.expect(t, client_enqueue(client, transmute([]u8)string("three")), "enqueue three")

	peer_expect_text(t, &peer, "one")
	peer_expect_text(t, &peer, "two")
	peer_expect_text(t, &peer, "three")
}

@(test)
respond_reaches_only_its_client :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47314) do return
	defer harness_close(&h)

	first, second: Peer
	defer peer_close(&first)
	defer peer_close(&second)
	if !peer_connect(t, &h, &first) do return
	await_clients(&h, 1)
	if !peer_connect(t, &h, &second) do return
	await_clients(&h, 2)

	sync.lock(&h.server.clients_mu)
	first_id := h.server.clients[0].id
	second_id := h.server.clients[1].id
	sync.unlock(&h.server.clients_mu)

	server_respond(&h.server, first_id, transmute([]u8)string("for-first"))
	server_respond(&h.server, second_id, transmute([]u8)string("for-second"))

	peer_expect_text(t, &first, "for-first")
	peer_expect_text(t, &second, "for-second")
}

@(test)
respond_to_a_missing_client_is_a_no_op :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47315) do return
	defer harness_close(&h)

	server_respond(&h.server, 9999, transmute([]u8)string("nobody is listening"))
}

@(test)
broadcast_only_reaches_subscribers :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47316) do return
	defer harness_close(&h)

	subscriber, bystander: Peer
	defer peer_close(&subscriber)
	defer peer_close(&bystander)
	if !peer_connect(t, &h, &subscriber) do return
	await_clients(&h, 1)
	if !peer_connect(t, &h, &bystander) do return
	await_clients(&h, 2)

	sync.lock(&h.server.clients_mu)
	sub := h.server.clients[0]
	other := h.server.clients[1]
	sync.unlock(&h.server.clients_mu)

	sync.lock(&sub.topics_mu)
	sub.topics = {.Scene, .Audio}
	sync.unlock(&sub.topics_mu)

	sync.lock(&other.topics_mu)
	other.topics = {.Outputs}
	sync.unlock(&other.topics_mu)

	server_broadcast(&h.server, protocol.Topic.Scene, transmute([]u8)string("scene-event"))
	server_broadcast(&h.server, protocol.Topic.Outputs, transmute([]u8)string("outputs-event"))

	peer_expect_text(t, &subscriber, "scene-event")
	peer_expect_text(t, &bystander, "outputs-event")
}

@(test)
a_client_that_never_reads_is_dropped :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47317) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	await_clients(&h, 1)

	client := first_client(&h)
	if !testing.expect(t, client != nil, "no client registered") do return

	big := make([]u8, 32 * 1024)
	defer delete(big)
	for &b in big do b = 'x'

	dropped := false
	for _ in 0 ..< MAX_OUT * 4 {
		if !client_enqueue(client, big) {
			dropped = true
			break
		}
	}

	testing.expect(t, dropped, "a client that never reads should be dropped, not queued forever")
	testing.expect(t, !client_is_alive(client), "an overflowed client is no longer alive")
}

@(test)
enqueue_after_kill_is_refused :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47318) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	await_clients(&h, 1)

	client := first_client(&h)
	if !testing.expect(t, client != nil, "no client registered") do return

	client_kill(client)
	testing.expect(t, !client_is_alive(client), "client_kill marks the client dead")
	testing.expect(t, !client_enqueue(client, transmute([]u8)string("too late")), "enqueue must refuse")
}

@(test)
stop_frees_queued_messages :: proc(t: ^testing.T) {
	h: Harness
	if !harness_open(t, &h, 47319) do return
	defer harness_close(&h)

	peer: Peer
	defer peer_close(&peer)
	if !peer_connect(t, &h, &peer) do return
	await_clients(&h, 1)

	client := first_client(&h)
	if !testing.expect(t, client != nil, "no client registered") do return

	sync.lock(&client.out_mu)
	for _ in 0 ..< 16 {
		append(&client.out, make([]u8, 128, client.allocator))
	}
	sync.unlock(&client.out_mu)

	server_stop(&h.server)
	testing.expect_value(t, client_count(&h.server), 0)
}

package action

import "core:sync"
import "core:mem"

Envelope_Origin :: enum {
	UI,
	Hotkey,
	Remote,
}

// Where a remote request's result is routed back to. Integers only, so push
// has nothing extra to clone and the reply outlives the network read buffer.
Envelope_Reply_Remote :: struct {
	client_id: u32,
	request_id: i64,
}

Envelope :: struct {
	action: Action,
	origin: Envelope_Origin,
	reply: Maybe(Envelope_Reply_Remote), // nil for UI and hotkeys
}

Envelope_Queue :: struct {
	mutex: sync.Mutex,
	pending: [dynamic]Envelope,
	allocator: mem.Allocator, // must be thread-safe: strings are cloned and freed on different threads
}

queue_init :: proc(q: ^Envelope_Queue, allocator := context.allocator) {
	q.allocator = allocator
	q.pending = make([dynamic]Envelope, 0, 16, allocator)
}

// Safe from any thread. Copies the action's strings into the queue's allocator.
queue_push :: proc(q: ^Envelope_Queue, env: Envelope) {
	env := env
	clone_action_strings(&env.action, q.allocator)
	sync.guard(&q.mutex)
	append(&q.pending, env)
}

// Main thread. Swaps the pending actions into out; out must be empty
// (queue_release the previous batch first) and use the queue's allocator.
queue_drain :: proc(q: ^Envelope_Queue, out: ^[dynamic]Envelope) {
	assert(len(out) == 0, "release the previous batch before draining again")
	sync.guard(&q.mutex)
	q.pending, out^ = out^, q.pending
}

// Frees the strings of a drained batch and empties it, keeping its capacity.
queue_release :: proc(q: ^Envelope_Queue, batch: ^[dynamic]Envelope) {
	for &env in batch {
		free_action_strings(&env.action, q.allocator)
	}
	clear(batch)
}

// Stop every producer thread before calling this.
queue_destroy :: proc(q: ^Envelope_Queue, batch: ^[dynamic]Envelope) {
	queue_release(q, batch)
	delete(batch^)
	sync.guard(&q.mutex)
	queue_release(q, &q.pending) // actions pushed after the last drain
	delete(q.pending)
}

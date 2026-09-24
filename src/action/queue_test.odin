// src/action/queue_test.odin
package action

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(private="file")
set_scene :: proc(id: string) -> Envelope {
	return Envelope{action = Action_Set_Scene{scene_id = id}, origin = .UI}
}

@(test)
push_drain_keeps_order_and_owns_strings :: proc(t: ^testing.T) {
	q: Envelope_Queue
	queue_init(&q)
	batch := make([dynamic]Envelope, 0, 16, q.allocator)
	defer queue_destroy(&q, &batch)

	// The source buffer is overwritten after push; the queued copy must not change.
	buf := [3]u8{'a', '0', 0}
	for i in 0 ..< 3 {
		buf[1] = u8('0' + i)
		queue_push(&q, set_scene(string(buf[:2])))
	}
	buf[0] = 'z'

	queue_drain(&q, &batch)
	testing.expect_value(t, len(batch), 3)
	testing.expect_value(t, len(q.pending), 0)
	for env, i in batch {
		id := env.action.(Action_Set_Scene).scene_id
		testing.expect_value(t, id, fmt.tprintf("a%d", i))
	}
	queue_release(&q, &batch)

	queue_drain(&q, &batch)
	testing.expect_value(t, len(batch), 0)
}

@(test)
push_after_drain_lands_in_next_batch :: proc(t: ^testing.T) {
	q: Envelope_Queue
	queue_init(&q)
	batch := make([dynamic]Envelope, 0, 16, q.allocator)
	defer queue_destroy(&q, &batch)

	queue_push(&q, set_scene("first"))
	queue_drain(&q, &batch)
	queue_push(&q, set_scene("second"))
	testing.expect_value(t, len(batch), 1)
	queue_release(&q, &batch)

	queue_drain(&q, &batch)
	testing.expect_value(t, len(batch), 1)
	testing.expect_value(t, batch[0].action.(Action_Set_Scene).scene_id, "second")
	queue_release(&q, &batch)
}

@(test)
destroy_frees_undrained_actions :: proc(t: ^testing.T) {
	q: Envelope_Queue
	queue_init(&q)
	batch := make([dynamic]Envelope, 0, 16, q.allocator)

	queue_push(&q, Envelope{action = Action_Toggle_Source_Visible{scene_id = "s", source_id = "src"}, origin = .Hotkey})
	queue_push(&q, Envelope{action = Action_Set_Volume{source_id = "mic", volume = 0.5}, origin = .Remote,
		reply = Envelope_Reply_Remote{client_id = 1, request_id = 7}})
	queue_drain(&q, &batch)
	queue_push(&q, Envelope{action = Action_Set_Mute{source_id = "mic", muted = true}, origin = .UI})

	// Leaves one batch and one pending action outstanding; the test runner's
	// tracking allocator fails the test if destroy misses either.
	queue_destroy(&q, &batch)
}

PRODUCERS :: 8
PUSHES_PER_PRODUCER :: 2000

@(private="file")
Producer :: struct {
	q: ^Envelope_Queue,
	index: int,
	remaining: ^i32, // producers still pushing
}

@(private="file")
produce :: proc(p: ^Producer) {
	defer sync.atomic_sub(p.remaining, 1)
	buf: [32]u8
	for i in 0 ..< PUSHES_PER_PRODUCER {
		id := fmt.bprintf(buf[:], "%d-%d", p.index, i)
		queue_push(p.q, set_scene(id))
	}
}

@(test)
concurrent_push_loses_nothing :: proc(t: ^testing.T) {
	q: Envelope_Queue
	queue_init(&q)
	batch := make([dynamic]Envelope, 0, 16, q.allocator)
	defer queue_destroy(&q, &batch)

	remaining := i32(PRODUCERS)
	producers: [PRODUCERS]Producer
	threads: [PRODUCERS]^thread.Thread
	for i in 0 ..< PRODUCERS {
		producers[i] = Producer{q = &q, index = i, remaining = &remaining}
		threads[i] = thread.create_and_start_with_poly_data(&producers[i], produce, context)
	}

	next := [PRODUCERS]int{}
	total := 0
	drain_and_check :: proc(t: ^testing.T, q: ^Envelope_Queue, batch: ^[dynamic]Envelope, next: ^[PRODUCERS]int, total: ^int) {
		queue_drain(q, batch)
		for env in batch {
			id := env.action.(Action_Set_Scene).scene_id
			dash := strings.index_byte(id, '-')
			producer, _ := strconv.parse_int(id[:dash])
			seq, _ := strconv.parse_int(id[dash + 1:])
			testing.expect_value(t, seq, next[producer])
			next[producer] = seq + 1
			total^ += 1
		}
		queue_release(q, batch)
	}

	// Drain while producers are still running, like the main loop would.
	// Read the flag before draining so the final drain sees every push.
	for {
		finished := sync.atomic_load(&remaining) == 0
		drain_and_check(t, &q, &batch, &next, &total)
		if finished do break
	}

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, total, PRODUCERS * PUSHES_PER_PRODUCER)
	for n in next {
		testing.expect_value(t, n, PUSHES_PER_PRODUCER)
	}
}

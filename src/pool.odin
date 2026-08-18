package main

import "core:thread"
import "core:sync"
import "core:fmt"
import "core:prof/spall"

Pool_TaskProc :: proc(pool: ^Pool, data: rawptr)
Pool_Task :: struct {
	do_work: Pool_TaskProc,
	args: rawptr,
}

Pool_Thread :: struct {
	thread: ^thread.Thread,
	idx: int,

	queue: []Pool_Task,
	head_and_tail: u64,

	pool: ^Pool,
}

Pool :: struct {
	threads: []Pool_Thread,
	running: bool,

	tasks_available: sync.Futex,
	tasks_left: sync.Futex,
}

@(thread_local) current_thread_idx: int

wait_for_change :: proc(f: ^sync.Futex, expected: u32) {
	for {
		sync.futex_wait(f, expected)
		v := sync.atomic_load(f)
		if u32(v) != expected {
			break
		}
	}
}

pool_thread_init :: proc(pool: ^Pool, thrd: ^Pool_Thread, idx: int) {
	max_work := 1 << 14 // must be a power of 2

	thrd^ = Pool_Thread{
		queue = make([]Pool_Task, max_work),
		pool = pool,
		idx = idx,
	}
}

pool_queue_push :: proc(thrd: ^Pool_Thread, task: Pool_Task) -> bool {
	capture : u64 = 0
	new_capture : u64 = 0

	for {
		capture = sync.atomic_load(&thrd.head_and_tail)

		mask := u64(len(thrd.queue)) - 1
		head := (capture >> 32) & mask
		tail := u64(u32(capture)) & mask

		new_head := (head + 1) & mask
		if new_head == tail {
			// Queue is full!
			return false
		}

		// We push into the queue here to avoid a potential race condition where we
		// no longer own the slot by the time we're assigning to it
		thrd.queue[head] = task

		new_capture = (new_head << 32) | tail
		_, ok := sync.atomic_compare_exchange_strong(&thrd.head_and_tail, capture, new_capture)
		if ok {
			break
		}
	}

	sync.atomic_add(&thrd.pool.tasks_left, 1)
	sync.atomic_add(&thrd.pool.tasks_available, 1)
	sync.futex_broadcast(&thrd.pool.tasks_available)
	return true
}

pool_queue_pop :: proc(thrd: ^Pool_Thread) -> (Pool_Task, bool) {
	capture : u64 = 0
	new_capture : u64 = 0

	ret_task := Pool_Task{}

	for {
		capture = sync.atomic_load(&thrd.head_and_tail)

		mask := u64(len(thrd.queue)) - 1
		head := (capture >> 32) & mask
		tail := u64(u32(capture)) & mask

		new_tail := (tail + 1) & mask
		if tail == head {
			// Queue is empty!
			return ret_task, false
		}

		// Copy the task before we bump the tail to avoid the same race condition mentioned above
		ret_task = thrd.queue[tail]

		new_capture = (head << 32) | new_tail
		_, ok := sync.atomic_compare_exchange_strong(&thrd.head_and_tail, capture, new_capture)
		if ok {
			break
		}
	}

	return ret_task, true
}

pool_worker :: proc(ptr: rawptr) {
	current_thread := cast(^Pool_Thread)ptr
	current_thread_idx = current_thread.idx
	pool := current_thread.pool

	when SELF_TRACE {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		spall_buffer = spall.buffer_create(buffer_backing, u32(current_thread.idx))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
	}

	work_start: for pool.running {

		finished_tasks := 0
		for {
			task, ok := pool_queue_pop(current_thread)
			if !ok {
				break
			}

			task.do_work(pool, task.args)
			sync.atomic_sub(&pool.tasks_left, 1)

			finished_tasks += 1
		}
		if finished_tasks > 0 && sync.atomic_load(&pool.tasks_left) == 0 {
			sync.futex_signal(&pool.tasks_left)
		}

		remaining_tasks := sync.atomic_load(&pool.tasks_left)
		if remaining_tasks > 0 {
			idx := current_thread.idx
			for i := 0; i < len(pool.threads); i += 1 {
				if sync.atomic_load(&pool.tasks_left) == 0 {
					break
				}

				idx = (idx + 1) % len(pool.threads)
				thrd := &pool.threads[idx]

				task, ok := pool_queue_pop(thrd)
				if !ok {
					continue
				}

				task.do_work(pool, task.args)
				sync.atomic_sub(&pool.tasks_left, 1)

				if sync.atomic_load(&pool.tasks_left) == 0 {
					sync.futex_signal(&pool.tasks_left)
				}

				continue work_start
			}
		}

		state := sync.atomic_load(&pool.tasks_available)
		if !pool.running { break }
		wait_for_change(&pool.tasks_available, u32(state))
	}
}

pool_add_task :: proc(pool: ^Pool, task: Pool_Task) {
	current_thread := &pool.threads[current_thread_idx]
	pool_queue_push(current_thread, task)
}

pool_wait :: proc(pool: ^Pool) {
	current_thread := &pool.threads[current_thread_idx]

	for sync.atomic_load(&pool.tasks_left) > 0 {
		for {
			task, ok := pool_queue_pop(current_thread)
			if !ok {
				break
			}

			task.do_work(pool, task.args)
			sync.atomic_sub(&pool.tasks_left, 1)
		}

		remaining_tasks := sync.atomic_load(&pool.tasks_left)
		if remaining_tasks == 0 {
			break
		}

		wait_for_change(&pool.tasks_left, u32(remaining_tasks))
	}
}

pool_init :: proc(pool: ^Pool, child_thread_count: int) {
	thread_count := child_thread_count + 1
	pool.threads = make([]Pool_Thread, thread_count)
	pool.running = true

	pool_thread_init(pool, &pool.threads[0], 0)
	current_thread_idx = 0

	fmt.printf("Spinning up %d threads!\n", thread_count)
	for i := 1; i < thread_count; i += 1 {
		pool_thread_init(pool, &pool.threads[i], i)
		pool.threads[i].thread = thread.create_and_start_with_data(&pool.threads[i], pool_worker)
	}
}

pool_destroy :: proc(pool: ^Pool) {
	pool.running = false
	for i := 1; i < len(pool.threads); i += 1 {
		sync.atomic_add(&pool.tasks_available, 1)
		sync.futex_broadcast(&pool.tasks_available)
		thread.join(pool.threads[i].thread)
	}

	when GOOD_BOY_MODE {
		for thread in pool.threads {
			delete(thread.queue)
		}
		delete(pool.threads)
	}
}

Loader_TaskProc :: proc(loader: ^Loader, data: rawptr)
Loader_Task :: struct {
	do_work: Loader_TaskProc,
	args: rawptr,
}

Loader :: struct {
	running: bool,

	has_task: sync.Futex,
	done:     sync.Futex,

	task: Loader_Task,
	thread_count: int,
	pool: Pool,

	thrd: ^thread.Thread,
}

loader_worker :: proc(ptr: rawptr) {
	loader := cast(^Loader)ptr
	current_thread_idx = 0xBEEF

	when SELF_TRACE {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		spall_buffer = spall.buffer_create(buffer_backing, u32(current_thread_idx))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
	}

	pool_init(&loader.pool, loader.thread_count)

	for loader.running {
		has_task := sync.atomic_load(&loader.has_task)
		if has_task == 1 {
			loader.task.do_work(loader, loader.task.args)
			sync.atomic_store(&loader.has_task, 0)
			sync.futex_signal(&loader.has_task)
		}

		if !loader.running { break }
		wait_for_change(&loader.has_task, 0)
	}

	pool_wait(&loader.pool)
	pool_destroy(&loader.pool)

	sync.atomic_store(&loader.done, 1)
	sync.futex_signal(&loader.done)
}

loader_init :: proc(loader: ^Loader, thread_count: int) {
	loader^ = Loader{
		running = true,
		done = 0,
		thread_count = thread_count,
	}
	loader.thrd = thread.create_and_start_with_data(loader, loader_worker)
}

loader_set_task :: proc(loader: ^Loader, task: Loader_Task) {
	loader.task = task
	sync.atomic_store(&loader.has_task, 1)
	sync.futex_signal(&loader.has_task)
}

loader_wait :: proc(loader: ^Loader) {
	wait_for_change(&loader.has_task, 1)
}

loader_destroy :: proc(loader: ^Loader) {
	loader.running = false
	sync.atomic_store(&loader.has_task, 1)
	sync.futex_signal(&loader.has_task)

	done := sync.atomic_load(&loader.done)
	if done == 0 {
		wait_for_change(&loader.done, 0)
	}

	thread.join(loader.thrd)
}

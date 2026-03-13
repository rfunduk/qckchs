package qckchs

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import fio "lib:facilio"

import "mimir"

g: ^Engine_Memory

USE_TRACKING_ALLOCATOR :: #config(USE_TRACKING_ALLOCATOR, false)
global_context: runtime.Context

cleanup :: proc() {
	for _, &game in g.games {
		kill_bot(&game)
		delete(game.moves)
		delete(game.white_name)
		delete(game.black_name)
	}
	delete(g.games)
	free(g)
	mimir.destroy()
}

main :: proc() {
	context.logger = make_ts_logger()

	when USE_TRACKING_ALLOCATOR {
		default_allocator := context.allocator
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, default_allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		defer {
			if len(tracking_allocator.allocation_map) > 0 {
				fmt.eprintfln("=== %d allocations not freed ===", len(tracking_allocator.allocation_map))
				for _, entry in tracking_allocator.allocation_map {
					fmt.eprintfln("  %v bytes at %v", entry.size, entry.location)
				}
			}
			if len(tracking_allocator.bad_free_array) > 0 {
				fmt.eprintfln("=== %d bad frees ===", len(tracking_allocator.bad_free_array))
				for entry in tracking_allocator.bad_free_array {
					fmt.eprintfln("  at %v", entry.location)
				}
			}
			mem.tracking_allocator_destroy(&tracking_allocator)
		}
	} else {
		_ = fmt.Info
		_ = mem.Tracking_Allocator
	}

	global_context = context

	if len(os.args) > 1 {
		cli_lookup_game(os.args[1])
		return
	}

	fio.set_log(fio_log)

	engine_init()
	init_bot_configs()
	db_init()
	register_bots()
	load_templates()
	defer cleanup()
	defer db_shutdown()
	defer cleanup_templates()

	fio.on_request(handle_request)
	fio.on_stream("/stream/", handle_stream_open, handle_stream_close)
	fio.on_sse_message(handle_game_update)
	fio.run_every(1000, lifecycle_tick, nil)

	port, found := os.lookup_env("PORT")
	portc := strings.clone_to_cstring(found ? port : "8080")
	fio.listen(portc)
	defer delete(port)
	defer delete(portc)
}

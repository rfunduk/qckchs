package qckchs

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import fio "lib:facilio"

import "chess"
import "mimir"

g: ^Engine_Memory

cli_lookup_game :: proc(code: string) {
	engine_init()
	defer cleanup()
	db_init()
	defer db_shutdown()

	id, ok := game_id_from_code(code)
	if !ok {
		fmt.eprintfln("Invalid game code: %s", code)
		return
	}

	game, found := db_load_finished_game(id)
	if !found {
		fmt.eprintfln("Game %s (id=%d) not found", code, id)
		return
	}
	defer delete(game.moves)
	defer delete(game.white_name)
	defer delete(game.black_name)

	fmt.printfln("Game %s (#%d)", code, id)
	fmt.printfln("White:  %s", len(game.white_name) > 0 ? game.white_name : "(unknown)")
	fmt.printfln("Black:  %s", len(game.black_name) > 0 ? game.black_name : "(unknown)")
	fmt.printfln("State:  %v", game.state)
	if game.result != .In_Progress {
		fmt.printfln("Result: %s", result_string(game.result))
	}
	fmt.printfln("Clock:  W=%d  B=%d", game.clock.white_periods, game.clock.black_periods)
	fmt.println()

	// Board
	fmt.println("  a b c d e")
	for r: u8 = 0; r < chess.RANKS; r += 1 {
		fmt.printf("%d", chess.RANKS - r)
		for f: u8 = 0; f < chess.FILES; f += 1 {
			p := game.board[r * chess.FILES + f]
			fmt.printf(" %c", p == .X ? '.' : chess.piece_char(p))
		}
		fmt.println()
	}
	fmt.println()

	// Moves
	if len(game.moves) > 0 {
		san := moves_algebraic(game.initial_board, game.moves[:])
		defer {
			for m in san { delete(m) }
			delete(san)
		}
		for m, i in san {
			if i % 2 == 0 {
				fmt.printf("%d. %-6s", i / 2 + 1, m)
			} else {
				fmt.printfln(" %s", m)
			}
		}
		if len(san) % 2 != 0 { fmt.println() }
	}
}

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

fio_log :: proc "c" (level: i32, msg: [^]u8, len: u32) {
	context = global_context
	s := string(msg[:len])
	//odinfmt: disable
	switch level {
	case 0:	log.debug(s)
	case 2:	log.warn(s)
	case 3:	log.error(s)
	case 4:	log.fatal(s)
	case:	log.info(s)
	}
	//odinfmt: enable
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
	load_asset_digest()
	load_templates()
	defer cleanup()
	defer db_shutdown()
	defer cleanup_templates()
	defer cleanup_asset_digest()

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

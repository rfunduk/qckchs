package qckchs

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

import mg "lib:mongoose"

import "mimir"

CLI_Args :: struct {
	game:     string `usage:"look up a game by code"`,
	player:   string `usage:"look up a player by code"`,
	selfplay: bool `usage:"run engine selfplay (training data to stdout)"`,
	games:    i32 `usage:"number of selfplay games (0 = infinite)"`,
	depth:    i32 `usage:"selfplay search depth"`,
	hce:      bool `usage:"use HCE eval instead of NNUE for selfplay"`,
	nnue:     string `usage:"NNUE weights file for selfplay (default: mimir.nnue)"`,
	match:    bool `args:"name=match" usage:"run engine-vs-engine match"`,
	count:    i32 `usage:"number of matches (each = 2 games, one per color)"`,
	nnue1:    string `usage:"NNUE weights for engine 1 (omit for HCE)"`,
	nnue2:    string `usage:"NNUE weights for engine 2 (omit for HCE)"`,
}

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

	args := CLI_Args {
		depth = 64,
	}
	flags.parse_or_exit(&args, os.args, .Odin)

	if len(args.game) > 0 {
		cli_lookup_game(args.game)
		return
	} else if len(args.player) > 0 {
		cli_lookup_player(args.player)
		return
	} else if args.match {
		cli_match(args.count, args.depth, args.nnue1, args.nnue2)
		return
	} else if args.selfplay {
		cli_selfplay(args.games, args.depth, args.hce, args.nnue)
		return
	}

	mg.set_log(on_log)

	origin, has_origin := os.lookup_env_alloc("ORIGIN", context.allocator)
	when !ODIN_DEBUG {
		if !has_origin || len(origin) == 0 || !strings.has_prefix(origin, "https://") {
			log.fatal("ORIGIN env var must be set in production (https://example.com)")
			return
		}
	} else {
		_ = log.Level
	}

	if len(origin) > 0 {
		mg.set_origin(strings.clone_to_cstring(origin))
	}

	engine_init()
	init_bot_configs()
	db_init()
	register_bots()
	load_templates()
	defer cleanup()
	defer db_shutdown()
	defer cleanup_templates()

	mg.on_request(handle_request)
	mg.on_stream("/stream/", handle_stream_open, handle_stream_close)
	mg.on_sse_message(handle_game_update)
	mg.run_every(1000, lifecycle_tick, nil)

	port, found := os.lookup_env_alloc("PORT", context.allocator)
	portc := strings.clone_to_cstring(found ? port : "8080")
	mg.listen(portc)
	defer delete(port)
	defer delete(portc)
}

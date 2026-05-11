package qckchs

import "core:encoding/json"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:sync/chan"
import "core:thread"
import "core:time"

import fio "lib:facilio"

import "chess"
import "mimir"

// --- Types ---

Difficulty :: enum u8 {
	None,
	Easy,
	Medium,
	Hard,
}

Bot_Config :: struct {
	pk:        Player_Key,
	name:      string,
	depth_min: i32,
	depth_max: i32,
	noise:     i32,
	min_time:  time.Duration,
	tt_size:   u64,
}

Bot_Request :: struct {
	game_id:           Game_Id,
	board:             chess.Board,
	player:            chess.Player,
	remaining_periods: i32,
	move_number:       i32,
	max_depth:         i32,
}

Bot_Move :: struct {
	game_id: Game_Id,
	from:    u8,
	to:      u8,
}

pack_bot_move :: proc(m: Bot_Move) -> (rawptr, rawptr) {
	return rawptr(uintptr(m.game_id)), rawptr(uintptr(m.from) << 8 | uintptr(m.to))
}

unpack_bot_move :: proc(udata1, udata2: rawptr) -> Bot_Move {
	return {
		game_id = Game_Id(uintptr(udata1)),
		from = u8(uintptr(udata2) >> 8),
		to = u8(uintptr(udata2) & 0xFF),
	}
}

Bot_Handle :: struct {
	request_chan: chan.Chan(Bot_Request),
	thread:       ^thread.Thread,
	config:       ^Bot_Config,
}

// --- Bot configs ---

Mimir_Keys :: struct {
	easy:   string,
	medium: string,
	hard:   string,
}

bot_configs: [Difficulty]Bot_Config

init_bot_configs :: proc() {
	set_pk :: proc(pk: ^Player_Key, s: string) { copy(pk[:], s) }

	// Load PKs from mimir.json (path overridable via MIMIR_PATH)
	mimir_path_env, _ := os.lookup_env_alloc("MIMIR_PATH", context.allocator)
	mimir_path := len(mimir_path_env) > 0 ? mimir_path_env : "mimir.json"
	data, err := os.read_entire_file_from_path(mimir_path, context.allocator)
	if err != nil { log.fatalf("Failed to read %s — bot PKs must be configured", mimir_path) }

	keys: Mimir_Keys
	jerr := json.unmarshal(data, &keys)
	delete(data)
	if jerr != nil { log.fatalf("Failed to parse mimir.json: %v", jerr) }
	defer {
		delete(keys.easy)
		delete(keys.medium)
		delete(keys.hard)
	}

	if len(keys.easy) != 32 || len(keys.medium) != 32 || len(keys.hard) != 32 {
		log.fatalf("mimir.json: all PKs must be exactly 32 characters")
	}

	bot_configs[.Easy] = {
		name      = "Easy",
		depth_min = 2,
		depth_max = 2,
		noise     = 1100,
		min_time  = 800 * time.Millisecond,
		tt_size   = 1 << 14, // 16K entries, ~192KB
	}
	set_pk(&bot_configs[.Easy].pk, keys.easy)

	bot_configs[.Medium] = {
		name      = "Medium",
		depth_min = 3,
		depth_max = 5,
		noise     = 450,
		min_time  = 600 * time.Millisecond,
		tt_size   = 1 << 17, // 128K entries, ~1.5MB
	}
	set_pk(&bot_configs[.Medium].pk, keys.medium)

	bot_configs[.Hard] = {
		name      = "Hard",
		depth_min = 64,
		depth_max = 64,
		noise     = 0,
		min_time  = 200 * time.Millisecond,
		tt_size   = 1 << 20, // 1M entries, ~12MB
	}
	set_pk(&bot_configs[.Hard].pk, keys.hard)
}

// --- Registration ---

register_bots :: proc() {
	for d in Difficulty {
		if d == .None { continue }
		config := &bot_configs[d]
		db_claim_player(config.pk, config.name)
		log.infof("Registered bot: %s (%.8s...)", config.name, string(config.pk[:8]))
	}
}

// --- Spawn / Kill ---

spawn_bot :: proc(game_id: Game_Id, difficulty: Difficulty) -> ^Bot_Handle {
	config := &bot_configs[difficulty]
	handle := new(Bot_Handle, global_context.allocator)

	err: mem.Allocator_Error
	handle.request_chan, err = chan.create(chan.Chan(Bot_Request), 1, global_context.allocator)
	if err != nil {
		log.errorf("Failed to create bot channel: %v", err)
		free(handle, global_context.allocator)
		return nil
	}
	handle.config = config

	// thread.create uses context.allocator for the Thread struct.
	// Must outlive the per-request arena that's active when spawn_bot is called.
	context.allocator = global_context.allocator
	handle.thread = thread.create(bot_worker)
	handle.thread.data = handle
	thread.start(handle.thread)

	log.infof("Game %d: spawned %s bot thread", game_id, config.name)
	return handle
}

kill_bot :: proc(game: ^Game) {
	if game.bot == nil { return }
	handle := game.bot
	log.debugf("Game %d: killing bot thread", game.id)
	chan.close(handle.request_chan)
	thread.join(handle.thread)
	thread.destroy(handle.thread)
	chan.destroy(handle.request_chan)
	free(handle, global_context.allocator)
	game.bot = nil
}

// --- Notify ---

notify_bot :: proc(game: ^Game) {
	if game.bot == nil { return }
	config := game.bot.config

	// Check it's the bot's turn
	bot_is_white := config.pk == game.white_key
	bot_turn := (bot_is_white && game.state == .Turn_White) || (!bot_is_white && game.state == .Turn_Black)
	if !bot_turn { return }

	remaining := bot_is_white ? i32(game.clock.white_periods) : i32(game.clock.black_periods)
	move_number := i32(len(game.moves))

	// Randomize depth
	max_depth: i32
	if config.depth_min == config.depth_max {
		max_depth = config.depth_min
	} else {
		max_depth = config.depth_min + i32(rand.int_max(int(config.depth_max - config.depth_min + 1)))
	}

	req := Bot_Request {
		game_id           = game.id,
		board             = game.board,
		player            = game.current_player,
		remaining_periods = remaining,
		move_number       = move_number,
		max_depth         = max_depth,
	}

	chan.send(game.bot.request_chan, req)
}

// --- Worker thread ---

bot_worker :: proc(t: ^thread.Thread) {
	context.logger = global_context.logger
	handle := cast(^Bot_Handle)t.data
	config := handle.config
	eng := mimir.engine_create(config.tt_size)
	eng.eval_noise = config.noise
	eng.nnue = &mimir.nnue_weights
	defer mimir.engine_destroy(eng)

	log.infof(
		"Bot worker started: %s (noise=%d, depth=%d-%d)",
		config.name,
		config.noise,
		config.depth_min,
		config.depth_max,
	)

	for {
		req, ok := chan.recv(handle.request_chan)
		if !ok { break }

		start := time.tick_now()
		best := mimir.pick_best_move(
			eng,
			req.board,
			req.player,
			req.remaining_periods,
			req.move_number,
			req.max_depth,
		)

		// Enforce min_time
		elapsed := time.tick_diff(start, time.tick_now())
		if elapsed < config.min_time {
			time.sleep(config.min_time - elapsed)
		}

		from := mimir.move_from(best)
		to := mimir.move_to(best)

		fio.defer_task(bot_move_callback, pack_bot_move({req.game_id, from, to}))
	}

	log.infof("Bot worker exiting: %s", config.name)
}

// --- Callback on event loop ---

bot_move_callback :: proc "c" (udata1: rawptr, udata2: rawptr) {
	context = global_context

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != .None { return }
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	bm := unpack_bot_move(udata1, udata2)
	game_id := bm.game_id
	from := bm.from
	to := bm.to

	if game_id not_in g.games { return }

	game := &g.games[game_id]
	if game.bot == nil { return }
	if game.state != .Turn_White && game.state != .Turn_Black { return }

	pk := game.bot.config.pk
	now := time.to_unix_nanoseconds(time.now())
	move, move_result := game_move(game, pk, from, to, now)

	switch move_result {
	case .Invalid_State, .Wrong_Player, .Illegal_Move, .Timed_Out:
		log.warnf("Game %s: bot move rejected (%v)", game.code, move_result)
		return
	case .Ok, .King_Captured, .Stalemate:
		log.infof(
			"Game %s: bot %v %d -> %d%s",
			game.code,
			move.piece,
			move.from,
			move.to,
			move_result == .King_Captured ? " (king captured!)" : move_result == .Stalemate ? " (draw)" : "",
		)
	}

	publish_game(game.code)
	publish_lobby(game_id, .Update)
	if move_result == .King_Captured || move_result == .Stalemate {
		publish_players(game, game_id, .Resolve)
	} else {
		publish_players(game, game_id, .Update)
		notify_bot(game)
	}
}

// --- Helper used in routes ---

bot_for_difficulty :: proc(d: Difficulty) -> ^Bot_Config {
	if d == .None { return nil }
	return &bot_configs[d]
}

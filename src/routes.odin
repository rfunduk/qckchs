package qckchs

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"

import fio "lib:facilio"

import "chess"

// --- Router entry point ---

handle_request :: proc "c" (req: fio.Req) {
	context = global_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != .None {
		log.error("Failed to init request arena")
		respond_500(req)
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	path := get_path(req)

	if path == "/profile" {
		route_profile(req)
	} else if path == "/" {
		route_index(req)
	} else if path == "/new-game" {
		route_new_game(req)
	} else if strings.has_prefix(path, "/new-game/") {
		route_new_game_bot(req, path)
	} else if strings.has_prefix(path, "/games/") {
		route_game(req)
	} else if strings.has_prefix(path, "/move/") {
		route_move(req)
	} else if strings.has_prefix(path, "/check/") {
		route_check(req)
	} else if strings.has_prefix(path, "/static/") {
		route_static(req, path)
	} else if path == "/health" {
		respond_ok(req)
	} else {
		respond_404(req)
	}
}

// --- Route handlers ---

route_static :: proc(req: fio.Req, path: string) {
	// Strip leading slash to get filesystem path relative to CWD
	fs_path := path[1:]
	if strings.contains(fs_path, "..") {
		respond_404(req)
		return
	}
	data, ok := os.read_entire_file(fs_path)
	if !ok {
		respond_404(req)
		return
	}
	fio.respond(req, 200, content_type_for(path), raw_data(data), u32(len(data)), "public, max-age=31536000, immutable")
}

route_index :: proc(req: fio.Req) {
	if require_claimed(req, "/") { return }
	games := make([dynamic]Mini_Game_Data)
	for id, &game in g.games {
		if game.state == .Waiting { continue }
		append(
			&games,
			Mini_Game_Data {
				assets = g_assets,
				code = game_code(id),
				squares = build_mini_squares(game.board, false),
				wn = game.white_name,
				bn = game.black_name,
				w_win = game.result in White_Wins,
				b_win = game.result in Black_Wins,
			},
		)
	}
	data := Index_Page_Data {
		assets = g_assets,
		games = games[:],
	}
	html, ok := render_template("index", data)
	if !ok { respond_404(req);return }
	respond_html(req, html)
}

route_new_game :: proc(req: fio.Req) {
	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok {
		respond_400(req)
		return
	}

	now := time.to_unix_nanoseconds(time.now())
	id := game_init(pk, now)
	code := game_code(id)

	game := g.games[id]
	color := game.white_key == pk ? "white" : "black"
	log.infof("Game %d: creator is %s (%.8s...)", id, color, string(pk[:8]))

	respond_redirect(req, fmt.aprintf("/games/%s", code))
}

route_new_game_bot :: proc(req: fio.Req, path: string) {
	suffix := path[len("/new-game/"):]
	difficulty: Difficulty
	switch suffix {
	case "easy":
		difficulty = .Easy
	case "medium":
		difficulty = .Medium
	case "hard":
		difficulty = .Hard
	case:
		respond_404(req)
		return
	}

	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok {
		respond_400(req)
		return
	}

	now := time.to_unix_nanoseconds(time.now())
	id := game_init(pk, now)
	game := &g.games[id]
	game.difficulty = difficulty

	config := bot_for_difficulty(difficulty)

	// Fill the empty slot with the bot's PK
	if game.white_key == EMPTY_KEY {
		game.white_key = config.pk
		game.white_name = strings.clone(config.name, global_context.allocator)
	} else {
		game.black_key = config.pk
		game.black_name = strings.clone(config.name, global_context.allocator)
	}

	// Start the game immediately
	game.current_player = .White
	game.state = .Turn_White
	game.clock.last_move_at = now
	record_position(game)

	// Spawn bot thread
	game.bot = spawn_bot(id, difficulty)

	// If bot is white, notify it to move first
	if config.pk == game.white_key {
		notify_bot(game)
	}

	db_save(game)

	code := game_code(id)
	color := game.white_key == pk ? "white" : "black"
	log.infof("Game %s: %s vs %s (creator is %s)", code, suffix, config.name, color)
	respond_redirect(req, fmt.aprintf("/games/%s", code))
}

route_profile :: proc(req: fio.Req) {
	method := get_method(req)
	query := get_query(req)

	if method == "POST" {
		pk, pk_ok := get_cookie_pk(req)
		if !pk_ok {
			respond_400(req)
			return
		}

		name_len: u32
		name_cstr := fio.get_form_param(req, "name", 4, &name_len)
		name := name_cstr != nil ? strings.clone_from_cstring(name_cstr)[:name_len] : ""
		if len(name) > 20 { name = name[:20] }

		next_len: u32
		next_cstr := fio.get_form_param(req, "next", 4, &next_len)
		next := next_cstr != nil ? strings.clone_from_cstring(next_cstr)[:next_len] : "/"

		was_claimed := db_is_player_claimed(pk)
		db_claim_player(pk, name)

		if !was_claimed {
			respond_redirect(req, len(next) > 0 ? next : "/")
		} else {
			respond_redirect(req, "/profile?saved=1")
		}
		return
	}

	// GET
	pk, pk_ok := get_cookie_pk(req)
	next := get_query_param(query, "next")
	if len(next) == 0 { next = "/" }
	saved := get_query_param(query, "saved") == "1"

	name: string
	claimed: bool
	stats: Player_Stats
	pk_str: string
	pc: string

	player_games: [dynamic]Mini_Game_Data
	if pk_ok {
		name = db_get_player_name(pk)
		claimed = db_is_player_claimed(pk)
		stats = db_get_player_stats(pk)
		pk_str = string(pk[:])

		pid, pid_ok := db_get_player_id(pk)
		if pid_ok {
			pc = player_code(pid)
		}

		// Active games (from memory, with flip)
		for id, &game in g.games {
			if game.state == .Waiting { continue }
			if pk != game.white_key && pk != game.black_key { continue }
			is_black := pk == game.black_key
			wn := game.white_name
			bn := game.black_name
			w_win := game.result in White_Wins
			b_win := game.result in Black_Wins
			append(
				&player_games,
				Mini_Game_Data {
					assets = g_assets,
					code = game_code(id),
					squares = build_mini_squares(game.board, is_black),
					wn = is_black ? bn : wn,
					bn = is_black ? wn : bn,
					w_win = is_black ? b_win : w_win,
					b_win = is_black ? w_win : b_win,
				},
			)
		}

		// Finished games (from DB, already flipped)
		db_games := db_get_player_games(pk)
		for dg in db_games {
			mgd := dg
			mgd.assets = g_assets
			append(&player_games, mgd)
		}
	}

	data := Profile_Page_Data {
		assets      = g_assets,
		name        = name,
		pk          = pk_ok ? fmt.tprintf("%s...", pk_str[:8]) : "",
		pk_full     = pk_str,
		claimed     = claimed,
		saved       = saved,
		next        = next,
		played      = int(stats.played),
		wins        = int(stats.wins),
		losses      = int(stats.losses),
		draws       = int(stats.draws),
		games       = player_games[:],
		player_code = pc,
	}
	html, ok := render_template("profile", data)
	if !ok { respond_500(req);return }
	respond_html(req, html)
}

route_game :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/games/", 1)
	if !ok { respond_404(req);return }
	code := p[0]

	if require_claimed(req, fmt.tprintf("/games/%s", code)) { return }

	id, id_ok := game_id_from_code(code)
	if !id_ok { respond_404(req);return }

	game: Game
	active: bool = false
	if id in g.games {
		game = g.games[id]
		active = true
	} else {
		found: bool
		game, found = db_load_finished_game(id)
		if !found { respond_404(req);return }
	}

	viewer := viewer_from_cookie(req, game)

	now := time.to_unix_nanoseconds(time.now())
	wp, bp := effective_periods(game.clock, game.state, now)
	squares := board_squares(game.board, viewer)
	data := Game_Page_Data {
		assets  = g_assets,
		code    = code,
		active  = active,
		squares = squares[:],
		result  = result_string(game.result),
		turn    = turn_string(game.state),
		state   = state_string(game.state),
		wp      = wp,
		bp      = bp,
		wn      = game.white_name,
		bn      = game.black_name,
		color   = viewer == .Black ? "black" : viewer == .White ? "white" : "spectator",
	}
	html, _ := render_template("game", data)
	respond_html(req, html)
}

route_move :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/move/", 3)
	if !ok { respond_400(req);return }
	code := p[0]

	from, from_ok := parse_u8(p[1])
	to, to_ok := parse_u8(p[2])
	if !from_ok || !to_ok || from >= chess.RANKS * chess.FILES || to >= chess.RANKS * chess.FILES {
		respond_400(req)
		return
	}

	id, id_ok := game_id_from_code(code)
	if !id_ok || id not_in g.games { respond_404(req);return }

	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok { respond_400(req);return }

	game := &g.games[id]
	now := time.to_unix_nanoseconds(time.now())
	move, result := game_move(game, pk, from, to, now)

	switch result {
	case .Invalid_State:
		log.debugf("Game %s: move rejected, state is %v", code, game.state)
		respond_400(req)
		return
	case .Wrong_Player:
		log.debugf("Game %s: move rejected, wrong player", code)
		respond_400(req)
		return
	case .Illegal_Move:
		log.debugf("Game %s: illegal move %d → %d", code, from, to)
		respond_400(req)
		return
	case .Timed_Out:
		log.infof("Game %s: move rejected, player timed out", code)
		publish_game(code)
		publish_lobby(id, .Update)
		publish_players(game, id, .Resolve)
		respond_400(req)
		return
	case .Ok, .King_Captured, .Stalemate:
		log.infof(
			"Game %s: %v %d → %d%s",
			code,
			move.piece,
			move.from,
			move.to,
			result == .King_Captured ? " (king captured!)" : result == .Stalemate ? " (draw)" : "",
		)
	}

	publish_game(code)
	publish_lobby(id, .Update)
	if result == .King_Captured || result == .Stalemate {
		publish_players(game, id, .Resolve)
	} else {
		publish_players(game, id, .Update)
		if game.bot != nil {
			notify_bot(game)
		}
	}
	fio.respond(req, 204, "text/plain", nil, 0, "no-store")
}

route_check :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/check/", 1)
	if !ok { respond_404(req);return }
	code := p[0]

	id, id_ok := game_id_from_code(code)
	if !id_ok || id not_in g.games { respond_404(req);return }

	game := &g.games[id]
	now := time.to_unix_nanoseconds(time.now())

	if game.state == .Turn_White || game.state == .Turn_Black {
		timed_out, _, _ := apply_timeout(game, now)
		if timed_out {
			log.infof("Game %s: flagged by client", code)
			publish_game(code)
			publish_players(game, id, .Resolve)
		}
	}

	fio.respond(req, 204, "text/plain", nil, 0, "no-store")
}

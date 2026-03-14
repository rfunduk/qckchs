package qckchs

import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
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

	if path == "/profile" || strings.has_prefix(path, "/profile/") {
		route_profile(req, path)
	} else if path == "/logout" {
		route_logout(req)
	} else if path == "/" {
		route_index(req)
	} else if strings.has_prefix(path, "/new-game") {
		route_new_game(req, path)
	} else if strings.has_prefix(path, "/games/") {
		route_game(req)
	} else if strings.has_prefix(path, "/make-public/") {
		route_make_public(req)
	} else if strings.has_prefix(path, "/move/") {
		route_move(req)
	} else if strings.has_prefix(path, "/replay/") {
		route_replay(req)
	} else if strings.has_prefix(path, "/check/") {
		route_check(req)
	} else if strings.has_prefix(path, "/ping/") {
		route_ping(req)
	} else if strings.has_prefix(path, "/static/") {
		// static handler in dev only
		when ODIN_DEBUG {
			route_static(req, path)
		} else {
			respond_404(req)
		}
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
	if strings.contains(fs_path, "..") { respond_404(req); return }
	data, ok := os.read_entire_file(fs_path)
	if !ok { respond_404(req); return }
	fio.respond(
		req,
		200,
		content_type_for(path),
		raw_data(data),
		u32(len(data)),
		"public, max-age=31536000, immutable",
	)
}

route_index :: proc(req: fio.Req) {
	joinable := make([dynamic]Mini_Game_Data)
	games := make([dynamic]Mini_Game_Data)
	for id, &game in g.games {
		if game.public && game.state == .Waiting {
			mgd := build_mini_game_data(id, &game, false)
			mgd.joinable = true
			append(&joinable, mgd)
		} else if game.state != .Waiting {
			append(&games, build_mini_game_data(id, &game, false))
		}
	}
	data := Index_Page_Data {
		assets   = g_assets,
		joinable = joinable[:],
		games    = games[:],
	}
	html, ok := render_template("index", data)
	if !ok { respond_404(req); return }
	respond_html(req, html)
}

route_new_game :: proc(req: fio.Req, path: string) {
	if require_claimed(req, path) { return }

	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok { respond_400(req); return }

	suffix := path[len("/new-game"):]
	if len(suffix) > 0 { suffix = suffix[1:] } // strip leading /

	id: Game_Id
	if len(suffix) == 0 {
		id = create_game(pk)
	} else {
		difficulty, ok := parse_difficulty(suffix)
		if !ok { respond_404(req); return }
		id = create_bot_game(pk, difficulty)
	}

	respond_redirect(req, fmt.aprintf("/games/%s", g.games[id].code))
}

route_profile :: proc(req: fio.Req, path: string) {
	public := strings.has_prefix(path, "/profile/")

	// Resolve the player key: from URL code (public) or cookie (own profile)
	pk: Player_Key
	pk_ok: bool
	pc: string

	if public {
		p, p_ok := path_params(path, "/profile/", 1)
		if !p_ok { respond_404(req); return }

		pid, pid_ok := player_id_from_code(p[0])
		if !pid_ok { respond_404(req); return }

		pk, pk_ok = db_get_player_key(pid)
		if !pk_ok { respond_404(req); return }

		name := db_get_player_name(pk)
		if len(name) == 0 { respond_404(req); return }

		pc = player_code(pid)
	} else {
		// Own profile — POST handling
		method := get_method(req)
		if method == "POST" {
			pk, pk_ok = get_cookie_pk(req)
			if !pk_ok { respond_400(req); return }

			name_len: u32
			name_cstr := fio.get_form_param(req, "name", 4, &name_len)
			name := name_cstr != nil ? strings.clone_from_cstring(name_cstr)[:name_len] : ""
			if len(name) > 20 { name = name[:20] }

			next_len: u32
			next_cstr := fio.get_form_param(req, "next", 4, &next_len)
			next := next_cstr != nil ? strings.clone_from_cstring(next_cstr)[:next_len] : "/"

			was_claimed := db_is_player_claimed(pk)
			db_claim_player(pk, name)

			dest: string
			if was_claimed {
				dest = "/profile?saved=1"
			} else if strings.has_prefix(next, "/new-game") {
				suffix := next[len("/new-game"):]
				if len(suffix) > 0 { suffix = suffix[1:] }
				if len(suffix) == 0 {
					id := create_game(pk)
					dest = fmt.aprintf("/games/%s", g.games[id].code)
				} else if difficulty, dok := parse_difficulty(suffix); dok {
					id := create_bot_game(pk, difficulty)
					dest = fmt.aprintf("/games/%s", g.games[id].code)
				} else {
					dest = "/"
				}
			} else {
				dest = len(next) > 0 ? next : "/"
			}
			respond_redirect(req, dest)
			return
		}

		pk, pk_ok = get_cookie_pk(req)
		if pk_ok {
			pid, pid_ok := db_get_player_id(pk)
			if pid_ok { pc = player_code(pid) }
		}
	}

	// GET — gather profile data
	query := get_query(req)
	next := get_query_param(query, "next")
	if len(next) == 0 { next = "/" }
	saved := get_query_param(query, "saved") == "1"

	name: string
	claimed: bool
	stats: Player_Stats
	pk_str: string

	player_games: [dynamic]Mini_Game_Data
	if pk_ok {
		name = db_get_player_name(pk)
		claimed = db_is_player_claimed(pk)
		stats = db_get_player_stats(pk)
		pk_str = string(pk[:])

		// Active games (from memory)
		active_ids: map[Game_Id]bool
		for id, &game in g.games {
			if game.state == .Waiting { continue }
			if pk != game.white_key && pk != game.black_key { continue }
			is_black := pk == game.black_key
			active_ids[id] = true
			append(&player_games, build_mini_game_data(id, &game, is_black))
		}

		// Finished games (from DB, skip any already shown from memory)
		db_games := db_get_player_games(pk)
		for dg in db_games {
			if dg.game_id in active_ids { continue }
			mgd := dg
			mgd.assets = g_assets
			append(&player_games, mgd)
		}
	}

	data := Profile_Page_Data {
		assets       = g_assets,
		edit_profile = !public,
		name         = name,
		claimed      = claimed,
		saved        = saved,
		next         = next,
		played       = int(stats.played),
		wins         = int(stats.wins),
		losses       = int(stats.losses),
		draws        = int(stats.draws),
		games        = player_games[:],
		player_code  = pc,
	}
	if !public && pk_ok {
		data.pk = fmt.tprintf("%s...", pk_str[:8])
		data.pk_full = pk_str
	}
	html, ok := render_template("profile", data)
	if !ok { respond_500(req); return }
	respond_html(req, html)
}

route_logout :: proc(req: fio.Req) {
	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok {
		respond_redirect(req, "/")
		return
	}

	pk_str := string(pk[:])
	data := Logout_Page_Data {
		assets  = g_assets,
		pk      = fmt.tprintf("%s...", pk_str[:8]),
		pk_full = pk_str,
	}
	html, ok := render_template("logout", data)
	if !ok { respond_500(req); return }
	respond_html(req, html)
}

route_game :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/games/", 1)
	if !ok { respond_404(req); return }
	code := p[0]

	if require_claimed(req, fmt.tprintf("/games/%s", code)) { return }

	id, id_ok := game_id_from_code(code)
	if !id_ok { respond_404(req); return }

	game: Game
	active: bool = false
	if id in g.games {
		game = g.games[id]
		active = true
	} else {
		found: bool
		game, found = db_load_finished_game(id)
		if !found { respond_404(req); return }
	}

	viewer := viewer_from_cookie(req, game)

	// Join flow for public waiting games
	join_prompt := false
	if active && game.public && game.state == .Waiting && viewer == .None {
		query := get_query(req)
		if get_query_param(query, "join") != "1" {
			join_prompt = true
			active = false // Don't open SSE stream
		}
	}

	now := time.to_unix_nanoseconds(time.now())
	wp, bp := effective_periods(game.clock, game.state, now)

	max_ply := (active && game.state != .Resolved) ? 0 : len(game.moves)
	squares: [chess.RANKS * chess.FILES]Square_Data
	if max_ply == 0 || active {
		squares = board_squares(game.board, viewer)
	} else {
		squares = board_squares_at_ply(game.initial_board, game.moves[:], max_ply, viewer)
	}

	paired := game.white_key != EMPTY_KEY && game.black_key != EMPTY_KEY

	white_code, black_code: string
	if wid, wok := db_get_player_id(game.white_key); wok {
		white_code = player_code(wid)
	}
	if bid, bok := db_get_player_id(game.black_key); bok {
		black_code = player_code(bid)
	}

	data := Game_Page_Data {
		assets = g_assets,
		game_id = id,
		code = code,
		active = active,
		squares = squares[:],
		result = result_string(game.result),
		turn = turn_string(game.state),
		state = state_string(game.state),
		white = {name = game.white_name, code = white_code, periods = wp},
		black = {name = game.black_name, code = black_code, periods = bp},
		color = viewer == .Black ? "black" : viewer == .White ? "white" : "spectator",
		max_ply = max_ply,
		paired = paired ? 1 : 0,
		public = game.public ? 1 : 0,
		join_prompt = join_prompt,
	}
	html, _ := render_template("game", data)
	respond_html(req, html)
}

route_make_public :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/make-public/", 1)
	if !ok { respond_404(req); return }
	code := p[0]

	id, id_ok := game_id_from_code(code)
	if !id_ok || id not_in g.games { respond_404(req); return }

	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok { respond_400(req); return }

	game := &g.games[id]
	if game.state != .Waiting { respond_400(req); return }
	if pk != game.white_key && pk != game.black_key { respond_400(req); return }

	game.public = true
	db_save(game)
	publish_lobby(id, .Add)
	publish_game(code)

	fio.respond(req, 204, "text/plain", nil, 0, "no-store")
}

route_move :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/move/", 3)
	if !ok { respond_400(req); return }
	code := p[0]

	from, from_ok := parse_u8(p[1])
	to, to_ok := parse_u8(p[2])
	if !from_ok || !to_ok || from >= chess.RANKS * chess.FILES || to >= chess.RANKS * chess.FILES {
		respond_400(req)
		return
	}

	id, id_ok := game_id_from_code(code)
	if !id_ok || id not_in g.games { respond_404(req); return }

	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok { respond_400(req); return }

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
		if game.bot != nil { notify_bot(game) }
	}
	fio.respond(req, 204, "text/plain", nil, 0, "no-store")
}

route_check :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/check/", 1)
	if !ok { respond_404(req); return }
	code := p[0]

	id, id_ok := game_id_from_code(code)
	if !id_ok || id not_in g.games { respond_404(req); return }

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

route_ping :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/ping/", 1)
	if !ok { respond_404(req); return }
	code := p[0]

	id, id_ok := game_id_from_code(code)
	if !id_ok || id not_in g.games { respond_404(req); return }

	pk, pk_ok := get_cookie_pk(req)
	if !pk_ok { fio.respond(req, 204, "text/plain", nil, 0, "no-store"); return }

	game := &g.games[id]
	now := time.to_unix_nanoseconds(time.now())

	if pk == game.white_key {
		game.white_last_seen = now
	} else if pk == game.black_key {
		game.black_last_seen = now
	}

	fio.respond(req, 204, "text/plain", nil, 0, "no-store")
}

route_replay :: proc(req: fio.Req) {
	p, ok := path_params(get_path(req), "/replay/", 2)
	if !ok { respond_400(req); return }
	code := p[0]

	id, id_ok := game_id_from_code(code)
	if !id_ok { respond_404(req); return }

	// Reject active games
	if id in g.games { respond_400(req); return }

	game, found := db_load_finished_game(id)
	if !found { respond_404(req); return }

	ply_val, ply_ok := strconv.parse_int(p[1])
	if !ply_ok { respond_400(req); return }
	ply := clamp(ply_val, 0, len(game.moves))

	viewer := viewer_from_cookie(req, game)
	squares := board_squares_at_ply(game.initial_board, game.moves[:], ply, viewer)
	data := Game_Page_Data {
		assets  = g_assets,
		squares = squares[:],
	}
	board_html, render_ok := render_partial("_board", data)
	if !render_ok { respond_500(req); return }

	b := strings.builder_make()
	sse_append_morph_el(&b, "#board", board_html)
	sse_append_signals(&b, fmt.tprintf("{{ ply: %d }}", ply))
	sse_respond(req, &b)
}

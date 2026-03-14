package qckchs

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:time"

import fio "lib:facilio"

import "chess"

// --- SSE subscription data packed into a uintptr (no allocation needed) ---
// Layout: [id:56][flags:8] — lower byte encodes kind + id + viewer + json flag.

Sub_Kind :: enum {
	Lobby,
	Game,
	Player,
}

Sub_Data :: struct {
	kind:    Sub_Kind,
	id:      u32,
	viewer:  chess.Player,
	is_json: bool,
}

pack_sub :: proc(data: Sub_Data) -> rawptr {
	switch data.kind {
	case .Lobby:
		return nil
	case .Player:
		return rawptr(uintptr(data.id) << 8 | 0xFF)
	case .Game:
		lower := uintptr(u8(data.viewer))
		if data.is_json { lower |= 0x80 }
		return rawptr(uintptr(data.id) << 8 | lower)
	}
	return nil
}

unpack_sub :: proc(udata: rawptr) -> Sub_Data {
	val := uintptr(udata)
	lower := u8(val & 0xFF)
	if lower == 0xFF {
		return {kind = .Player, id = u32(val >> 8)}
	}
	id := u32(val >> 8)
	if id == 0 {
		return {kind = .Lobby}
	}
	return {kind = .Game, id = id, viewer = chess.Player(lower & 0x7F), is_json = (lower & 0x80) != 0}
}

// --- Publish helpers ---

Lobby_Op :: enum u8 {
	Add    = 'a',
	Update = 'u',
	Remove = 'r',
}

Player_Op :: enum u8 {
	Add     = 'a',
	Update  = 'u',
	Remove  = 'r',
	Resolve = 'x',
}

publish_lobby :: proc(id: Game_Id, op: Lobby_Op) {
	channel: string = "lobby"
	msg := fmt.tprintf("%c:%d", rune(u8(op)), id)
	fio.publish(raw_data(channel), u32(len(channel)), raw_data(msg), u32(len(msg)))
}

publish_game :: proc(code: string) {
	channel := fmt.aprintf("game:%s", code)
	fio.publish(raw_data(channel), u32(len(channel)), nil, 0)
}

publish_player :: proc(player_id: i64, game_id: Game_Id, op: Player_Op) {
	channel := fmt.tprintf("player:%d", player_id)
	msg := fmt.tprintf("%c:%d", rune(u8(op)), game_id)
	fio.publish(raw_data(channel), u32(len(channel)), raw_data(msg), u32(len(msg)))
}

publish_players :: proc(game: ^Game, game_id: Game_Id, op: Player_Op) {
	w_id, w_ok := db_get_player_id(game.white_key)
	b_id, b_ok := db_get_player_id(game.black_key)
	if w_ok { publish_player(w_id, game_id, op) }
	if b_ok { publish_player(b_id, game_id, op) }
}

// --- Stream entry points ---

handle_stream_open :: proc "c" (sse: fio.SSE) {
	context = global_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != .None {
		log.error("Failed to init SSE arena")
		fio.sse_close(sse)
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	route_game_stream(sse)
}

handle_stream_close :: proc "c" (_sse: fio.SSE) {
	context = global_context
	log.info("Stream closed")
}

// --- Update handlers ---

handle_game_update :: proc "c" (sse: fio.SSE, udata: rawptr, msg_ptr: [^]u8, msg_len: u32) {
	context = global_context
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != .None { return }
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	sub := unpack_sub(udata)

	switch sub.kind {
	case .Player:
		handle_player_update(sse, i64(sub.id), msg_ptr, msg_len)
	case .Lobby:
		if msg_len < 3 || msg_ptr == nil { return }
		msg := string(msg_ptr[:msg_len])
		op := msg[0]
		lobby_id, ok := strconv.parse_uint(msg[2:])
		if !ok { return }
		id := Game_Id(lobby_id)
		game, exists := &g.games[id]
		code := exists ? game.code : game_code(id)
		selector := fmt.aprintf("#lobby-%s", code)

		switch op {
		case 'a':
			if !exists { return }
			html, rok := render_lobby_game(id, game)
			if rok { ds_append_el(sse, "#lobby", html) }
		case 'u':
			if !exists { return }
			html, rok := render_lobby_game(id, game)
			if rok { ds_patch_el(sse, selector, html) }
		case 'r':
			ds_remove_el(sse, selector)
		}
	case .Game:
		game_id := Game_Id(sub.id)
		if game_id not_in g.games { return }
		game := &g.games[game_id]
		now := time.to_unix_nanoseconds(time.now())

		if sub.is_json {
			json_data := game_json(game, sub.viewer, now)
			sse_write_json(sse, json_data)
		} else {
			board_html, ok := render_board(game, sub.viewer)
			if ok { ds_patch_el(sse, "#board", board_html) }
			ds_patch_signals(sse, game_signals(game, now))
		}
	}
}

handle_player_update :: proc(sse: fio.SSE, player_id: i64, msg_ptr: [^]u8, msg_len: u32) {
	if msg_len < 3 || msg_ptr == nil { return }
	msg := string(msg_ptr[:msg_len])
	op := msg[0]
	game_id_val, ok := strconv.parse_uint(msg[2:])
	if !ok { return }
	id := Game_Id(game_id_val)

	pk, pk_ok := db_get_player_key(player_id)
	if !pk_ok { return }

	game, exists := &g.games[id]
	code := exists ? game.code : game_code(id)
	selector := fmt.aprintf("#lobby-%s", code)

	switch op {
	case 'a':
		if !exists { return }
		is_black := pk == game.black_key
		html, rok := render_mini_game(id, game, is_black)
		if rok { ds_prepend_el(sse, "#profile-games", html) }
	case 'u':
		if !exists { return }
		is_black := pk == game.black_key
		html, rok := render_mini_game(id, game, is_black)
		if rok { ds_patch_el(sse, selector, html) }
	case 'r':
		ds_remove_el(sse, selector)
	case 'x':
		if !exists { return }
		is_black := pk == game.black_key
		html, rok := render_mini_game(id, game, is_black)
		if rok { ds_patch_el(sse, selector, html) }
		stats := calc_player_stats(player_id, game.result, !is_black)
		stats_bytes, _ := json.marshal(stats)
		stats_json := string(stats_bytes)
		ds_patch_signals(sse, stats_json)
	}
}

// --- Stream route handlers ---

route_game_stream :: proc(sse: fio.SSE) {
	udata_raw := fio.sse_get_udata(sse)
	if udata_raw == nil {
		log.warn("SSE stream opened with no udata")
		fio.sse_close(sse)
		return
	}
	defer fio.free(udata_raw)

	ud := cast(^fio.SSE_Udata)udata_raw

	// Read suffix — game code, optionally followed by /json
	code_len := 0
	for code_len < len(ud.suffix) && ud.suffix[code_len] != 0 { code_len += 1 }
	suffix := string(ud.suffix[:code_len])

	if len(suffix) == 0 {
		route_lobby_stream(sse)
		return
	}

	if strings.has_prefix(suffix, "p/") {
		route_player_stream(sse, suffix[2:])
		return
	}

	is_json := strings.has_suffix(suffix, "/json")
	code := is_json ? suffix[:len(suffix) - 5] : suffix

	id, ok := game_id_from_code(code)
	if !ok {
		log.warnf("SSE stream: invalid game code '%s'", code)
		fio.sse_close(sse)
		return
	}

	if id not_in g.games {
		log.warnf("SSE stream: game %d not found", id)
		fio.sse_close(sse)
		return
	}

	pk, pk_ok := udata_pk(ud)
	game := &g.games[id]

	now := time.to_unix_nanoseconds(time.now())
	result := game_pair(game, pk, pk_ok, now)

	// Update in-memory names
	if pk_ok {
		name := db_get_player_name(pk)
		if pk == game.white_key && len(name) > 0 {
			delete(game.white_name, global_context.allocator)
			game.white_name = strings.clone(name, global_context.allocator)
		}
		if pk == game.black_key && len(name) > 0 {
			delete(game.black_name, global_context.allocator)
			game.black_name = strings.clone(name, global_context.allocator)
		}
	}

	viewer: chess.Player
	switch result {
	case .White_Connected, .White_Joined:
		viewer = .White
		log.infof(
			"Game %s: White %s (%.8s...)",
			code,
			result == .White_Joined ? "joined" : "connected",
			string(pk[:8]),
		)
	case .Black_Connected, .Black_Joined:
		viewer = .Black
		log.infof(
			"Game %s: Black %s (%.8s...)",
			code,
			result == .Black_Joined ? "joined" : "connected",
			string(pk[:8]),
		)
	case .Spectator:
		viewer = .None
		log.infof("Game %s: spectator connected (%.8s...)", code, string(pk[:8]))
	case .Anonymous:
		viewer = .None
		log.infof("Game %s: anonymous spectator connected", code)
	}

	channel := fmt.aprintf("game:%s", code)

	// Publish before subscribing so the joiner doesn't double-receive,
	// but the waiting player gets notified.
	if result == .White_Joined || result == .Black_Joined {
		fio.publish(raw_data(channel), u32(len(channel)), nil, 0)
		publish_lobby(id, .Add)
		publish_players(game, id, .Add)
	}

	udata := pack_sub({kind = .Game, id = u32(id), viewer = viewer, is_json = is_json})
	fio.sse_subscribe(sse, raw_data(channel), u32(len(channel)), udata)

	if is_json {
		json_data := game_json(game, viewer, now)
		sse_write_json(sse, json_data)
	} else {
		board_html, ok2 := render_board(game, viewer)
		if ok2 { ds_patch_el(sse, "#board", board_html) }
		ds_patch_signals(sse, game_signals(game, now))
	}
}

route_player_stream :: proc(sse: fio.SSE, player_code_suffix: string) {
	player_id, ok := player_id_from_code(player_code_suffix)
	if !ok {
		log.warnf("Player stream: invalid code '%s'", player_code_suffix)
		fio.sse_close(sse)
		return
	}

	channel := fmt.aprintf("player:%d", player_id)
	udata := pack_sub({kind = .Player, id = u32(player_id)})
	fio.sse_subscribe(sse, raw_data(channel), u32(len(channel)), udata)

	_, pk_ok := db_get_player_key(player_id)
	if !pk_ok {
		log.warnf("Player stream: no player for id %d", player_id)
		return
	}

	log.infof("Player stream opened for player %d", player_id)
}

route_lobby_stream :: proc(sse: fio.SSE) {
	log.info("Lobby stream opened")

	channel: string = "lobby"
	fio.sse_subscribe(sse, raw_data(channel), u32(len(channel)), nil)
}

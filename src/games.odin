package qckchs

import sa "core:container/small_array"
import "core:encoding/json"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:time"

import "chess"

// --- Result types ---

Move_Result :: enum {
	Ok,
	King_Captured,
	Stalemate,
	Timed_Out,
	Invalid_State,
	Wrong_Player,
	Illegal_Move,
}

Pair_Result :: enum {
	White_Connected,
	Black_Connected,
	White_Joined,
	Black_Joined,
	Spectator,
	Anonymous,
}

// --- Signals ---

Signal_Player :: struct {
	name:    string,
	code:    string `json:",omitempty"`,
	periods: u16,
}

Game_Signals :: struct {
	turn:    string,
	state:   string,
	white:   Signal_Player,
	black:   Signal_Player,
	result:  string,
	paired:  bool,
	ply:     int,
	max_ply: int `json:"maxPly"`,
}

effective_periods :: proc(clock: Clock, state: State, now: i64) -> (u16, u16) {
	if state not_in PLAYING_STATES {
		return clock.white_periods, clock.black_periods
	}
	elapsed_s := u16((now - clock.last_move_at) / i64(time.Second))
	burned := elapsed_s / PERIOD_SECONDS
	wp := clock.white_periods
	bp := clock.black_periods
	if state == .Turn_White {
		wp -= min(burned, wp)
	} else {
		bp -= min(burned, bp)
	}
	return wp, bp
}

game_signals :: proc(game: ^Game, now: i64) -> string {
	wp, bp := effective_periods(game.clock, game.state, now)
	ply := len(game.moves)
	sigs := Game_Signals {
		turn = turn_string(game.state),
		state = state_string(game.state),
		white = {name = game.white_name, periods = wp},
		black = {name = game.black_name, periods = bp},
		result = result_string(game.result),
		paired = game.white_key != EMPTY_KEY && game.black_key != EMPTY_KEY,
		ply = ply,
		max_ply = ply,
	}
	bytes, _ := json.marshal(sigs)
	return string(bytes)
}

//odinfmt: disable
result_string :: proc(result: Game_Result) -> string {
	switch result {
	case .White_By_Capture:     return "White wins by capture"
	case .Black_By_Capture:     return "Black wins by capture"
	case .White_By_Timeout:     return "White wins on time"
	case .Black_By_Timeout:     return "Black wins on time"
	case .White_By_Resignation: return "White wins by resignation"
	case .Black_By_Resignation: return "Black wins by resignation"
	case .Stalemate:            return "Draw — insufficient material"
	case .Draw_Repetition:      return "Draw — threefold repetition"
	case .Draw_No_Progress:     return "Draw — no progress"
	case .In_Progress:          return ""
	case:                       return ""
	}
}

turn_string :: proc(state: State) -> string {
	switch state {
	case .Turn_White:                     return "white"
	case .Turn_Black:                     return "black"
	case .Waiting, .Stalemate, .Resolved: return ""
	case:                                 return ""
	}
}

state_string :: proc(state: State) -> string {
	switch state {
	case .Waiting:                  return "waiting"
	case .Turn_White, .Turn_Black:  return "playing"
	case .Stalemate, .Resolved:     return "resolved"
	case:                           return ""
	}
}
//odinfmt: enable

// --- Game creation ---

parse_difficulty :: proc(s: string) -> (Difficulty, bool) {
	switch s {
	case "easy":
		return .Easy, true
	case "medium":
		return .Medium, true
	case "hard":
		return .Hard, true
	case:
		return .None, false
	}
}

create_game :: proc(pk: Player_Key) -> Game_Id {
	now := time.to_unix_nanoseconds(time.now())
	id := game_init(pk, now)

	game := &g.games[id]
	is_white := game.white_key == pk
	color := is_white ? "white" : "black"
	creator_key := is_white ? &game.white_key : &game.black_key
	log.infof("Game %d: creator is %s (%.8s...)", id, color, string(creator_key[:8]))

	return id
}

create_bot_game :: proc(pk: Player_Key, difficulty: Difficulty) -> Game_Id {
	now := time.to_unix_nanoseconds(time.now())
	id := game_init(pk, now)
	game := &g.games[id]
	game.difficulty = difficulty

	config := bot_for_difficulty(difficulty)

	if game.white_key == EMPTY_KEY {
		game.white_key = config.pk
		game.white_name = strings.clone(config.name, global_context.allocator)
	} else {
		game.black_key = config.pk
		game.black_name = strings.clone(config.name, global_context.allocator)
	}

	game.current_player = .White
	game.state = .Turn_White
	game.clock.last_move_at = now
	record_position(game)

	game.bot = spawn_bot(id, difficulty)
	if config.pk == game.white_key { notify_bot(game) }

	db_save(game)
	publish_lobby(id, .Add)

	color := game.white_key == pk ? "white" : "black"
	log.infof("Game %s: %v vs %s (creator is %s)", game.code, difficulty, config.name, color)

	return id
}

// --- Game logic ---

make_move :: proc(game: ^Game, from: u8, to: u8) -> (chess.Move, bool) {
	piece := game.board[from]

	if chess.piece_owner(piece) != game.current_player { return {}, false }
	if !chess.is_legal_move(game.board, from, to) { return {}, false }

	captured := game.board[to]
	king_captured := captured in chess.Kings

	move := chess.Move {
		piece   = piece,
		from    = from,
		to      = to,
		capture = captured != .X,
	}

	chess.apply_move(&game.board, move)
	append(&game.moves, move)
	game.current_player = game.current_player == .White ? .Black : .White

	return move, king_captured
}

game_init :: proc(pk: Player_Key, now: i64) -> Game_Id {
	g.last_id += 1
	id := g.last_id

	// creator slightly more likely to get white, because i said so
	white_key, black_key: Player_Key
	if rand.float64() >= 0.4 { white_key = pk } else { black_key = pk }

	board := chess.random_board()
	code := game_code(id, global_context.allocator)
	g.games[id] = {
		id             = id,
		code           = code,
		created_at     = now,
		board          = board,
		initial_board  = board,
		current_player = .None,
		clock          = {INITIAL_PERIODS, INITIAL_PERIODS, 0},
		state          = .Waiting,
		white_key      = white_key,
		black_key      = black_key,
		moves          = make([dynamic]chess.Move, 0, 30, global_context.allocator),
	}
	log.debugf("Game %d created (total active: %d)", id, len(g.games))
	db_save(&g.games[id])
	return id
}

game_free :: proc(game: ^Game) {
	kill_bot(game)
	delete(game.code, global_context.allocator)
	delete(game.moves)
	delete(game.white_name, global_context.allocator)
	delete(game.black_name, global_context.allocator)
	delete_key(&g.games, game.id)
}

apply_timeout :: proc(game: ^Game, now: i64) -> (timed_out: bool, wp: u16, bp: u16) {
	wp, bp = effective_periods(game.clock, game.state, now)
	active_is_white := game.state == .Turn_White
	if (active_is_white && wp == 0) || (!active_is_white && bp == 0) {
		game.clock.white_periods = wp
		game.clock.black_periods = bp
		game.state = .Resolved
		game.result = active_is_white ? .Black_By_Timeout : .White_By_Timeout
		db_save(game)
		timed_out = true
	}
	return
}

game_move :: proc(game: ^Game, pk: Player_Key, from, to: u8, now: i64) -> (chess.Move, Move_Result) {
	if game.state not_in PLAYING_STATES { return {}, .Invalid_State }
	if game.state == .Turn_White && pk != game.white_key { return {}, .Wrong_Player }
	if game.state == .Turn_Black && pk != game.black_key { return {}, .Wrong_Player }

	timed_out, wp, bp := apply_timeout(game, now)
	if timed_out { return {}, .Timed_Out }

	move, king_captured := make_move(game, from, to)
	if move.piece == .X { return {}, .Illegal_Move }

	game.clock.white_periods = wp
	game.clock.black_periods = bp

	is_progress := move.capture || move.piece in chess.Pawns
	if is_progress {
		game.no_progress_count = 0
		sa.clear(&game.position_hashes)
	} else {
		game.no_progress_count += 1
	}

	record_position(game)

	if king_captured {
		game.state = .Resolved
		game.result = game.current_player == .White ? .Black_By_Capture : .White_By_Capture
	} else if is_progress && chess.is_insufficient_material(game.board) {
		game.state = .Stalemate
		game.result = .Stalemate
	} else if chess.is_threefold_repetition(sa.slice(&game.position_hashes)) {
		game.state = .Stalemate
		game.result = .Draw_Repetition
	} else if game.no_progress_count >= chess.NO_PROGRESS_THRESHOLD {
		game.state = .Stalemate
		game.result = .Draw_No_Progress
	} else {
		game.state = game.current_player == .White ? .Turn_White : .Turn_Black
	}
	game.clock.last_move_at = now
	db_save(game)

	result: Move_Result
	if king_captured { result = .King_Captured } else if game.state == .Stalemate { result = .Stalemate } else { result = .Ok }
	return move, result
}

record_position :: proc(game: ^Game) {
	h := chess.board_hash(game.board, game.current_player)
	if sa.len(game.position_hashes) >= 50 { sa.pop_front(&game.position_hashes) }
	sa.push_back(&game.position_hashes, h)
}

game_pair :: proc(game: ^Game, pk: Player_Key, pk_ok: bool, now: i64) -> Pair_Result {
	if !pk_ok { return .Anonymous }
	if pk == game.white_key { return .White_Connected }
	if pk == game.black_key { return .Black_Connected }
	if game.white_key == EMPTY_KEY {
		game.white_key = pk
		db_save(game)
		return .White_Joined
	}
	if game.black_key == EMPTY_KEY {
		game.black_key = pk
		db_save(game)
		return .Black_Joined
	}
	return .Spectator
}

game_tick :: proc(game: ^Game, now: i64) -> Tick_Result {
	switch game.state {
	case .Waiting:
		timeout := game.difficulty != .None ? BOT_ABANDON_TIMEOUT : ABANDON_TIMEOUT
		if now - game.created_at >= timeout { return .Abandoned }
		can_start :=
			game.white_key != EMPTY_KEY &&
			game.black_key != EMPTY_KEY &&
			game.white_last_seen != 0 &&
			game.black_last_seen != 0 &&
			now - game.white_last_seen < PRESENCE_THRESHOLD &&
			now - game.black_last_seen < PRESENCE_THRESHOLD
		if can_start {
			game.state = .Turn_White
			game.current_player = .White
			game.clock.last_move_at = now
			record_position(game)
			db_save(game)
			return .Started
		}
	case .Turn_White, .Turn_Black:
		timed_out, _, _ := apply_timeout(game, now)
		if timed_out { return .Timed_Out }
	case .Stalemate, .Resolved:
		return .Cleanup
	}
	return .No_Change
}

// --- JSON representation ---

JSON_Player :: struct {
	periods: u16,
}

Game_JSON :: struct {
	state:  string,
	turn:   string,
	color:  string,
	board:  string,
	white:  JSON_Player,
	black:  JSON_Player,
	moves:  []string,
	result: string,
}

game_json :: proc(game: ^Game, viewer: chess.Player, now: i64) -> string {
	wp, bp := effective_periods(game.clock, game.state, now)

	color: string
	switch viewer {
	case .White:
		color = "white"
	case .Black:
		color = "black"
	case .None:
		color = "spectator"
	}

	data := Game_JSON {
		state = state_string(game.state),
		turn = turn_string(game.state),
		color = color,
		board = chess.board_string(game.board),
		white = {periods = wp},
		black = {periods = bp},
		moves = chess.moves_algebraic(game.initial_board, game.moves[:]),
		result = result_string(game.result),
	}
	bytes, _ := json.marshal(data)
	return string(bytes)
}

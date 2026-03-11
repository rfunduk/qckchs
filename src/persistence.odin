package qckchs

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import "core:time"
import sqlite "lib:sqlite3"

import "chess"

CHANNEL_CAPACITY :: 256

// --- Op types ---

Op_Save_Game :: struct {
	id:             Game_Id,
	white_key:      Player_Key,
	black_key:      Player_Key,
	result:         Game_Result,
	state:          State,
	current_player: chess.Player,
	board:          chess.Board,
	initial_board:  chess.Board,
	moves:          []chess.Move,
	white_periods:  u16,
	black_periods:  u16,
	created_at:     i64,
	last_move_at:   i64,
	difficulty:     Difficulty,
}

Op_Delete_Game :: struct {
	id: Game_Id,
}

Op_Claim_Player :: struct {
	key:  Player_Key,
	name: string,
}

DB_Op :: union {
	Op_Save_Game,
	Op_Delete_Game,
	Op_Claim_Player,
}

// --- Module state ---

db_conn: ^sqlite.DB
db_read: ^sqlite.DB
db_chan: chan.Chan(DB_Op)
db_thread: ^thread.Thread

// --- Public API ---

db_init :: proc() {
	status: sqlite.Status

	db_path_env, _ := os.lookup_env("DB_PATH")
	db_path := strings.clone_to_cstring(len(db_path_env) > 0 ? db_path_env : "qckchs.db")
	defer delete(db_path)

	db_conn, status = sqlite.open(db_path)
	if status != nil {
		log.errorf("Failed to open database: %v", sqlite.status_explain(status))
		return
	}

	sqlite.sql_exec(db_conn, "PRAGMA journal_mode=WAL")
	sqlite.sql_exec(db_conn, "PRAGMA foreign_keys=ON")
	sqlite.busy_timeout(db_conn, 5000)

	db_read, status = sqlite.open_readonly(db_path)
	if status != nil {
		log.errorf("Failed to open read-only database: %v", sqlite.status_explain(status))
		return
	}

	sqlite.sql_exec(
		db_conn,
		`
			CREATE TABLE IF NOT EXISTS players (
				id  INTEGER PRIMARY KEY AUTOINCREMENT,
				key BLOB NOT NULL UNIQUE
			)
		`,
	)
	sqlite.sql_exec(
		db_conn,
		`
			CREATE TABLE IF NOT EXISTS games (
				id             INTEGER PRIMARY KEY,
				white_id       INTEGER REFERENCES players(id),
				black_id       INTEGER REFERENCES players(id),
				result         INTEGER NOT NULL DEFAULT 0,
				state          INTEGER NOT NULL,
				current_player INTEGER NOT NULL,
				board          BLOB NOT NULL,
				initial_board  BLOB NOT NULL DEFAULT x'',
				moves          BLOB NOT NULL DEFAULT x'',
				white_periods  INTEGER NOT NULL,
				black_periods  INTEGER NOT NULL,
				created_at     INTEGER NOT NULL,
				last_move_at   INTEGER NOT NULL DEFAULT 0,
				updated_at     INTEGER NOT NULL,
				difficulty     INTEGER NOT NULL DEFAULT 0
			)
		`,
	)
	// Migrations
	sqlite.sql_exec(db_conn, `ALTER TABLE games ADD COLUMN difficulty INTEGER NOT NULL DEFAULT 0`)
	sqlite.sql_exec(db_conn, `ALTER TABLE players ADD COLUMN name TEXT NOT NULL DEFAULT ''`)
	sqlite.sql_exec(db_conn, `ALTER TABLE players ADD COLUMN claimed INTEGER NOT NULL DEFAULT 0`)

	db_load_games()

	Max_Row :: struct {
		max_id: i64,
	}
	row, ok := sqlite.sql_one(db_conn, "SELECT COALESCE(MAX(id), 0) FROM games", Max_Row)
	if ok && Game_Id(row.max_id) > g.last_id {
		g.last_id = Game_Id(row.max_id)
	}

	log.infof("DB: loaded %d in-progress games, last_id=%d", len(g.games), g.last_id)

	// Re-spawn bot threads for active bot games
	for id, &game in g.games {
		if game.difficulty == .None { continue }
		if game.state != .Turn_White && game.state != .Turn_Black { continue }
		config := bot_for_difficulty(game.difficulty)
		game.bot = spawn_bot(id, game.difficulty)
		log.infof("DB: re-spawned bot for game %d (%s)", id, config.name)
		notify_bot(&game)
	}

	err: mem.Allocator_Error
	db_chan, err = chan.create(chan.Chan(DB_Op), CHANNEL_CAPACITY, global_context.allocator)
	if err != nil {
		log.errorf("Failed to create DB channel: %v", err)
		return
	}

	// Don't pass global_context — the DB worker must NOT use the tracking
	// allocator (not thread-safe). It inherits default heap allocator and
	// sets just the logger in db_worker.
	db_thread = thread.create_and_start(db_worker)
}

db_shutdown :: proc() {
	if db_chan.impl != nil {
		chan.close(db_chan)
		if db_thread != nil {
			thread.join(db_thread)
			thread.destroy(db_thread)
		}
		chan.destroy(db_chan)
	}
	if db_read != nil { sqlite.close(db_read) }
	if db_conn != nil { sqlite.close(db_conn) }
}

db_delete :: proc(id: Game_Id) {
	if db_chan.impl == nil { return }
	chan.send(db_chan, DB_Op(Op_Delete_Game{id = id}))
}

db_save :: proc(game: ^Game) {
	if db_chan.impl == nil { return }

	cloned_moves: []chess.Move
	if len(game.moves) > 0 {
		cloned_moves = make([]chess.Move, len(game.moves), runtime.default_allocator())
		copy(cloned_moves, game.moves[:])
	}

	op := Op_Save_Game {
		id             = game.id,
		white_key      = game.white_key,
		black_key      = game.black_key,
		result         = game.result,
		state          = game.state,
		current_player = game.current_player,
		board          = game.board,
		initial_board  = game.initial_board,
		moves          = cloned_moves,
		white_periods  = game.clock.white_periods,
		black_periods  = game.clock.black_periods,
		created_at     = game.created_at,
		last_move_at   = game.clock.last_move_at,
		difficulty     = game.difficulty,
	}

	chan.send(db_chan, DB_Op(op))
}

// --- Worker ---

db_worker :: proc() {
	context.logger = global_context.logger
	for {
		op, ok := chan.recv(db_chan)
		if !ok { break }
		db_process_op(op)
	}
	// Drain remaining
	for {
		op, ok := chan.try_recv(db_chan)
		if !ok { break }
		db_process_op(op)
	}
	log.info("DB worker exiting")
}

db_process_op :: proc(op: DB_Op) {
	switch v in op {
	case Op_Save_Game:
		db_save_game(v)
		if len(v.moves) > 0 {
			delete(v.moves, runtime.default_allocator())
		}
	case Op_Delete_Game:
		db_delete_game(v.id)
	case Op_Claim_Player:
		db_claim_player_exec(v)
		if len(v.name) > 0 {
			delete(v.name, runtime.default_allocator())
		}
	}
}

// --- DB operations ---

db_claim_player :: proc(key: Player_Key, name: string) {
	if key == EMPTY_KEY { return }
	if db_chan.impl == nil { return }
	chan.send(
		db_chan,
		DB_Op(Op_Claim_Player{key = key, name = strings.clone(name, runtime.default_allocator())}),
	)
}

db_claim_player_exec :: proc(op: Op_Claim_Player) {
	sqlite.sql_exec(
		db_conn,
		`INSERT INTO players (key, name, claimed) VALUES (?, ?, 1)
		 ON CONFLICT(key) DO UPDATE SET name = excluded.name, claimed = 1`,
		op.key,
		op.name,
	)
}

db_get_player_name :: proc(key: Player_Key) -> string {
	if key == EMPTY_KEY { return "" }
	Name_Row :: struct {
		name: string,
	}
	row, ok := sqlite.sql_one(db_read, "SELECT name FROM players WHERE key = ?", Name_Row, key)
	if !ok { return "" }
	return row.name
}

db_is_player_claimed :: proc(key: Player_Key) -> bool {
	if key == EMPTY_KEY { return false }
	Claimed_Row :: struct {
		claimed: i64,
	}
	row, ok := sqlite.sql_one(db_read, "SELECT claimed FROM players WHERE key = ?", Claimed_Row, key)
	if !ok { return false }
	return row.claimed != 0
}

Player_Stats :: struct {
	played: i64,
	wins:   i64,
	losses: i64,
	draws:  i64,
}

db_get_player_stats :: proc(key: Player_Key) -> Player_Stats {
	if key == EMPTY_KEY { return {} }
	w := fmt.tprintf(
		"(%d,%d,%d)",
		Game_Result.White_By_Capture,
		Game_Result.White_By_Resignation,
		Game_Result.White_By_Timeout,
	)
	b := fmt.tprintf(
		"(%d,%d,%d)",
		Game_Result.Black_By_Capture,
		Game_Result.Black_By_Resignation,
		Game_Result.Black_By_Timeout,
	)
	d := fmt.tprintf(
		"(%d,%d,%d)",
		Game_Result.Stalemate,
		Game_Result.Draw_Repetition,
		Game_Result.Draw_No_Progress,
	)
	row, ok := sqlite.sql_one(
		db_read,
		fmt.tprintf(
			`
			SELECT
				COUNT(*) as played,
				COALESCE(SUM(CASE WHEN (g.white_id=p.id AND g.result IN %s)
					OR (g.black_id=p.id AND g.result IN %s) THEN 1 ELSE 0 END), 0) as wins,
				COALESCE(SUM(CASE WHEN (g.white_id=p.id AND g.result IN %s)
					OR (g.black_id=p.id AND g.result IN %s) THEN 1 ELSE 0 END), 0) as losses,
				COALESCE(SUM(CASE WHEN g.result IN %s THEN 1 ELSE 0 END), 0) as draws
			FROM games g JOIN players p ON (g.white_id=p.id OR g.black_id=p.id)
			WHERE p.key = ? AND g.result != 0
		`,
			w,
			b,
			b,
			w,
			d,
		),
		Player_Stats,
		key,
	)
	if !ok { return {} }
	return row
}

db_save_game :: proc(op: Op_Save_Game) {
	// Use db_conn (write connection) since this runs on the DB worker thread.
	// db_read is owned by the event loop thread and is not thread-safe.
	white_id, has_white := db_get_player_id(op.white_key, db_conn)
	black_id, has_black := db_get_player_id(op.black_key, db_conn)

	// Pack moves: 4 bytes per move (piece, from, to, capture)
	moves_buf: [dynamic]u8
	defer delete(moves_buf)
	for m in op.moves {
		append(&moves_buf, u8(m.piece), m.from, m.to, m.capture ? 1 : 0)
	}
	moves_bytes := moves_buf[:]

	now := time.to_unix_nanoseconds(time.now())

	// Nullable player IDs: uninitialized `any` is nil
	white_id_any: any
	if has_white { white_id_any = white_id }
	black_id_any: any
	if has_black { black_id_any = black_id }

	board_bytes := transmute([size_of(chess.Board)]u8)op.board
	initial_board_bytes := transmute([size_of(chess.Board)]u8)op.initial_board

	status := sqlite.sql_exec(
		db_conn,
		`
			INSERT OR REPLACE INTO games (
				id, white_id, black_id, result, state, current_player,
				board, initial_board, moves, white_periods, black_periods,
				created_at, last_move_at, updated_at, difficulty
			)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`,
		i64(op.id),
		white_id_any,
		black_id_any,
		i64(op.result),
		i64(op.state),
		i64(op.current_player),
		board_bytes,
		initial_board_bytes,
		moves_bytes,
		i64(op.white_periods),
		i64(op.black_periods),
		op.created_at,
		op.last_move_at,
		now,
		i64(op.difficulty),
	)
	if status != nil {
		log.errorf("DB: failed to save game %d: %v", op.id, sqlite.status_explain(status))
	}
}

db_delete_game :: proc(id: Game_Id) {
	status := sqlite.sql_exec(db_conn, "DELETE FROM games WHERE id = ?", i64(id))
	if status != nil {
		log.errorf("DB: failed to delete game %d: %v", id, sqlite.status_explain(status))
	}
}

db_get_player_games :: proc(key: Player_Key) -> []Mini_Game_Data {
	if db_read == nil { return {} }

	query, status := sqlite.sql_bind(
		db_read,
		`
			SELECT g.id, g.board, wp.name, bp.name, g.result,
				CASE WHEN g.black_id = p.id THEN 1 ELSE 0 END
			FROM games g
			JOIN players p ON (g.white_id=p.id OR g.black_id=p.id)
			LEFT JOIN players wp ON g.white_id = wp.id
			LEFT JOIN players bp ON g.black_id = bp.id
			WHERE p.key = ? AND g.result != 0
			ORDER BY g.id DESC
		`,
		key,
	)
	if status != nil {
		log.errorf("DB: failed to query player games: %v", sqlite.status_explain(status))
		return {}
	}
	defer sqlite.finalize(query)

	results: [dynamic]Mini_Game_Data
	for {
		step := sqlite.step(query)
		if step != .Row { break }

		board: chess.Board
		board_len := int(sqlite.column_bytes(query, 1))
		board_ptr := sqlite.column_blob(query, 1)
		if board_ptr != nil && board_len == size_of(chess.Board) {
			mem.copy(&board, board_ptr, board_len)
		}

		is_black := sqlite.column_int64(query, 5) != 0

		result := Game_Result(sqlite.column_int64(query, 4))
		wn := strings.clone_from_cstring(sqlite.column_text(query, 2))
		bn := strings.clone_from_cstring(sqlite.column_text(query, 3))
		w_win := result in White_Wins
		b_win := result in Black_Wins
		append(
			&results,
			Mini_Game_Data {
				code = game_code(Game_Id(sqlite.column_int64(query, 0))),
				squares = build_mini_squares(board, is_black),
				wn = is_black ? bn : wn,
				bn = is_black ? wn : bn,
				w_win = is_black ? b_win : w_win,
				b_win = is_black ? w_win : b_win,
			},
		)
	}
	return results[:]
}

// --- Loading ---

db_load_finished_game :: proc(id: Game_Id) -> (Game, bool) {
	if db_read == nil { return {}, false }

	query, status := sqlite.sql_bind(
		db_read,
		`
			SELECT
				g.id, g.result, g.state, g.current_player,
				g.board, g.initial_board, g.moves,
				g.white_periods, g.black_periods, g.created_at, g.last_move_at,
				wp.key, bp.key, wp.name, bp.name
			FROM games g
			LEFT JOIN players wp ON g.white_id = wp.id
			LEFT JOIN players bp ON g.black_id = bp.id
			WHERE g.id = ?
		`,
		i64(id),
	)
	if status != nil {
		log.errorf("DB: failed to query finished game %d: %v", id, sqlite.status_explain(status))
		return {}, false
	}
	defer sqlite.finalize(query)

	step := sqlite.step(query)
	if step != .Row { return {}, false }

	result := Game_Result(sqlite.column_int64(query, 1))
	state := State(sqlite.column_int64(query, 2))
	current_player := chess.Player(sqlite.column_int64(query, 3))

	board: chess.Board
	board_len := int(sqlite.column_bytes(query, 4))
	board_ptr := sqlite.column_blob(query, 4)
	if board_ptr != nil && board_len == size_of(chess.Board) {
		mem.copy(&board, board_ptr, board_len)
	}

	initial_board: chess.Board
	ib_len := int(sqlite.column_bytes(query, 5))
	ib_ptr := sqlite.column_blob(query, 5)
	if ib_ptr != nil && ib_len == size_of(chess.Board) {
		mem.copy(&initial_board, ib_ptr, ib_len)
	}

	moves_len := int(sqlite.column_bytes(query, 6))
	moves_ptr := sqlite.column_blob(query, 6)
	moves: [dynamic]chess.Move
	if moves_ptr != nil && moves_len > 0 {
		raw := (cast([^]u8)moves_ptr)[:moves_len]
		for i := 0; i + 3 < moves_len; i += 4 {
			append(
				&moves,
				chess.Move {
					piece = chess.Piece(raw[i]),
					from = raw[i + 1],
					to = raw[i + 2],
					capture = raw[i + 3] != 0,
				},
			)
		}
	}

	white_periods := u16(sqlite.column_int64(query, 7))
	black_periods := u16(sqlite.column_int64(query, 8))
	created_at := sqlite.column_int64(query, 9)
	last_move_at := sqlite.column_int64(query, 10)

	white_key: Player_Key
	wk_len := int(sqlite.column_bytes(query, 11))
	wk_ptr := sqlite.column_blob(query, 11)
	if wk_ptr != nil && wk_len == 32 {
		mem.copy(&white_key, wk_ptr, 32)
	}

	black_key: Player_Key
	bk_len := int(sqlite.column_bytes(query, 12))
	bk_ptr := sqlite.column_blob(query, 12)
	if bk_ptr != nil && bk_len == 32 {
		mem.copy(&black_key, bk_ptr, 32)
	}

	white_name := strings.clone_from_cstring(sqlite.column_text(query, 13))
	black_name := strings.clone_from_cstring(sqlite.column_text(query, 14))

	return Game {
			id = id,
			created_at = created_at,
			board = board,
			initial_board = initial_board,
			current_player = current_player,
			clock = {white_periods, black_periods, last_move_at},
			state = state,
			result = result,
			moves = moves,
			white_key = white_key,
			black_key = black_key,
			white_name = white_name,
			black_name = black_name,
		},
		true
}

db_load_games :: proc() {
	query, status := sqlite.sql_bind(
		db_conn,
		`
			SELECT
				g.id, g.result, g.state, g.current_player,
				g.board, g.initial_board, g.moves,
				g.white_periods, g.black_periods, g.created_at, g.last_move_at,
				wp.key, bp.key, g.difficulty, wp.name, bp.name
			FROM games g
			LEFT JOIN players wp ON g.white_id = wp.id
			LEFT JOIN players bp ON g.black_id = bp.id
			WHERE g.result = 0
		`,
	)
	if status != nil {
		log.errorf("DB: failed to query games: %v", sqlite.status_explain(status))
		return
	}
	defer sqlite.finalize(query)

	for {
		step := sqlite.step(query)
		if step == .Done { break }
		if step != .Row {
			log.errorf("DB: step error loading games: %v", sqlite.status_explain(step))
			break
		}

		id := Game_Id(sqlite.column_int64(query, 0))
		result := Game_Result(sqlite.column_int64(query, 1))
		state := State(sqlite.column_int64(query, 2))
		current_player := chess.Player(sqlite.column_int64(query, 3))

		board: chess.Board
		board_len := int(sqlite.column_bytes(query, 4))
		board_ptr := sqlite.column_blob(query, 4)
		if board_ptr != nil && board_len == size_of(chess.Board) {
			mem.copy(&board, board_ptr, board_len)
		}

		initial_board: chess.Board
		ib_len := int(sqlite.column_bytes(query, 5))
		ib_ptr := sqlite.column_blob(query, 5)
		if ib_ptr != nil && ib_len == size_of(chess.Board) {
			mem.copy(&initial_board, ib_ptr, ib_len)
		}

		// Moves blob (4 bytes per move)
		moves_len := int(sqlite.column_bytes(query, 6))
		moves_ptr := sqlite.column_blob(query, 6)
		moves := make([dynamic]chess.Move, 0, max(moves_len / 4, 1), global_context.allocator)
		if moves_ptr != nil && moves_len > 0 {
			raw := (cast([^]u8)moves_ptr)[:moves_len]
			for i := 0; i + 3 < moves_len; i += 4 {
				append(
					&moves,
					chess.Move {
						piece = chess.Piece(raw[i]),
						from = raw[i + 1],
						to = raw[i + 2],
						capture = raw[i + 3] != 0,
					},
				)
			}
		}

		white_periods := u16(sqlite.column_int64(query, 7))
		black_periods := u16(sqlite.column_int64(query, 8))
		created_at := sqlite.column_int64(query, 9)
		last_move_at := sqlite.column_int64(query, 10)

		// Player keys (32-byte BLOBs, may be NULL from LEFT JOIN)
		white_key: Player_Key
		wk_len := int(sqlite.column_bytes(query, 11))
		wk_ptr := sqlite.column_blob(query, 11)
		if wk_ptr != nil && wk_len == 32 {
			mem.copy(&white_key, wk_ptr, 32)
		}

		black_key: Player_Key
		bk_len := int(sqlite.column_bytes(query, 12))
		bk_ptr := sqlite.column_blob(query, 12)
		if bk_ptr != nil && bk_len == 32 {
			mem.copy(&black_key, bk_ptr, 32)
		}

		difficulty := Difficulty(sqlite.column_int64(query, 13))
		white_name := strings.clone_from_cstring(sqlite.column_text(query, 14), global_context.allocator)
		black_name := strings.clone_from_cstring(sqlite.column_text(query, 15), global_context.allocator)

		g.games[id] = Game {
			id             = id,
			created_at     = created_at,
			board          = board,
			initial_board  = initial_board,
			current_player = current_player,
			clock          = {white_periods, black_periods, last_move_at},
			state          = state,
			result         = result,
			moves          = moves,
			white_key      = white_key,
			black_key      = black_key,
			difficulty     = difficulty,
			white_name     = white_name,
			black_name     = black_name,
		}

		log.debugf(
			"DB: loaded game %d (state=%v, moves=%d, difficulty=%v)",
			id,
			state,
			len(moves),
			difficulty,
		)
	}
}

db_get_player_id :: proc(key: Player_Key, db: ^sqlite.DB = nil) -> (i64, bool) {
	if key == EMPTY_KEY { return 0, false }
	Id_Row :: struct {
		id: i64,
	}
	conn := db != nil ? db : db_read
	row, ok := sqlite.sql_one(conn, "SELECT id FROM players WHERE key = ?", Id_Row, key)
	if !ok { return 0, false }
	return row.id, true
}

db_get_player_key :: proc(player_id: i64) -> (Player_Key, bool) {
	query, status := sqlite.sql_bind(db_read, "SELECT key FROM players WHERE id = ?", player_id)
	if status != nil { return {}, false }
	defer sqlite.finalize(query)

	step := sqlite.step(query)
	if step != .Row { return {}, false }

	pk: Player_Key
	pk_len := int(sqlite.column_bytes(query, 0))
	pk_ptr := sqlite.column_blob(query, 0)
	if pk_ptr == nil || pk_len != 32 { return {}, false }
	mem.copy(&pk, pk_ptr, 32)
	return pk, true
}

db_get_player_stats_by_id :: proc(player_id: i64) -> Player_Stats {
	pk, ok := db_get_player_key(player_id)
	if !ok { return {} }
	return db_get_player_stats(pk)
}

Draws :: bit_set[Game_Result]{.Stalemate, .Draw_Repetition, .Draw_No_Progress}

calc_player_stats :: proc(player_id: i64, result: Game_Result, is_white: bool) -> Player_Stats {
	stats := db_get_player_stats_by_id(player_id)
	stats.played += 1
	if result in White_Wins {
		if is_white { stats.wins += 1 } else { stats.losses += 1 }
	} else if result in Black_Wins {
		if !is_white { stats.wins += 1 } else { stats.losses += 1 }
	} else if result in Draws {
		stats.draws += 1
	}
	return stats
}

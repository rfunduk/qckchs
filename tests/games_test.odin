package tests

import "base:runtime"

import "core:strings"

import src "../src"
import chess "../src/chess"
import t "core:testing"
import "core:time"

@(init)
global_context_setup :: proc "contextless" () {
	context = runtime.default_context()
	src.global_context = context
}

// --- Test constants ---

NS :: i64(time.Second)
T0: i64 : 1000 * NS // arbitrary base timestamp for tests

// --- Helpers ---

make_key :: proc(b: u8) -> src.Player_Key {
	key: src.Player_Key
	for &c in key { c = b }
	return key
}

make_active_game :: proc() -> src.Game {
	return src.Game {
		board = TEST_BOARD,
		initial_board = TEST_BOARD,
		current_player = .White,
		state = .Turn_White,
		white_key = make_key('W'),
		black_key = make_key('B'),
		clock = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0},
		moves = make([dynamic]chess.Move, 0, 30),
	}
}

make_waiting_game :: proc() -> src.Game {
	return src.Game {
		board = TEST_BOARD,
		initial_board = TEST_BOARD,
		state = .Waiting,
		created_at = T0,
		white_key = make_key('W'),
		clock = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, 0},
		moves = make([dynamic]chess.Move, 0, 30),
	}
}

make_waiting_game_black_creator :: proc() -> src.Game {
	return src.Game {
		board = TEST_BOARD,
		initial_board = TEST_BOARD,
		state = .Waiting,
		created_at = T0,
		black_key = make_key('B'),
		clock = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, 0},
		moves = make([dynamic]chess.Move, 0, 30),
	}
}

// --- game_init ---

@(test)
test_game_init_assigns_one_key :: proc(test: ^t.T) {
	pk := make_key('W')
	id := src.game_init(pk, T0)
	game := src.g.games[id]
	has_white := game.white_key == pk
	has_black := game.black_key == pk
	t.expect(test, has_white || has_black, "pk must be assigned to white or black")
	t.expect(test, !(has_white && has_black), "pk must not be assigned to both")
	other := has_white ? game.black_key : game.white_key
	t.expect_value(test, other, src.EMPTY_KEY)
	t.expect_value(test, game.state, src.State.Waiting)
	t.expect_value(test, game.current_player, chess.Player.None)
	t.expect_value(test, game.created_at, T0)
	delete(game.moves)
}

// --- game_move ---

@(test)
test_game_move_ok :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	move, result := src.game_move(&game, make_key('W'), 22, 17, T0)
	t.expect_value(test, result, src.Move_Result.Ok)
	t.expect_value(test, move.piece, chess.Piece.WP)
	t.expect_value(test, game.state, src.State.Turn_Black)
	t.expect_value(test, game.clock.last_move_at, T0)
}

@(test)
test_game_move_king_captured :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WQ
	board[7] = .BK
	game := src.Game {
		board          = board,
		current_player = .White,
		state          = .Turn_White,
		white_key      = make_key('W'),
		black_key      = make_key('B'),
		clock          = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0},
		moves          = make([dynamic]chess.Move, 0, 30),
	}
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 12, 7, T0)
	t.expect_value(test, result, src.Move_Result.King_Captured)
	t.expect_value(test, game.state, src.State.Resolved)
}

@(test)
test_game_move_invalid_state_waiting :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 22, 17, T0)
	t.expect_value(test, result, src.Move_Result.Invalid_State)
}

@(test)
test_game_move_invalid_state_resolved :: proc(test: ^t.T) {
	game := make_active_game()
	game.state = .Resolved
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 22, 17, T0)
	t.expect_value(test, result, src.Move_Result.Invalid_State)
}

@(test)
test_game_move_wrong_player :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('B'), 22, 17, T0) // Black's key on White's turn
	t.expect_value(test, result, src.Move_Result.Wrong_Player)
	t.expect_value(test, game.state, src.State.Turn_White) // unchanged
}

@(test)
test_game_move_illegal_move :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 22, 12, T0) // WP two squares — illegal
	t.expect_value(test, result, src.Move_Result.Illegal_Move)
}

// --- game_pair ---

@(test)
test_game_pair_white_connected :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	result := src.game_pair(&game, make_key('W'), true, T0)
	t.expect_value(test, result, src.Pair_Result.White_Connected)
	t.expect_value(test, game.state, src.State.Waiting) // unchanged
}

@(test)
test_game_pair_black_joined :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	black_key := make_key('B')
	result := src.game_pair(&game, black_key, true, T0)
	t.expect_value(test, result, src.Pair_Result.Black_Joined)
	t.expect_value(test, game.state, src.State.Waiting) // stays waiting until presence confirmed
	t.expect_value(test, game.current_player, chess.Player.None)
	t.expect_value(test, game.black_key, black_key)
	t.expect_value(test, game.clock.last_move_at, i64(0))
}

@(test)
test_game_pair_black_connected :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	result := src.game_pair(&game, make_key('B'), true, T0)
	t.expect_value(test, result, src.Pair_Result.Black_Connected)
}

@(test)
test_game_pair_spectator :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	result := src.game_pair(&game, make_key('X'), true, T0)
	t.expect_value(test, result, src.Pair_Result.Spectator)
}

@(test)
test_game_pair_anonymous :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	result := src.game_pair(&game, {}, false, T0)
	t.expect_value(test, result, src.Pair_Result.Anonymous)
	t.expect_value(test, game.state, src.State.Waiting) // unchanged
}

@(test)
test_game_pair_creator_is_black :: proc(test: ^t.T) {
	game := make_waiting_game_black_creator()
	defer delete(game.moves)

	// Creator reconnects as black
	result := src.game_pair(&game, make_key('B'), true, T0)
	t.expect_value(test, result, src.Pair_Result.Black_Connected)
	t.expect_value(test, game.state, src.State.Waiting) // still waiting

	// Opponent joins the empty white slot
	white_key := make_key('W')
	result2 := src.game_pair(&game, white_key, true, T0)
	t.expect_value(test, result2, src.Pair_Result.White_Joined)
	t.expect_value(test, game.state, src.State.Waiting) // stays waiting until presence confirmed
	t.expect_value(test, game.white_key, white_key)
	t.expect_value(test, game.clock.last_move_at, i64(0))
}

// --- effective_periods ---

@(test)
test_effective_periods_white_turn :: proc(test: ^t.T) {
	clock := src.Clock{src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0}
	wp, bp := src.effective_periods(clock, .Turn_White, T0 + 3 * NS)
	t.expect_value(test, wp, u16(src.INITIAL_PERIODS - 3))
	t.expect_value(test, bp, u16(src.INITIAL_PERIODS)) // unchanged
}

@(test)
test_effective_periods_black_turn :: proc(test: ^t.T) {
	clock := src.Clock{src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0}
	wp, bp := src.effective_periods(clock, .Turn_Black, T0 + 3 * NS)
	t.expect_value(test, wp, u16(src.INITIAL_PERIODS)) // unchanged
	t.expect_value(test, bp, u16(src.INITIAL_PERIODS - 3))
}

@(test)
test_effective_periods_not_playing :: proc(test: ^t.T) {
	clock := src.Clock{25, 20, T0}

	wp, bp := src.effective_periods(clock, .Waiting, T0 + 100 * NS)
	t.expect_value(test, wp, u16(25))
	t.expect_value(test, bp, u16(20))

	wp2, bp2 := src.effective_periods(clock, .Resolved, T0 + 100 * NS)
	t.expect_value(test, wp2, u16(25))
	t.expect_value(test, bp2, u16(20))
}

// --- game_move timer tests ---

@(test)
test_game_move_burns_periods :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 22, 17, T0 + 3 * NS)
	t.expect_value(test, result, src.Move_Result.Ok)
	t.expect_value(test, game.clock.white_periods, u16(src.INITIAL_PERIODS - 3))
	t.expect_value(test, game.clock.black_periods, u16(src.INITIAL_PERIODS)) // unchanged
}

@(test)
test_game_move_fast_no_burn :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 22, 17, T0 + NS / 2) // 0.5s
	t.expect_value(test, result, src.Move_Result.Ok)
	t.expect_value(test, game.clock.white_periods, u16(src.INITIAL_PERIODS)) // no burn
}

@(test)
test_game_move_timeout_before_move :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	_, result := src.game_move(&game, make_key('W'), 22, 17, T0 + i64(src.INITIAL_PERIODS + 1) * NS)
	t.expect_value(test, result, src.Move_Result.Timed_Out)
	t.expect_value(test, game.state, src.State.Resolved)
	t.expect_value(test, game.result, src.Game_Result.Black_By_Timeout)
	t.expect_value(test, game.clock.white_periods, u16(0))
}

// --- game_tick tests ---

@(test)
test_game_tick_timeout_white :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	result := src.game_tick(&game, T0 + i64(src.INITIAL_PERIODS + 1) * NS)
	t.expect_value(test, result, src.Tick_Result.Timed_Out)
	t.expect_value(test, game.state, src.State.Resolved)
	t.expect_value(test, game.result, src.Game_Result.Black_By_Timeout)
}

@(test)
test_game_tick_timeout_black :: proc(test: ^t.T) {
	game := make_active_game()
	game.state = .Turn_Black
	game.current_player = .Black
	defer delete(game.moves)

	result := src.game_tick(&game, T0 + i64(src.INITIAL_PERIODS + 1) * NS)
	t.expect_value(test, result, src.Tick_Result.Timed_Out)
	t.expect_value(test, game.state, src.State.Resolved)
	t.expect_value(test, game.result, src.Game_Result.White_By_Timeout)
}

@(test)
test_game_tick_no_timeout :: proc(test: ^t.T) {
	game := make_active_game()
	defer delete(game.moves)

	result := src.game_tick(&game, T0 + NS / 2) // 0.5s
	t.expect_value(test, result, src.Tick_Result.No_Change)
	t.expect_value(test, game.state, src.State.Turn_White) // unchanged
}

@(test)
test_game_tick_abandon_waiting :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	result := src.game_tick(&game, T0 + src.ABANDON_TIMEOUT)
	t.expect_value(test, result, src.Tick_Result.Abandoned)
}

@(test)
test_game_tick_waiting_not_abandoned :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	result := src.game_tick(&game, T0 + src.ABANDON_TIMEOUT - 1)
	t.expect_value(test, result, src.Tick_Result.No_Change)
}

@(test)
test_game_tick_cleanup_resolved :: proc(test: ^t.T) {
	game := make_active_game()
	game.state = .Resolved
	defer delete(game.moves)

	result := src.game_tick(&game, T0)
	t.expect_value(test, result, src.Tick_Result.Cleanup)
}

@(test)
test_game_tick_starts_when_both_present :: proc(test: ^t.T) {
	game := make_waiting_game()
	defer delete(game.moves)

	// Second player joins — game stays Waiting
	src.game_pair(&game, make_key('B'), true, T0)
	t.expect_value(test, game.state, src.State.Waiting)

	// Both players ping (presence confirmed)
	game.white_last_seen = T0
	game.black_last_seen = T0

	// Tick detects both present → starts the game
	result := src.game_tick(&game, T0)
	t.expect_value(test, result, src.Tick_Result.Started)
	t.expect_value(test, game.state, src.State.Turn_White)
	t.expect_value(test, game.current_player, chess.Player.White)
	t.expect_value(test, game.clock.last_move_at, T0)
}

// --- board_string ---

@(test)
test_board_string_initial :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s := src.board_string(TEST_BOARD)
	t.expect_value(test, s, "rbqknpppppxxxxxxxxxxPPPPPRBQKN")
}

@(test)
test_board_string_empty :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	s := src.board_string(empty_board())
	t.expect_value(test, s, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
}

// --- move_algebraic ---

@(test)
test_move_algebraic_pawn_forward :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// WP at c2 (index 22) moves to c3 (index 17)
	s := src.move_algebraic(TEST_BOARD, chess.Move{piece = .WP, from = 22, to = 17})
	t.expect_value(test, s, "c3")
}

@(test)
test_move_algebraic_pawn_capture :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	board := empty_board()
	board[22] = .WP
	board[16] = .BN
	s := src.move_algebraic(board, chess.Move{piece = .WP, from = 22, to = 16, capture = true})
	t.expect_value(test, s, "cxb3")
}

@(test)
test_move_algebraic_knight :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	board := empty_board()
	board[29] = .WN
	s := src.move_algebraic(board, chess.Move{piece = .WN, from = 29, to = 18})
	t.expect_value(test, s, "Nd3")
}

@(test)
test_move_algebraic_knight_disambiguation :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	board := empty_board()
	board[1] = .WN // b6
	board[9] = .WN // e5
	// Both can reach c4 (index 12): b6→c4 and e5→c4
	s := src.move_algebraic(board, chess.Move{piece = .WN, from = 1, to = 12})
	t.expect_value(test, s, "Nbc4")
}

@(test)
test_move_algebraic_promotion :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	board := empty_board()
	board[6] = .WP // b5, one step from black's back rank
	s := src.move_algebraic(board, chess.Move{piece = .WP, from = 6, to = 1})
	t.expect_value(test, s, "b6=Q")
}

@(test)
test_move_algebraic_queen :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	board := empty_board()
	board[12] = .WQ
	board[7] = .BK
	s := src.move_algebraic(board, chess.Move{piece = .WQ, from = 12, to = 7, capture = true})
	t.expect_value(test, s, "Qxc5")
}

// --- moves_algebraic ---

@(test)
test_moves_algebraic_empty :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	result := src.moves_algebraic(TEST_BOARD, nil)
	t.expect_value(test, len(result), 0)
}

@(test)
test_moves_algebraic_sequence :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	// 1. c3 c4
	moves := []chess.Move{{piece = .WP, from = 22, to = 17}, {piece = .BP, from = 7, to = 12}}
	result := src.moves_algebraic(TEST_BOARD, moves)
	t.expect_value(test, len(result), 2)
	t.expect_value(test, result[0], "c3")
	t.expect_value(test, result[1], "c4")
}

// --- game_json ---

@(test)
test_game_json_waiting :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	game := make_waiting_game()
	defer delete(game.moves)

	s := src.game_json(&game, .White, T0)
	t.expect(test, len(s) > 0, "game_json should produce output")
	// Verify it contains expected fields
	t.expect(test, strings.contains(s, `"state":"waiting"`))
	t.expect(test, strings.contains(s, `"color":"white"`))
	t.expect(test, strings.contains(s, `"board":"rbqknpppppxxxxxxxxxxPPPPPRBQKN"`))
}

@(test)
test_game_json_playing :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	game := make_active_game()
	defer delete(game.moves)

	s := src.game_json(&game, .Black, T0)
	t.expect(test, strings.contains(s, `"state":"playing"`))
	t.expect(test, strings.contains(s, `"turn":"white"`))
	t.expect(test, strings.contains(s, `"color":"black"`))
}

// --- Draw rules ---

@(test)
test_draw_threefold_repetition :: proc(test: ^t.T) {
	// Set up a position where knights can shuffle back and forth
	board := empty_board()
	board[3] = .WK
	board[18] = .WN
	board[26] = .BK
	board[11] = .BN

	game := src.Game {
		board          = board,
		initial_board  = board,
		current_player = .White,
		state          = .Turn_White,
		white_key      = make_key('W'),
		black_key      = make_key('B'),
		clock          = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0},
		moves          = make([dynamic]chess.Move, 0, 30),
	}
	defer delete(game.moves)

	// Record initial position
	src.record_position(&game)

	// WN: 18 → 7 → 18 → 7 → 18 (triangulate back to same position)
	// BN: 11 → 22 → 11 → 22 → 11
	// After full cycles, the original position recurs
	moves := [][2]u8 {
		{18, 7}, // W: Nc5
		{11, 22}, // B: Nc2
		{7, 18}, // W: Nd3 (position repeats — 2nd time)
		{22, 11}, // B: Nb4 (position repeats — 2nd time)
		{18, 7}, // W: Nc5
		{11, 22}, // B: Nc2
		{7, 18}, // W: Nd3 (position repeats — 3rd time)
		{22, 11}, // B: Nb4 → should trigger threefold
	}

	last_result: src.Move_Result
	for m in moves {
		pk := game.current_player == .White ? make_key('W') : make_key('B')
		_, last_result = src.game_move(&game, pk, m[0], m[1], T0)
		if last_result == .Stalemate { break }
	}

	t.expect_value(test, last_result, src.Move_Result.Stalemate)
	t.expect_value(test, game.result, src.Game_Result.Draw_Repetition)
}

@(test)
test_draw_no_progress :: proc(test: ^t.T) {
	// Kings and knights shuffling — no captures, no pawn moves
	board := empty_board()
	board[0] = .WK
	board[29] = .BK
	board[12] = .WN
	board[17] = .BN

	game := src.Game {
		board          = board,
		initial_board  = board,
		current_player = .White,
		state          = .Turn_White,
		white_key      = make_key('W'),
		black_key      = make_key('B'),
		clock          = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0},
		moves          = make([dynamic]chess.Move, 0, 60),
	}
	defer delete(game.moves)

	src.record_position(&game)

	// Make 50 non-capture, non-pawn moves by shuffling kings
	// WK: 0 → 1 → 0 → 1 ...
	// BK: 29 → 28 → 29 → 28 ...
	last_result: src.Move_Result
	for i in 0 ..< 50 {
		pk := game.current_player == .White ? make_key('W') : make_key('B')
		from, to: u8
		if game.current_player == .White {
			from = (i / 2) % 2 == 0 ? 0 : 1
			to = (i / 2) % 2 == 0 ? 1 : 0
		} else {
			from = (i / 2) % 2 == 0 ? 29 : 28
			to = (i / 2) % 2 == 0 ? 28 : 29
		}
		_, last_result = src.game_move(&game, pk, from, to, T0)
		if last_result != .Ok { break }
	}

	// Should be draw by either repetition or no-progress
	t.expect_value(test, last_result, src.Move_Result.Stalemate)
	t.expect(
		test,
		game.result == .Draw_Repetition || game.result == .Draw_No_Progress,
		"expected draw by repetition or no-progress",
	)
}

@(test)
test_capture_resets_draw_counters :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[29] = .BK
	board[12] = .WR
	board[17] = .BN // target for capture

	game := src.Game {
		board          = board,
		initial_board  = board,
		current_player = .White,
		state          = .Turn_White,
		white_key      = make_key('W'),
		black_key      = make_key('B'),
		clock          = {src.INITIAL_PERIODS, src.INITIAL_PERIODS, T0},
		moves          = make([dynamic]chess.Move, 0, 30),
	}
	defer delete(game.moves)

	src.record_position(&game)

	// Make a few king moves to build up no_progress_count
	// WK: 0→1, BK: 29→28, WK: 1→0, BK: 28→29
	src.game_move(&game, make_key('W'), 0, 1, T0)
	src.game_move(&game, make_key('B'), 29, 28, T0)
	src.game_move(&game, make_key('W'), 1, 0, T0)
	src.game_move(&game, make_key('B'), 28, 29, T0)
	t.expect_value(test, game.no_progress_count, u8(4))

	// Capture resets counter
	src.game_move(&game, make_key('W'), 12, 17, T0) // WR captures BN
	t.expect_value(test, game.no_progress_count, u8(0))
}

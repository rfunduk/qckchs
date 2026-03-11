package tests

import "base:runtime"

import src "../src"
import chess "../src/chess"
import t "core:testing"

@(init)
engine_setup :: proc "contextless" () {
	context = runtime.default_context()
	src.engine_init()
}

empty_board :: proc() -> chess.Board {
	b: chess.Board
	for &sq in b { sq = .X }
	return b
}

//odinfmt: disable
TEST_BOARD: chess.Board : {
	.BR, .BB, .BQ, .BK, .BN,
	.BP, .BP, .BP, .BP, .BP,
	.X,  .X,  .X,  .X,  .X,
	.X,  .X,  .X,  .X,  .X,
	.WP, .WP, .WP, .WP, .WP,
	.WR, .WB, .WQ, .WK, .WN,
}
//odinfmt: enable

// --- piece_owner ---

@(test)
test_piece_owner_white :: proc(test: ^t.T) {
	for p in ([]chess.Piece{.WK, .WQ, .WN, .WB, .WR, .WP}) {
		t.expect_value(test, chess.piece_owner(p), chess.Player.White)
	}
}

@(test)
test_piece_owner_black :: proc(test: ^t.T) {
	for p in ([]chess.Piece{.BK, .BQ, .BN, .BB, .BR, .BP}) {
		t.expect_value(test, chess.piece_owner(p), chess.Player.Black)
	}
}

@(test)
test_piece_owner_empty :: proc(test: ^t.T) {
	t.expect_value(test, chess.piece_owner(.X), chess.Player.None)
}

// --- pawn targets ---

@(test)
test_white_pawn_forward :: proc(test: ^t.T) {

	board := empty_board()
	board[22] = .WP // rank 4, file 2
	targets := chess.piece_targets(board, 22)
	t.expect_value(test, targets, chess.Targets{17})
}

@(test)
test_white_pawn_blocked :: proc(test: ^t.T) {
	board := empty_board()
	board[22] = .WP
	board[17] = .BN
	targets := chess.piece_targets(board, 22)
	t.expect_value(test, targets, chess.Targets{})
}

@(test)
test_white_pawn_captures :: proc(test: ^t.T) {
	board := empty_board()
	board[22] = .WP // rank 4, file 2
	board[16] = .BN // SW diagonal
	board[18] = .BB // SE diagonal
	targets := chess.piece_targets(board, 22)
	t.expect_value(test, targets, chess.Targets{16, 17, 18})
}

@(test)
test_white_pawn_no_friendly_capture :: proc(test: ^t.T) {
	board := empty_board()
	board[22] = .WP
	board[16] = .WN // SW but friendly
	targets := chess.piece_targets(board, 22)
	t.expect_value(test, targets, chess.Targets{17})
}

@(test)
test_white_pawn_edge_file_a :: proc(test: ^t.T) {
	board := empty_board()
	board[20] = .WP // rank 4, file 0 — left edge
	board[14] = .BN // not adjacent
	targets := chess.piece_targets(board, 20)
	// SW dist = min(rank=4, file=0) = 0, no wrapping
	t.expect_value(test, targets, chess.Targets{15})
}

@(test)
test_black_pawn_forward :: proc(test: ^t.T) {
	board := empty_board()
	board[7] = .BP // rank 1, file 2
	targets := chess.piece_targets(board, 7)
	t.expect_value(test, targets, chess.Targets{12})
}

@(test)
test_black_pawn_captures :: proc(test: ^t.T) {
	board := empty_board()
	board[7] = .BP // rank 1, file 2
	board[11] = .WR // NW diagonal
	board[13] = .WB // NE diagonal
	targets := chess.piece_targets(board, 7)
	t.expect_value(test, targets, chess.Targets{11, 12, 13})
}

@(test)
test_pawn_initial_board :: proc(test: ^t.T) {
	for f: u8 = 0; f < chess.FILES; f += 1 {
		wp_targets := chess.piece_targets(TEST_BOARD, 20 + f)
		t.expect_value(test, card(wp_targets), 1)
		t.expect(test, int(15 + f) in wp_targets)

		bp_targets := chess.piece_targets(TEST_BOARD, 5 + f)
		t.expect_value(test, card(bp_targets), 1)
		t.expect(test, int(10 + f) in bp_targets)
	}
}

// --- knight targets ---

@(test)
test_knight_center :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WN // rank 2, file 2
	targets := chess.piece_targets(board, 12)
	t.expect_value(test, targets, chess.Targets{1, 3, 5, 9, 15, 19, 21, 23})
}

@(test)
test_knight_corner :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .BN // rank 0, file 0
	targets := chess.piece_targets(board, 0)
	// (+1,+2)→7, (+2,+1)→11
	t.expect_value(test, targets, chess.Targets{7, 11})
}

@(test)
test_knight_captures_enemy :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WN
	board[1] = .BP // enemy — can capture
	board[3] = .WP // friendly — blocked
	targets := chess.piece_targets(board, 12)
	t.expect_value(test, targets, chess.Targets{1, 5, 9, 15, 19, 21, 23})
}

@(test)
test_knight_initial_board :: proc(test: ^t.T) {
	// WN at 29 (rank 5, file 4): only (-2,-1)→18
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 29), chess.Targets{18})
	// BN at 4 (rank 0, file 4): only (+2,-1)→13
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 4), chess.Targets{13})
}

// --- king targets ---

@(test)
test_king_center :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WK
	targets := chess.piece_targets(board, 12)
	t.expect_value(test, targets, chess.Targets{6, 7, 8, 11, 13, 16, 17, 18})
}

@(test)
test_king_corner :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .BK // rank 0, file 0
	targets := chess.piece_targets(board, 0)
	// E→1, N→5, NE→6
	t.expect_value(test, targets, chess.Targets{1, 5, 6})
}

@(test)
test_king_initial_board :: proc(test: ^t.T) {
	// Both kings boxed in by own pieces
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 28), chess.Targets{})
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 3), chess.Targets{})
}

// --- sliding targets ---

@(test)
test_rook_center :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WR // rank 2, file 2
	targets := chess.piece_targets(board, 12)
	// N: 17,22,27  S: 7,2  W: 11,10  E: 13,14
	t.expect_value(test, targets, chess.Targets{2, 7, 10, 11, 13, 14, 17, 22, 27})
}

@(test)
test_rook_blocked_by_friendly :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WR
	board[17] = .WP // blocks N immediately
	targets := chess.piece_targets(board, 12)
	t.expect_value(test, targets, chess.Targets{2, 7, 10, 11, 13, 14})
}

@(test)
test_rook_captures_then_stops :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WR
	board[17] = .BN // enemy at first N step
	targets := chess.piece_targets(board, 12)
	t.expect_value(test, targets, chess.Targets{2, 7, 10, 11, 13, 14, 17})
}

@(test)
test_bishop_center :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WB
	targets := chess.piece_targets(board, 12)
	// NW: 16,20  NE: 18,24  SW: 6,0  SE: 8,4
	t.expect_value(test, targets, chess.Targets{0, 4, 6, 8, 16, 18, 20, 24})
}

@(test)
test_queen_center :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WQ
	targets := chess.piece_targets(board, 12)
	t.expect_value(
		test,
		targets,
		chess.Targets{0, 2, 4, 6, 7, 8, 10, 11, 13, 14, 16, 17, 18, 20, 22, 24, 27},
	)
}

@(test)
test_sliding_initial_board :: proc(test: ^t.T) {
	// All back-rank sliders boxed in
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 25), chess.Targets{}) // WR
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 26), chess.Targets{}) // WB
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 27), chess.Targets{}) // WQ
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 0), chess.Targets{}) // BR
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 1), chess.Targets{}) // BB
	t.expect_value(test, chess.piece_targets(TEST_BOARD, 2), chess.Targets{}) // BQ
}

// --- is_legal_move ---

@(test)
test_is_legal_move :: proc(test: ^t.T) {
	t.expect(test, chess.is_legal_move(TEST_BOARD, 22, 17)) // WP forward
	t.expect(test, !chess.is_legal_move(TEST_BOARD, 22, 12)) // two squares
	t.expect(test, !chess.is_legal_move(TEST_BOARD, 22, 16)) // diagonal, no enemy
	t.expect(test, !chess.is_legal_move(TEST_BOARD, 10, 15)) // empty square
	t.expect(test, !chess.is_legal_move(TEST_BOARD, 30, 0)) // out of bounds
}

// --- make_move ---

@(test)
test_make_move_basic :: proc(test: ^t.T) {
	game := src.Game {
		board          = TEST_BOARD,
		current_player = .White,
		moves          = make([dynamic]chess.Move, 0, 10),
	}
	defer delete(game.moves)

	move, king_captured := src.make_move(&game, 22, 17)
	t.expect_value(test, move.piece, chess.Piece.WP)
	t.expect_value(test, move.from, u8(22))
	t.expect_value(test, move.to, u8(17))
	t.expect(test, !move.capture)
	t.expect(test, !king_captured)
	t.expect_value(test, game.board[22], chess.Piece.X)
	t.expect_value(test, game.board[17], chess.Piece.WP)
	t.expect_value(test, game.current_player, chess.Player.Black)
	t.expect_value(test, len(game.moves), 1)
}

@(test)
test_make_move_wrong_player :: proc(test: ^t.T) {
	game := src.Game {
		board          = TEST_BOARD,
		current_player = .White,
		moves          = make([dynamic]chess.Move, 0, 10),
	}
	defer delete(game.moves)

	move, _ := src.make_move(&game, 7, 12) // black pawn on white's turn
	t.expect_value(test, move.piece, chess.Piece.X)
	t.expect_value(test, game.current_player, chess.Player.White)
}

@(test)
test_make_move_capture :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WR
	board[17] = .BN
	game := src.Game {
		board          = board,
		current_player = .White,
		moves          = make([dynamic]chess.Move, 0, 10),
	}
	defer delete(game.moves)

	move, king_captured := src.make_move(&game, 12, 17)
	t.expect(test, move.capture)
	t.expect(test, !king_captured)
	t.expect_value(test, game.board[17], chess.Piece.WR)
	t.expect_value(test, game.board[12], chess.Piece.X)
}

@(test)
test_make_move_king_capture :: proc(test: ^t.T) {
	board := empty_board()
	board[12] = .WQ
	board[7] = .BK
	game := src.Game {
		board          = board,
		current_player = .White,
		moves          = make([dynamic]chess.Move, 0, 10),
	}
	defer delete(game.moves)

	_, king_captured := src.make_move(&game, 12, 7)
	t.expect(test, king_captured)
}

@(test)
test_make_move_auto_queen_white :: proc(test: ^t.T) {
	board := empty_board()
	board[6] = .WP // rank 1, one step from back rank
	game := src.Game {
		board          = board,
		current_player = .White,
		moves          = make([dynamic]chess.Move, 0, 10),
	}
	defer delete(game.moves)

	move, _ := src.make_move(&game, 6, 1)
	t.expect_value(test, move.piece, chess.Piece.WP) // logged as pawn
	t.expect_value(test, game.board[1], chess.Piece.WQ) // promoted
}

@(test)
test_make_move_auto_queen_black :: proc(test: ^t.T) {
	board := empty_board()
	board[23] = .BP // rank 4, one step from back rank
	game := src.Game {
		board          = board,
		current_player = .Black,
		moves          = make([dynamic]chess.Move, 0, 10),
	}
	defer delete(game.moves)

	move, _ := src.make_move(&game, 23, 28)
	t.expect_value(test, move.piece, chess.Piece.BP)
	t.expect_value(test, game.board[28], chess.Piece.BQ)
}

@(test)
test_empty_square_no_targets :: proc(test: ^t.T) {
	board := empty_board()
	t.expect_value(test, chess.piece_targets(board, 12), chess.Targets{})
}

@(test)
test_format_targets :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	t.expect_value(test, src.format_targets(chess.Targets{15}), "15")
	t.expect_value(test, src.format_targets(chess.Targets{10, 15, 20}), "10,15,20")
	t.expect_value(test, src.format_targets(chess.Targets{0, 5, 29}), "0,5,29")
	t.expect_value(test, src.format_targets(chess.Targets{}), "")
}

@(test)
test_board_squares_white_targets :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	squares := src.board_squares(TEST_BOARD, .White)
	// WP at board index 20 is CSS grid position 20 for White viewer
	// Should have target 15 (one square forward)
	t.expect_value(test, squares[20].targets, "15")
	// WN at board index 29 is CSS grid position 29
	// Should have target 18
	t.expect_value(test, squares[29].targets, "18")
	// Empty square should have no targets
	t.expect_value(test, squares[12].targets, "")
	// Black piece should have no targets for White viewer
	t.expect_value(test, squares[0].targets, "")
}

// --- insufficient material ---

@(test)
test_insufficient_material_k_vs_k :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[29] = .BK
	t.expect(test, chess.is_insufficient_material(board))
}

@(test)
test_insufficient_material_kn_vs_k :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[12] = .WN
	board[29] = .BK
	t.expect(test, chess.is_insufficient_material(board))
}

@(test)
test_insufficient_material_kb_vs_k :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[12] = .WB
	board[29] = .BK
	t.expect(test, chess.is_insufficient_material(board))
}

@(test)
test_insufficient_material_kb_vs_kb :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[29] = .BK
	board[12] = .WB
	board[17] = .BB
	t.expect(test, chess.is_insufficient_material(board))
}

@(test)
test_sufficient_material_with_rook :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[12] = .WR
	board[29] = .BK
	t.expect(test, !chess.is_insufficient_material(board))
}

@(test)
test_sufficient_material_with_queen :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[29] = .BK
	board[12] = .BQ
	t.expect(test, !chess.is_insufficient_material(board))
}

@(test)
test_sufficient_material_with_pawn :: proc(test: ^t.T) {
	board := empty_board()
	board[0] = .WK
	board[29] = .BK
	board[12] = .WP
	t.expect(test, !chess.is_insufficient_material(board))
}

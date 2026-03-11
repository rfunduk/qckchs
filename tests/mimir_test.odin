package tests

import chess "../src/chess"
import mimir "../src/mimir"
import t "core:testing"

@(test)
test_move_pack_roundtrip :: proc(tt: ^t.T) {
	m := mimir.move_pack(7, 22)
	t.expect_value(tt, mimir.move_from(m), u8(7))
	t.expect_value(tt, mimir.move_to(m), u8(22))
}

@(test)
test_apply_move_basic :: proc(tt: ^t.T) {
	board: chess.Board
	for &sq in board { sq = .X }
	board[20] = .WP // white pawn at index 20

	m := mimir.move_pack(20, 15) // move pawn forward
	result := mimir.apply_move(board, m)

	t.expect_value(tt, result[20], chess.Piece.X)
	t.expect_value(tt, result[15], chess.Piece.WP)
}

@(test)
test_generate_moves_initial :: proc(tt: ^t.T) {
	list: mimir.Move_List
	board := chess.INITIAL_BOARD
	mimir.generate_moves(board, .White, &list)
	count := list.len
	t.expect(tt, count > 0, "expected at least one legal move for white on initial board")

	// All generated moves should be for white pieces
	for i := 0; i < int(count); i += 1 {
		from := mimir.move_from(list.data[i].move)
		piece := board[from]
		t.expect(
			tt,
			chess.piece_owner(piece) == .White,
			"expected all generated moves to be for white pieces",
		)
	}
}

@(test)
test_pick_best_move_captures_king :: proc(tt: ^t.T) {
	// Set up a board where white queen can capture black king
	board: chess.Board
	for &sq in board { sq = .X }
	board[0] = .BK // black king at 0
	board[5] = .WQ // white queen at 5 (can reach 0)
	board[29] = .WK // white king at 29

	eng := mimir.engine_create()
	defer mimir.engine_destroy(eng)

	mimir.init_zobrist()
	mimir.init_lmr()

	best := mimir.pick_best_move(eng, board, .White, 120, 1, 4)
	// Should capture the king at square 0
	t.expect_value(tt, mimir.move_to(best), u8(0))
}

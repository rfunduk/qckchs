package chess

import "core:strings"

//odinfmt: disable
piece_san_prefix :: proc(piece: Piece) -> u8 {
	switch {
	case piece in Kings:   return 'K'
	case piece in Queens:  return 'Q'
	case piece in Rooks:   return 'R'
	case piece in Bishops: return 'B'
	case piece in Knights: return 'N'
	case:                  return 0
	}
}
//odinfmt: enable

move_algebraic :: proc(board: Board, move: Move) -> string {
	b := strings.builder_make()

	if move.piece not_in Pawns {
		prefix := piece_san_prefix(move.piece)
		strings.write_byte(&b, prefix)

		// Disambiguation: check if another piece of the same type can reach the target
		same_file, same_rank: bool
		ambiguous := false
		for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
			if sq == move.from { continue }
			if board[sq] != move.piece { continue }
			if int(move.to) not_in piece_targets(board, sq) { continue }
			ambiguous = true
			if sq_file(sq) == sq_file(move.from) { same_file = true }
			if sq / FILES == move.from / FILES { same_rank = true }
		}
		if ambiguous {
			if !same_file {
				strings.write_byte(&b, 'a' + sq_file(move.from))
			} else if !same_rank {
				strings.write_byte(&b, '0' + sq_rank(move.from))
			} else {
				strings.write_byte(&b, 'a' + sq_file(move.from))
				strings.write_byte(&b, '0' + sq_rank(move.from))
			}
		}
	} else if move.capture {
		strings.write_byte(&b, 'a' + sq_file(move.from))
	}

	if move.capture { strings.write_byte(&b, 'x') }

	strings.write_byte(&b, 'a' + sq_file(move.to))
	strings.write_byte(&b, '0' + sq_rank(move.to))

	// Promotion
	if move.piece == .WP && move.to < FILES {
		strings.write_string(&b, "=Q")
	} else if move.piece == .BP && move.to >= RANKS * FILES - FILES {
		strings.write_string(&b, "=Q")
	}

	return strings.to_string(b)
}

moves_algebraic :: proc(starting_board: Board, moves: []Move) -> []string {
	result := make([]string, len(moves))
	board := starting_board
	for i in 0 ..< len(moves) {
		result[i] = move_algebraic(board, moves[i])
		apply_move(&board, moves[i])
	}
	return result
}

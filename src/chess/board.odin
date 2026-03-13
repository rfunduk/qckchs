package chess

import "core:hash"
import "core:math/rand"
import "core:strings"

sq_file :: proc(sq: u8) -> u8 { return sq % FILES }
sq_rank :: proc(sq: u8) -> u8 { return RANKS - sq / FILES }

piece_owner :: proc(piece: Piece) -> Player {
	if piece in White_Pieces { return .White }
	if piece in Black_Pieces { return .Black }
	return .None
}

board_hash :: proc(board: Board, player: Player) -> u32 {
	board_bytes := transmute([size_of(Board)]u8)board
	player_byte := [1]u8{u8(player)}
	return hash.fnv32a(player_byte[:], hash.fnv32a(board_bytes[:]))
}

board_string :: proc(board: Board) -> string {
	b := strings.builder_make(0, int(RANKS * FILES))
	for sq in board { strings.write_byte(&b, piece_char(sq)) }
	return strings.to_string(b)
}

random_board :: proc() -> Board {
	white := [5]Piece{.WR, .WB, .WQ, .WK, .WN}
	black := [5]Piece{.BR, .BB, .BQ, .BK, .BN}

	// Fisher-Yates shuffle — same permutation for both sides
	for i := u8(4); i > 0; i -= 1 {
		j := u8(rand.int_max(int(i + 1)))
		white[i], white[j] = white[j], white[i]
		black[i], black[j] = black[j], black[i]
	}

	board: Board
	for f: u8 = 0; f < FILES; f += 1 {
		board[f] = black[f]
		board[f + FILES] = .BP
		board[f + 4 * FILES] = .WP
		board[f + 5 * FILES] = white[f]
	}
	return board
}

//odinfmt: disable
char_to_piece :: proc(ch: u8) -> Piece {
	switch ch {
	case 'K': return .WK
	case 'Q': return .WQ
	case 'N': return .WN
	case 'B': return .WB
	case 'R': return .WR
	case 'P': return .WP
	case 'k': return .BK
	case 'q': return .BQ
	case 'n': return .BN
	case 'b': return .BB
	case 'r': return .BR
	case 'p': return .BP
	case:     return .X
	}
}

piece_char :: proc(piece: Piece) -> u8 {
	switch piece {
	case .WK: return 'K'
	case .WQ: return 'Q'
	case .WR: return 'R'
	case .WB: return 'B'
	case .WN: return 'N'
	case .WP: return 'P'
	case .BK: return 'k'
	case .BQ: return 'q'
	case .BR: return 'r'
	case .BB: return 'b'
	case .BN: return 'n'
	case .BP: return 'p'
	case .X:  return 'x'
	case:     return 'x'
	}
}
//odinfmt: enable

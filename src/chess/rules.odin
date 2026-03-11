package chess

import "core:hash"
import "core:math/rand"

board_hash :: proc(board: Board, player: Player) -> u32 {
	board_bytes := transmute([size_of(Board)]u8)board
	player_byte := [1]u8{u8(player)}
	return hash.fnv32a(player_byte[:], hash.fnv32a(board_bytes[:]))
}

is_legal_move :: proc(board: Board, from: u8, to: u8) -> bool {
	if from >= 30 || to >= 30 { return false }
	if board[from] == .X { return false }
	return int(to) in piece_targets(board, from)
}

apply_move :: proc(board: ^Board, move: Move) {
	board[move.to] = move.piece
	board[move.from] = .X
	if move.piece == .WP && move.to < FILES {
		board[move.to] = .WQ
	} else if move.piece == .BP && move.to >= RANKS * FILES - FILES {
		board[move.to] = .BQ
	}
}

is_insufficient_material :: proc(board: Board) -> bool {
	piece_count: u8
	has_wb, has_bb: bool
	for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
		piece := board[sq]
		if piece == .X { continue }
		if piece in Rooks || piece in Queens || piece in Pawns { return false }
		piece_count += 1
		if piece == .WB { has_wb = true }
		if piece == .BB { has_bb = true }
	}
	// K vs K, K+minor vs K
	if piece_count <= 3 { return true }
	// K+B vs K+B (any bishop colors — neither side can force capture)
	if piece_count == 4 && has_wb && has_bb { return true }
	return false
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

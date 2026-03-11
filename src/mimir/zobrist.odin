package mimir

import "../chess"

// Zobrist hash tables — initialized once at startup via init_zobrist().
// Uses xorshift64 PRNG from a fixed seed for reproducibility.

zobrist_pieces: [30][len(chess.Piece)]u64
zobrist_side: u64

// xorshift64 PRNG
@(private)
xorshift64 :: proc(state: ^u64) -> u64 {
	s := state^
	s ~= s << 13
	s ~= s >> 7
	s ~= s << 17
	state^ = s
	return s
}

init_zobrist :: proc() {
	state: u64 = 0xDEAD_BEEF_CAFE_BABE

	for sq in 0 ..< 30 {
		for p in chess.Piece {
			zobrist_pieces[sq][p] = xorshift64(&state)
		}
	}
	zobrist_side = xorshift64(&state)
}

// Compute Zobrist hash from scratch.
zobrist_hash :: proc(board: chess.Board, player: chess.Player) -> u64 {
	h: u64 = 0
	for sq in 0 ..< 30 {
		p := board[sq]
		if p != .X {
			h ~= zobrist_pieces[sq][p]
		}
	}
	if player == .Black {
		h ~= zobrist_side
	}
	return h
}

// Incremental Zobrist update for apply_move.
// Returns the new hash after the move.
zobrist_apply_move :: proc(h: u64, board: chess.Board, m: Move) -> u64 {
	hash := h
	from := move_from(m)
	to := move_to(m)
	piece := board[from]
	captured := board[to]

	// Remove piece from origin
	hash ~= zobrist_pieces[from][piece]

	// Remove captured piece (if any)
	if captured != .X {
		hash ~= zobrist_pieces[to][captured]
	}

	// Add piece at destination (handle promotion)
	dest_piece := piece
	if piece == .WP && to < 5 {
		dest_piece = .WQ
	} else if piece == .BP && to >= 25 {
		dest_piece = .BQ
	}
	hash ~= zobrist_pieces[to][dest_piece]

	// Flip side to move
	hash ~= zobrist_side

	return hash
}

package mimir

import sa "core:container/small_array"

import "../chess"

// --- Move (packed u16, critical for TT/killers/history) ---

Move :: distinct u16

move_pack :: proc(from, to: u8) -> Move {
	return Move(u16(from) * 30 + u16(to))
}

move_from :: proc(m: Move) -> u8 {
	return u8(u16(m) / 30)
}

move_to :: proc(m: Move) -> u8 {
	return u8(u16(m) % 30)
}

NULL_MOVE :: Move(0)

// --- Move ordering ---

Move_Entry :: struct {
	move:  Move,
	score: i32,
}

Move_List :: sa.Small_Array(128, Move_Entry)

// --- Piece values (runtime variable so it can be indexed by variable) ---

//odinfmt: disable
piece_values := [chess.Piece]i32{
	.X  = 0,
	.WK = 20000, .WQ = 900, .WN = 320, .WB = 330, .WR = 500, .WP = 100,
	.BK = 20000, .BQ = 900, .BN = 320, .BB = 330, .BR = 500, .BP = 100,
}
//odinfmt: enable

// --- Piece-square tables (white perspective, index 0-4 = rank 6) ---
// Runtime variables for runtime indexing.
//odinfmt: disable
pst_pawn := [30]i32{
	 0,  0,  0,  0,  0,   // rank 6
	30, 35, 40, 35, 30,   // rank 5
	15, 20, 25, 20, 15,   // rank 4
	 5, 10, 15, 10,  5,   // rank 3
	 0,  0,  0,  0,  0,   // rank 2
	 0,  0,  0,  0,  0,   // rank 1
}

pst_knight := [30]i32{
	-10,  0,  5,  0, -10,
	  0, 10, 15, 10,   0,
	  5, 15, 20, 15,   5,
	  5, 15, 20, 15,   5,
	  0, 10, 15, 10,   0,
	-10,  0,  5,  0, -10,
}

pst_bishop := [30]i32{
	 -5,  0,  0,  0,  -5,
	  0, 10,  5, 10,   0,
	  0,  5, 15,  5,   0,
	  0,  5, 15,  5,   0,
	  0, 10,  5, 10,   0,
	 -5,  0,  0,  0,  -5,
}

pst_rook := [30]i32{
	 5,  5,  5,  5,  5,
	10, 10, 10, 10, 10,
	 0,  0,  5,  0,  0,
	 0,  0,  5,  0,  0,
	 0,  0,  5,  0,  0,
	 0,  5,  5,  5,  0,
}

pst_queen := [30]i32{
	-5,  0,  0,  0,  -5,
	 0,  5, 10,  5,   0,
	 0,  5, 10,  5,   0,
	 0,  5, 10,  5,   0,
	 0,  5,  5,  5,   0,
	-5,  0,  0,  0,  -5,
}

pst_king := [30]i32{
	-20, -20, -30, -20, -20,
	-20, -20, -30, -20, -20,
	-20, -20, -20, -20, -20,
	-10, -10, -10, -10, -10,
	 10,  10,   0,  10,  10,
	 15,  20,   5,  20,  15,
}

pst_king_endgame := [30]i32{
	-10,   0,   5,   0, -10,
	 -5,  10,  15,  10,  -5,
	  0,  15,  20,  15,   0,
	  0,  15,  20,  15,   0,
	 -5,  10,  15,  10,  -5,
	-10,   0,   5,   0, -10,
}

ENDGAME_MATERIAL_THRESHOLD :: 640

// MIRROR[sq] flips rank for black PST lookup: rank 1 <-> rank 6, etc.
mirror := [30]u8 {
	25,	26,	27,	28,	29,
	20,	21,	22,	23,	24,
	15,	16,	17,	18,	19,
	10,	11,	12,	13,	14,
	5,	6,	7,	8,	9,
	0,	1,	2,	3,	4,
}

// Bonus tables indexed by effective rank (runtime variable for indexing)
passed_pawn_bonus := [7]i32{0, 0, 20, 50, 130, 300, 0}
mobile_pawn_bonus := [7]i32{0, 0, 3, 6, 12, 20, 0}
//odinfmt: enable

// piece_pst returns the PST value for a given piece at a given square.
piece_pst :: proc(p: chess.Piece, sq: u8) -> i32 {
	idx: u8
	switch {
	case p in chess.White_Pieces:
		idx = sq
	case p in chess.Black_Pieces:
		idx = mirror[sq]
	case:
		return 0
	}

	switch p {
	case .WP, .BP:
		return pst_pawn[idx]
	case .WN, .BN:
		return pst_knight[idx]
	case .WB, .BB:
		return pst_bishop[idx]
	case .WR, .BR:
		return pst_rook[idx]
	case .WQ, .BQ:
		return pst_queen[idx]
	case .WK, .BK:
		return pst_king[idx]
	case .X:
		return 0
	}
	return 0
}

// --- Apply move (copy-make) ---

apply_move :: proc(board: chess.Board, m: Move) -> chess.Board {
	b := board
	from := move_from(m)
	to := move_to(m)
	piece := b[from]
	b[from] = .X
	// Auto-queen on back rank
	if piece == .WP && to < 5 {
		piece = .WQ
	} else if piece == .BP && to >= 25 {
		piece = .BQ
	}
	b[to] = piece
	return b
}

// --- Coordinate helpers ---

idx_to_file :: proc(sq: u8) -> u8 {
	return sq % chess.FILES
}

idx_to_rank :: proc(sq: u8) -> u8 {
	// rank 1..6 where rank 6 = row 0
	return chess.RANKS - sq / chess.FILES
}

// Chebyshev distance between two squares
chebyshev :: proc(sq1, sq2: u8) -> i32 {
	f1 := i32(sq1 % chess.FILES)
	r1 := i32(sq1 / chess.FILES)
	f2 := i32(sq2 % chess.FILES)
	r2 := i32(sq2 / chess.FILES)
	return max(abs(f1 - f2), abs(r1 - r2))
}

// Square color (0 or 1) for bishop-color checks
square_color :: proc(sq: u8) -> u8 {
	return (sq % chess.FILES + sq / chess.FILES) % 2
}

INF :: i32(999_999)

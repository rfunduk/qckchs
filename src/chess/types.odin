package chess

RANKS: u8 : 6
FILES: u8 : 5

Board :: [RANKS * FILES]Piece

Player :: enum {
	None,
	White,
	Black,
}

Move :: struct {
	piece:   Piece,
	from:    u8,
	to:      u8,
	capture: bool,
}

//odinfmt: disable
Piece :: enum {
    X,
	WK,	WQ,	WN,	WB,	WR,	WP,
	BK,	BQ,	BN,	BB,	BR,	BP,
}
Pieces :: bit_set[Piece]

Direction :: enum {
	N, S, W, E, // orthogonal 0-3
	NW, SW, NE, SE, // diagonal 4-7
}

Offsets :: [Direction]i8 {
	.N  = 5, .S  = -5, .W  = -1, .E  = 1,
	.NW = 4, .SW = -6, .NE = 6, .SE = -4,
}

Direction_Range :: [Piece][2]u8 {
	.X  = {0, 0},
	.WK = {0, 0}, .WN = {0, 0}, .WP = {0, 0},
	.BK = {0, 0}, .BN = {0, 0}, .BP = {0, 0},
	.WQ = {0, 8}, .BQ = {0, 8},
	.WR = {0, 4}, .BR = {0, 4},
	.WB = {4, 8}, .BB = {4, 8},
}

INITIAL_BOARD: Board : {
	.BR, .BB, .BQ, .BK, .BN,
	.BP, .BP, .BP, .BP, .BP,
	.X,  .X,  .X,  .X,  .X,
	.X,  .X,  .X,  .X,  .X,
	.WP, .WP, .WP, .WP, .WP,
	.WR, .WB, .WQ, .WK, .WN,
}

KNIGHT_MOVES :: [8][2]i16 {
	{-2, -1}, {-2, 1}, {-1, -2}, {-1, 2},
	{ 1, -2}, { 1, 2}, { 2, -1}, { 2, 1},
}
//odinfmt: enable

Targets :: bit_set[0 ..< 30;u32]

White_Pieces: Pieces : {.WK, .WQ, .WN, .WB, .WR, .WP}
Black_Pieces: Pieces : {.BK, .BQ, .BN, .BB, .BR, .BP}
Sliding_Pieces: Pieces : {.WQ, .BQ, .WB, .BB, .WR, .BR}
Kings: Pieces : {.WK, .BK}
Queens: Pieces : {.WQ, .BQ}
Knights: Pieces : {.WN, .BN}
Bishops: Pieces : {.WB, .BB}
Rooks: Pieces : {.WR, .BR}
Pawns: Pieces : {.WP, .BP}

opponent :: proc(p: Player) -> Player {
	switch p {
	case .White:
		return .Black
	case .Black:
		return .White
	case .None:
		return .None
	}
	return .None
}

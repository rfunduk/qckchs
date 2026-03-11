package chess

distances: [RANKS * FILES][8]u8
knight_table: [RANKS * FILES]Targets
king_table: [RANKS * FILES]Targets
pawn_table: [2][RANKS * FILES]Targets // [0]=white, [1]=black

init :: proc() {
	i: u8 = 0
	for r: u8 = 0; r < RANKS; r += 1 {
		for f: u8 = 0; f < FILES; f += 1 {
			n := RANKS - r - 1
			s := r
			e := FILES - f - 1
			w := f

			distances[i] = [8]u8{n, s, w, e, min(n, w), min(s, w), min(n, e), min(s, e)}
			i += 1
		}
	}

	for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
		rank := i16(sq / FILES)
		file := i16(sq % FILES)
		for move in KNIGHT_MOVES {
			nr := rank + move[0]
			nf := file + move[1]
			if nr < 0 || nr >= i16(RANKS) || nf < 0 || nf >= i16(FILES) { continue }
			knight_table[sq] += {int(u8(nr) * FILES + u8(nf))}
		}
	}

	offsets := Offsets
	for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
		for dir_idx: u8 = 0; dir_idx < 8; dir_idx += 1 {
			if distances[sq][dir_idx] == 0 { continue }
			target := i16(sq) + i16(offsets[Direction(dir_idx)])
			king_table[sq] += {int(target)}
		}
	}

	// Precompute pawn attack tables
	for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
		file := i16(sq % FILES)
		rank := i16(sq / FILES)

		// White pawns attack toward lower indices (row - 1)
		w_targets: Targets
		w_rank := rank - 1
		if w_rank >= 0 {
			for df in ([2]i16{-1, 1}) {
				nf := file + df
				if nf >= 0 && nf < i16(FILES) {
					w_targets += {int(u8(w_rank) * FILES + u8(nf))}
				}
			}
		}
		pawn_table[0][sq] = w_targets

		// Black pawns attack toward higher indices (row + 1)
		b_targets: Targets
		b_rank := rank + 1
		if b_rank < i16(RANKS) {
			for df in ([2]i16{-1, 1}) {
				nf := file + df
				if nf >= 0 && nf < i16(FILES) {
					b_targets += {int(u8(b_rank) * FILES + u8(nf))}
				}
			}
		}
		pawn_table[1][sq] = b_targets
	}
}

piece_owner :: proc(piece: Piece) -> Player {
	if piece in White_Pieces { return .White }
	if piece in Black_Pieces { return .Black }
	return .None
}

piece_targets :: proc(board: Board, from: u8) -> Targets {
	piece := board[from]
	if piece in Sliding_Pieces { return sliding_targets(board, from, piece) }
	if piece in Pawns { return pawn_targets(board, from, piece) }
	if piece in Kings { return king_targets(board, from, piece) }
	if piece in Knights { return knight_targets(board, from, piece) }
	return {}
}

sliding_targets :: proc(board: Board, from: u8, piece: Piece) -> Targets {
	owner := piece_owner(piece)
	dr := Direction_Range
	range := dr[piece]
	offsets := Offsets
	targets: Targets

	for dir_idx: u8 = range[0]; dir_idx < range[1]; dir_idx += 1 {
		dir := Direction(dir_idx)
		offset := i16(offsets[dir])
		dist := distances[from][dir_idx]

		sq := i16(from)
		for _step: u8 = 0; _step < dist; _step += 1 {
			sq += offset
			target := board[sq]
			if target == .X {
				targets += {int(sq)}
			} else if piece_owner(target) != owner {
				targets += {int(sq)}
				break
			} else {
				break
			}
		}
	}

	return targets
}

king_targets :: proc(board: Board, from: u8, piece: Piece) -> Targets {
	own: Pieces = piece_owner(piece) == .White ? White_Pieces : Black_Pieces
	targets := king_table[from]
	for sq in targets {
		if board[sq] in own { targets -= {sq} }
	}
	return targets
}

knight_targets :: proc(board: Board, from: u8, piece: Piece) -> Targets {
	own: Pieces = piece_owner(piece) == .White ? White_Pieces : Black_Pieces
	targets := knight_table[from]
	for sq in targets {
		if board[sq] in own { targets -= {sq} }
	}
	return targets
}

pawn_targets :: proc(board: Board, from: u8, piece: Piece) -> Targets {
	targets: Targets

	fwd_dir: Direction
	cap_l, cap_r: Direction
	enemy: Player

	if piece == .WP {
		fwd_dir = .S
		cap_l = .SW
		cap_r = .SE
		enemy = .Black
	} else {
		fwd_dir = .N
		cap_l = .NW
		cap_r = .NE
		enemy = .White
	}

	offsets := Offsets

	// Forward
	if distances[from][int(fwd_dir)] > 0 {
		sq := i16(from) + i16(offsets[fwd_dir])
		if board[sq] == .X { targets += {int(sq)} }
	}

	// Captures
	for cap_dir in ([2]Direction{cap_l, cap_r}) {
		if distances[from][int(cap_dir)] == 0 { continue }
		sq := i16(from) + i16(offsets[cap_dir])
		if board[sq] != .X && piece_owner(board[sq]) == enemy {
			targets += {int(sq)}
		}
	}

	return targets
}

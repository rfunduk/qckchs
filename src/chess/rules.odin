package chess

NO_PROGRESS_THRESHOLD :: 50

is_threefold_repetition :: proc(hashes: []u32) -> bool {
	n := len(hashes)
	if n < 3 { return false }
	last := hashes[n - 1]
	count := 0
	for i in 0 ..< n {
		if hashes[i] == last {
			count += 1
			if count >= 3 { return true }
		}
	}
	return false
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

is_insufficient_material :: proc(board: Board, next_to_move: Player) -> bool {
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

	// K vs K, K+minor vs K or
	// K+B vs K+B (any bishop colors — neither side can force capture)
	is_insuff: bool = piece_count <= 3 || (piece_count == 4 && has_wb && has_bb)
	if !is_insuff { return false }

	// Even with insufficient material, if the opponent's king is currently
	// capturable, it's not a draw — the side to move wins immediately.
	return !is_king_capturable(board, next_to_move)
}

// Returns true if `attacker` has any piece that can capture the opponent's king.
is_king_capturable :: proc(board: Board, attacker: Player) -> bool {
	target_king: Piece = attacker == .White ? .BK : .WK
	own := attacker == .White ? White_Pieces : Black_Pieces
	king_sq: u8
	for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
		if board[sq] == target_king { king_sq = sq;break }
	}
	for sq: u8 = 0; sq < RANKS * FILES; sq += 1 {
		if board[sq] == .X || board[sq] not_in own { continue }
		if int(king_sq) in piece_targets(board, sq) { return true }
	}
	return false
}

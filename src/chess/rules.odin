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

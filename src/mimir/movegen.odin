package mimir

import sa "core:container/small_array"

import "../chess"

// --- Move generation ---

generate_moves :: proc(board: chess.Board, player: chess.Player, list: ^Move_List) {
	sa.clear(list)
	for sq: u8 = 0; sq < 30; sq += 1 {
		p := board[sq]
		if chess.piece_owner(p) != player { continue }
		targets := chess.piece_targets(board, sq)
		for to in targets {
			sa.append(list, Move_Entry{move = move_pack(sq, u8(to)), score = 0})
		}
	}
}

generate_captures :: proc(board: chess.Board, player: chess.Player, list: ^Move_List) {
	sa.clear(list)
	for sq: u8 = 0; sq < 30; sq += 1 {
		p := board[sq]
		if chess.piece_owner(p) != player { continue }
		targets := chess.piece_targets(board, sq)
		for to in targets {
			if board[to] != .X {
				sa.append(list, Move_Entry{move = move_pack(sq, u8(to)), score = 0})
			}
		}
	}
}

// --- Attack maps ---

// Sliding attack targets (ignoring friendly blocking for attack map purposes)
sliding_attack_targets :: proc(board: chess.Board, from: u8, piece: chess.Piece) -> chess.Targets {
	dr := chess.Direction_Range
	range := dr[piece]
	offsets := chess.Offsets
	targets: chess.Targets

	for dir_idx: u8 = range[0]; dir_idx < range[1]; dir_idx += 1 {
		dir := chess.Direction(dir_idx)
		offset := i16(offsets[dir])
		dist := chess.distances[from][dir_idx]

		sq := i16(from)
		for _step: u8 = 0; _step < dist; _step += 1 {
			sq += offset
			targets += {int(sq)}
			if board[sq] != .X {
				break
			}
		}
	}

	return targets
}

attacks_for_color :: proc(board: chess.Board, player: chess.Player) -> chess.Targets {
	attacks: chess.Targets
	color_idx := player == .White ? 0 : 1

	for sq: u8 = 0; sq < 30; sq += 1 {
		p := board[sq]
		if chess.piece_owner(p) != player { continue }

		switch {
		case p in chess.Knights:
			attacks += chess.knight_table[sq]
		case p in chess.Kings:
			attacks += chess.king_table[sq]
		case p in chess.Pawns:
			attacks += chess.pawn_table[color_idx][sq]
		case p in chess.Sliding_Pieces:
			attacks += sliding_attack_targets(board, sq, p)
		}
	}

	return attacks
}

has_king :: proc(board: chess.Board, player: chess.Player) -> bool {
	king := player == .White ? chess.Piece.WK : chess.Piece.BK
	for sq: u8 = 0; sq < 30; sq += 1 {
		if board[sq] == king { return true }
	}
	return false
}

find_king :: proc(board: chess.Board, player: chess.Player) -> (u8, bool) {
	king := player == .White ? chess.Piece.WK : chess.Piece.BK
	for sq: u8 = 0; sq < 30; sq += 1 {
		if board[sq] == king { return sq, true }
	}
	return 0, false
}

king_is_attacked :: proc(board: chess.Board, player: chess.Player) -> bool {
	king_sq, ok := find_king(board, player)
	if !ok { return false }
	opp := chess.opponent(player)
	opp_attacks := attacks_for_color(board, opp)
	return int(king_sq) in opp_attacks
}

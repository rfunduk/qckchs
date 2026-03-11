package mimir

import "core:math/rand"

import "../chess"

// Direct port of eval.py evaluate()

FROZEN_PAWN_VALUE :: 10
ROOK_OPEN_FILE_BONUS :: 40
ROOK_SEMI_OPEN_FILE_BONUS :: 25
KING_PASSER_DISTANCE_WEIGHT :: 10

// --- Frozen pawn detection ---

is_frozen_pawn :: proc(board: chess.Board, sq: u8, player: chess.Player) -> bool {
	file := i16(sq % chess.FILES)
	rank := i16(sq / chess.FILES)

	// Direction: white pawns go to lower rows (-1), black to higher (+1)
	dir: i16 = player == .White ? -1 : 1
	nr := rank + dir
	if nr < 0 || nr >= i16(chess.RANKS) { return false } 	// about to promote

	// Forward clear?
	fwd_sq := u8(nr) * chess.FILES + u8(file)
	if board[fwd_sq] == .X { return false }

	// Any diagonal capture?
	enemy := chess.opponent(player)
	for df in ([2]i16{-1, 1}) {
		nf := file + df
		if nf < 0 || nf >= i16(chess.FILES) { continue }
		cap_sq := u8(nr) * chess.FILES + u8(nf)
		if chess.piece_owner(board[cap_sq]) == enemy { return false }
	}

	// Forward blocked AND no capture available
	return true
}

// --- Passed pawn detection ---

is_passed_pawn :: proc(board: chess.Board, sq: u8, player: chess.Player) -> bool {
	file := i16(sq % chess.FILES)
	rank := i16(sq / chess.FILES)
	dir: i16 = player == .White ? -1 : 1
	enemy_pawn: chess.Piece = player == .White ? .BP : .WP

	nr := rank + dir
	for nr >= 0 && nr < i16(chess.RANKS) {
		for df in ([3]i16{-1, 0, 1}) {
			nf := file + df
			if nf < 0 || nf >= i16(chess.FILES) { continue }
			check_sq := u8(nr) * chess.FILES + u8(nf)
			if board[check_sq] == enemy_pawn { return false }
		}
		nr += dir
	}
	return true
}

// --- File has pawn ---

file_has_pawn :: proc(board: chess.Board, file: u8, pawn: chess.Piece) -> bool {
	for rank: u8 = 0; rank < chess.RANKS; rank += 1 {
		if board[rank * chess.FILES + file] == pawn { return true }
	}
	return false
}

// --- Drawish position detection (server rules, not learnable) ---

is_drawish :: proc(board: chess.Board) -> bool {
	w_piece_count: i32 = 0
	b_piece_count: i32 = 0
	w_has_only_bishop := true
	b_has_only_bishop := true

	for sq: u8 = 0; sq < 30; sq += 1 {
		p := board[sq]
		if p == .X || p in chess.Kings { continue }

		p_white := p in chess.White_Pieces

		if p in chess.Pawns {
			piece_player: chess.Player = p_white ? .White : .Black
			if !is_frozen_pawn(board, sq, piece_player) {
				// Non-frozen pawn exists — not drawish
				return false
			}
			continue
		}

		// Non-pawn, non-king piece
		if p_white {
			w_piece_count += 1
			if p != .WB { w_has_only_bishop = false }
		} else {
			b_piece_count += 1
			if p != .BB { b_has_only_bishop = false }
		}
	}

	// K vs K (only frozen pawns)
	if w_piece_count == 0 && b_piece_count == 0 {
		return true
	}
	// K+B vs K+B
	if w_piece_count == 1 && b_piece_count == 1 && w_has_only_bishop && b_has_only_bishop {
		return true
	}
	// K vs K+minor
	if w_piece_count == 0 && b_piece_count == 1 {
		for sq: u8 = 0; sq < 30; sq += 1 {
			if board[sq] == .BN || board[sq] == .BB { return true }
		}
	} else if b_piece_count == 0 && w_piece_count == 1 {
		for sq: u8 = 0; sq < 30; sq += 1 {
			if board[sq] == .WN || board[sq] == .WB { return true }
		}
	}

	return false
}

// --- Main evaluation (dispatches to NNUE or HCE) ---

evaluate :: proc(board: chess.Board, player: chess.Player, noise: i32 = 0) -> i32 {
	// Drawish detection first — server rules, not learnable
	if is_drawish(board) {
		return 0
	}

	score: i32
	// NNUE if available, otherwise fall back to HCE
	if nnue_weights.loaded {
		score = nnue_evaluate(board, player)
	} else {
		score = evaluate_hce(board, player)
	}

	if noise > 0 {
		score += i32(rand.int_max(int(noise * 2 + 1))) - noise
	}

	return score
}

// --- Handcrafted evaluation ---

evaluate_hce :: proc(board: chess.Board, player: chess.Player) -> i32 {
	opp := chess.opponent(player)
	score: i32 = 0

	// Piece tracking for drawishness
	w_piece_count: i32 = 0 // non-king, non-frozen white mobile pieces
	b_piece_count: i32 = 0
	w_bishop_sq: i32 = -1
	b_bishop_sq: i32 = -1
	w_has_only_bishop := true
	b_has_only_bishop := true

	total_non_pawn_material: i32 = 0
	w_king_sq: i32 = -1
	b_king_sq: i32 = -1

	pawn_bonus: i32 = 0

	// Rook/passer tracking (stack arrays)
	w_rook_count: u8 = 0
	b_rook_count: u8 = 0
	w_rooks: [4]u8
	b_rooks: [4]u8
	w_passer_count: u8 = 0
	b_passer_count: u8 = 0
	w_passers: [10]u8
	b_passers: [10]u8

	for sq: u8 = 0; sq < 30; sq += 1 {
		p := board[sq]
		if p == .X { continue }

		val := piece_values[p]
		pst_val := piece_pst(p, sq)
		p_white := p in chess.White_Pieces

		if p == .WK || p == .BK {
			if p_white {
				w_king_sq = i32(sq)
			} else {
				b_king_sq = i32(sq)
			}
		} else if p in chess.Rooks {
			if p_white {
				if w_rook_count < 4 {
					w_rooks[w_rook_count] = sq
					w_rook_count += 1
				}
			} else {
				if b_rook_count < 4 {
					b_rooks[b_rook_count] = sq
					b_rook_count += 1
				}
			}
		}

		if !(p in chess.Pawns) && !(p in chess.Kings) {
			total_non_pawn_material += piece_values[p]
		}

		// Frozen pawn handling
		is_frozen := false
		piece_player: chess.Player = p_white ? .White : .Black
		if p in chess.Pawns && is_frozen_pawn(board, sq, piece_player) {
			val = FROZEN_PAWN_VALUE
			is_frozen = true
		} else if !(p in chess.Kings) {
			if p_white {
				w_piece_count += 1
				if p == .WB {
					w_bishop_sq = i32(sq)
				} else {
					w_has_only_bishop = false
				}
			} else {
				b_piece_count += 1
				if p == .BB {
					b_bishop_sq = i32(sq)
				} else {
					b_has_only_bishop = false
				}
			}
		}

		// Passed pawn / mobile pawn bonus
		if p in chess.Pawns && !is_frozen {
			rank := idx_to_rank(sq) // 1..6
			effective_rank: u8
			if p_white {
				effective_rank = rank
			} else {
				effective_rank = chess.RANKS + 1 - rank
			}

			if is_passed_pawn(board, sq, piece_player) {
				bonus := passed_pawn_bonus[effective_rank]
				if p_white {
					if w_passer_count < 10 {
						w_passers[w_passer_count] = sq
						w_passer_count += 1
					}
				} else {
					if b_passer_count < 10 {
						b_passers[b_passer_count] = sq
						b_passer_count += 1
					}
				}
				if (player == .White) == p_white {
					pawn_bonus += bonus
				} else {
					pawn_bonus -= bonus
				}
			} else {
				bonus := mobile_pawn_bonus[effective_rank]
				if (player == .White) == p_white {
					pawn_bonus += bonus
				} else {
					pawn_bonus -= bonus
				}
			}
		}

		// Material + PST
		if (player == .White) == p_white {
			score += val + pst_val
		} else {
			score -= val + pst_val
		}
	}

	score += pawn_bonus

	// Endgame king centralization
	if total_non_pawn_material <= ENDGAME_MATERIAL_THRESHOLD {
		if w_king_sq >= 0 {
			eg_idx := u8(w_king_sq)
			mg_val := pst_king[eg_idx]
			eg_val := pst_king_endgame[eg_idx]
			delta := eg_val - mg_val
			if player == .White {
				score += delta
			} else {
				score -= delta
			}
		}
		if b_king_sq >= 0 {
			eg_idx := mirror[u8(b_king_sq)]
			mg_val := pst_king[eg_idx]
			eg_val := pst_king_endgame[eg_idx]
			delta := eg_val - mg_val
			if player == .Black {
				score += delta
			} else {
				score -= delta
			}
		}
	}

	// Rook on open/semi-open file
	for i: u8 = 0; i < w_rook_count; i += 1 {
		f := w_rooks[i] % chess.FILES
		has_own := file_has_pawn(board, f, .WP)
		has_opp := file_has_pawn(board, f, .BP)
		bonus: i32 = 0
		if !has_own && !has_opp {
			bonus = ROOK_OPEN_FILE_BONUS
		} else if !has_own {
			bonus = ROOK_SEMI_OPEN_FILE_BONUS
		}
		if player == .White {
			score += bonus
		} else {
			score -= bonus
		}
	}
	for i: u8 = 0; i < b_rook_count; i += 1 {
		f := b_rooks[i] % chess.FILES
		has_own := file_has_pawn(board, f, .BP)
		has_opp := file_has_pawn(board, f, .WP)
		bonus: i32 = 0
		if !has_own && !has_opp {
			bonus = ROOK_OPEN_FILE_BONUS
		} else if !has_own {
			bonus = ROOK_SEMI_OPEN_FILE_BONUS
		}
		if player == .Black {
			score += bonus
		} else {
			score -= bonus
		}
	}

	// King proximity to passed pawns (endgame only)
	if total_non_pawn_material <= ENDGAME_MATERIAL_THRESHOLD {
		for i: u8 = 0; i < w_passer_count; i += 1 {
			psq := w_passers[i]
			if b_king_sq >= 0 {
				dist := chebyshev(u8(b_king_sq), psq)
				if player == .White {
					score += dist * KING_PASSER_DISTANCE_WEIGHT
				} else {
					score -= dist * KING_PASSER_DISTANCE_WEIGHT
				}
			}
			if w_king_sq >= 0 {
				dist := chebyshev(u8(w_king_sq), psq)
				if player == .White {
					score -= dist * KING_PASSER_DISTANCE_WEIGHT
				} else {
					score += dist * KING_PASSER_DISTANCE_WEIGHT
				}
			}
		}
		for i: u8 = 0; i < b_passer_count; i += 1 {
			psq := b_passers[i]
			if w_king_sq >= 0 {
				dist := chebyshev(u8(w_king_sq), psq)
				if player == .Black {
					score += dist * KING_PASSER_DISTANCE_WEIGHT
				} else {
					score -= dist * KING_PASSER_DISTANCE_WEIGHT
				}
			}
			if b_king_sq >= 0 {
				dist := chebyshev(u8(b_king_sq), psq)
				if player == .Black {
					score -= dist * KING_PASSER_DISTANCE_WEIGHT
				} else {
					score += dist * KING_PASSER_DISTANCE_WEIGHT
				}
			}
		}
	}

	// Mobility
	our_attacks := attacks_for_color(board, player)
	opp_attacks := attacks_for_color(board, opp)
	score += 3 * (i32(card(our_attacks)) - i32(card(opp_attacks)))

	// King safety
	our_king_sq, our_ok := find_king(board, player)
	opp_king_sq, opp_ok := find_king(board, opp)
	if our_ok && int(our_king_sq) in opp_attacks {
		score -= 50
	}
	if opp_ok && int(opp_king_sq) in our_attacks {
		score += 50
	}

	return score
}

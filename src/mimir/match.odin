package mimir

import sa "core:container/small_array"
import "core:fmt"
import "core:math"

import "../chess"

engine_label :: proc(eng: ^Engine) -> string {
	if eng.nnue != nil {
		return "NNUE"
	}
	return "HCE"
}

// Play a single game between white_eng (white) and black_eng (black).
// Returns: 1.0 = white wins, 0.0 = black wins, 0.5 = draw.
play_match_game :: proc(white_eng, black_eng: ^Engine, board_start: chess.Board, depth: i32) -> f32 {
	board := board_start
	player: chess.Player = .White
	no_progress: i32 = 0
	pos_hashes: Position_Hashes

	for {
		eng := player == .White ? white_eng : black_eng

		// Reset engine state per position (no carryover)
		eng.has_prev = false
		eng.halfmove_clock = 0

		best_move := pick_best_move(eng, board, player, 9999, 0, depth)
		if best_move == NULL_MOVE {
			return player == .White ? 0.0 : 1.0
		}

		piece := board[move_from(best_move)]
		captured := board[move_to(best_move)]
		is_capture := captured != .X
		is_pawn := piece in chess.Pawns
		board = apply_move(board, best_move)
		opp := chess.opponent(player)

		if !has_king(board, opp) {
			return player == .White ? 1.0 : 0.0
		}

		if is_capture || is_pawn {
			no_progress = 0
			sa.clear(&pos_hashes)
		} else {
			no_progress += 1
		}

		h := chess.board_hash(board, opp)
		if sa.len(pos_hashes) >= 256 { sa.pop_front(&pos_hashes) }
		sa.push_back(&pos_hashes, h)

		if (is_capture || is_pawn) && chess.is_insufficient_material(board, opp) {
			return 0.5
		}
		if chess.is_threefold_repetition(sa.slice(&pos_hashes)) || no_progress >= chess.NO_PROGRESS_THRESHOLD {
			return 0.5
		}

		player = opp
	}
}

run_match :: proc(eng1, eng2: ^Engine, depth: i32, count: i32) {
	eng1.selfplay = true
	eng2.selfplay = true

	label1 := engine_label(eng1)
	label2 := engine_label(eng2)

	num_matches := count
	if num_matches <= 0 { num_matches = 5 }
	fmt.eprintfln("Playing %d matches (%d games)", num_matches, num_matches * 2)

	e1_wins: i32 = 0
	e2_wins: i32 = 0
	draws: i32 = 0

	total_games := num_matches * 2
	game_num: i32 = 0

	for m: i32 = 0; m < num_matches; m += 1 {
		board := chess.random_board()

		for swap in ([2]bool{false, true}) {
			game_num += 1
			w_eng := swap ? eng2 : eng1
			b_eng := swap ? eng1 : eng2
			w_label := swap ? label2 : label1
			b_label := swap ? label1 : label2

			result := play_match_game(w_eng, b_eng, board, depth)

			// White win = the engine playing white won
			w_is_e1 := !swap
			if result == 1.0 {
				if w_is_e1 { e1_wins += 1 } else { e2_wins += 1 }
				fmt.eprintfln("Game %d/%d: %s(W) vs %s(B) → %s wins", game_num, total_games, w_label, b_label, w_label)
			} else if result == 0.0 {
				if w_is_e1 { e2_wins += 1 } else { e1_wins += 1 }
				fmt.eprintfln("Game %d/%d: %s(W) vs %s(B) → %s wins", game_num, total_games, w_label, b_label, b_label)
			} else {
				draws += 1
				fmt.eprintfln("Game %d/%d: %s(W) vs %s(B) → draw", game_num, total_games, w_label, b_label)
			}
		}
	}

	played := e1_wins + e2_wins + draws
	fmt.eprintfln("\n--- Results ---")
	fmt.eprintfln("E1 (%s): %d wins", label1, e1_wins)
	fmt.eprintfln("E2 (%s): %d wins", label2, e2_wins)
	fmt.eprintfln("Draws: %d", draws)

	if played > 0 {
		score := (f64(e1_wins) + f64(draws) * 0.5) / f64(played)
		if score > 0.0 && score < 1.0 {
			elo := -400.0 * math.log10(1.0 / score - 1.0)
			se := math.sqrt(score * (1.0 - score) / f64(played))
			// Propagate SE through elo formula: d(elo)/d(score) = 400 / (ln(10) * score * (1-score))
			elo_se := 400.0 / (math.ln(f64(10.0)) * score * (1.0 - score)) * se
			fmt.eprintfln("Elo difference (E1 vs E2): %+.0f ± %.0f", elo, elo_se)
		} else if score == 1.0 {
			fmt.eprintfln("Elo difference: E1 wins all games")
		} else {
			fmt.eprintfln("Elo difference: E2 wins all games")
		}
	}

}

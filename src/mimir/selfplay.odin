package mimir

import sa "core:container/small_array"
import "core:fmt"

import "../chess"

Position_Hashes :: sa.Small_Array(256, u32)

// --- Selfplay position record ---

Selfplay_Pos :: struct {
	board:  chess.Board,
	player: chess.Player,
	score:  i32,
}

// --- Main selfplay loop ---

run_selfplay :: proc(eng: ^Engine, depth: i32, num_games: i32) {
	eng.selfplay = true
	total_positions := 0
	game := 0
	for num_games <= 0 || i32(game) < num_games {
		game += 1
		board := chess.random_board()
		player: chess.Player = .White
		positions: [dynamic]Selfplay_Pos
		defer delete(positions)
		no_progress: i32 = 0
		pos_hashes: Position_Hashes

		result: f32
		game_over := false

		for !game_over {
			// Reset engine state for each position (no carryover between games)
			eng.has_prev = false
			eng.halfmove_clock = 0

			best_move := pick_best_move(eng, board, player, 9999, 0, depth)
			if best_move == NULL_MOVE {
				// No legal moves — treat as loss for side to move
				result = player == .White ? 0.0 : 1.0
				break
			}
			score := eng.last_score

			append(&positions, Selfplay_Pos{board, player, score})

			// Apply move, detect captures and pawn moves
			piece := board[move_from(best_move)]
			captured := board[move_to(best_move)]
			is_capture := captured != .X
			is_pawn := piece in chess.Pawns
			board = apply_move(board, best_move)
			opp := chess.opponent(player)

			// King captured?
			if !has_king(board, opp) {
				result = player == .White ? 1.0 : 0.0
				game_over = true
				break
			}

			// Progress tracking
			if is_capture || is_pawn {
				no_progress = 0
				sa.clear(&pos_hashes)
			} else {
				no_progress += 1
			}

			// Record position hash
			h := chess.board_hash(board, opp)
			if sa.len(pos_hashes) >= 256 { sa.pop_front(&pos_hashes) }
			sa.push_back(&pos_hashes, h)

			// Draw checks (server order: games.odin:223-237)
			if (is_capture || is_pawn) && chess.is_insufficient_material(board, opp) {
				result = 0.5
				game_over = true
				break
			}
			if chess.is_threefold_repetition(sa.slice(&pos_hashes)) || no_progress >= chess.NO_PROGRESS_THRESHOLD {
				result = 0.5
				game_over = true
				break
			}

			player = opp
		}

		// Flush game positions
		for pos in positions {
			board_str: [30]u8
			for sq: u8 = 0; sq < 30; sq += 1 {
				board_str[sq] = chess.piece_char(pos.board[sq])
			}
			color_str := pos.player == .White ? "white" : "black"
			result_str: string
			if result == 1.0 {
				result_str = "1.0"
			} else if result == 0.0 {
				result_str = "0.0"
			} else {
				result_str = "0.5"
			}
			fmt.printfln("%s %s | %d | %s", string(board_str[:]), color_str, pos.score, result_str)
		}
		total_positions += len(positions)
		result_tag := result == 1.0 ? "white" : (result == 0.0 ? "black" : "draw")
		if num_games > 0 {
			fmt.eprintfln(
				"  game %d/%d  %s in %d moves  (%d positions total)",
				game,
				num_games,
				result_tag,
				len(positions),
				total_positions,
			)
		} else {
			fmt.eprintfln(
				"  game %d  %s in %d moves  (%d positions total)",
				game,
				result_tag,
				len(positions),
				total_positions,
			)
		}
	}
}

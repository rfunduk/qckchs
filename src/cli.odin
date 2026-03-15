package qckchs

import "core:fmt"

import "chess"
import "mimir"

cli_lookup_game :: proc(code: string) {
	engine_init()
	defer cleanup()
	db_init()
	defer db_shutdown()

	id, ok := game_id_from_code(code)
	if !ok {
		fmt.eprintfln("Invalid game code: %s", code)
		return
	}

	game, found := db_load_finished_game(id)
	if !found {
		fmt.eprintfln("Game %s (id=%d) not found", code, id)
		return
	}
	defer delete(game.moves)
	defer delete(game.white_name)
	defer delete(game.black_name)

	fmt.printfln("Game %s (#%d)", code, id)
	fmt.printfln("White:  %s", len(game.white_name) > 0 ? game.white_name : "(unknown)")
	fmt.printfln("Black:  %s", len(game.black_name) > 0 ? game.black_name : "(unknown)")
	fmt.printfln("State:  %v", game.state)
	if game.result != .In_Progress {
		fmt.printfln("Result: %s", result_string(game.result))
	}
	fmt.printfln("Clock:  W=%d  B=%d", game.clock.white_periods, game.clock.black_periods)
	fmt.println()

	// Board
	fmt.println("  a b c d e")
	for r: u8 = 0; r < chess.RANKS; r += 1 {
		fmt.printf("%d", chess.RANKS - r)
		for f: u8 = 0; f < chess.FILES; f += 1 {
			p := game.board[r * chess.FILES + f]
			fmt.printf(" %c", p == .X ? '.' : chess.piece_char(p))
		}
		fmt.println()
	}
	fmt.println()

	// Moves
	if len(game.moves) > 0 {
		san := chess.moves_algebraic(game.initial_board, game.moves[:])
		defer {
			for m in san { delete(m) }
			delete(san)
		}
		for m, i in san {
			if i % 2 == 0 {
				fmt.printf("%d. %-6s", i / 2 + 1, m)
			} else {
				fmt.printfln(" %s", m)
			}
		}
		if len(san) % 2 != 0 { fmt.println() }
	}
}

cli_lookup_player :: proc(code: string) {
	engine_init()
	defer cleanup()
	db_init()
	defer db_shutdown()

	player_id, ok := player_id_from_code(code)
	if !ok {
		fmt.eprintfln("Invalid player code: %s", code)
		return
	}

	pk, found := db_get_player_key(player_id)
	if !found {
		fmt.eprintfln("Player %s (id=%d) not found", code, player_id)
		return
	}

	name := db_get_player_name(pk)
	defer delete(name)
	stats := db_get_player_stats(pk)

	fmt.printfln("Player %s (#%d)", code, player_id)
	fmt.printfln("Name:   %s", len(name) > 0 ? name : "(unnamed)")
	fmt.printfln("Played: %d  Wins: %d  Losses: %d  Draws: %d", stats.played, stats.wins, stats.losses, stats.draws)
	fmt.println()

	games := db_get_player_games(pk)
	defer {
		for &g in games {
			delete(g.code)
			delete(g.squares)
			delete(g.white.name)
			delete(g.black.name)
		}
		delete(games)
	}

	if len(games) > 0 {
		fmt.printfln("Recent games (%d):", len(games))
		for &g in games {
			w_marker := g.white.has_won ? "*" : " "
			b_marker := g.black.has_won ? "*" : " "
			fmt.printfln("  %s  %s%s vs %s%s", g.code, w_marker, g.white.name, b_marker, g.black.name)
		}
	}
}

cli_selfplay :: proc(games: i32, depth: i32) {
	chess.init()
	mimir.init()
	defer mimir.destroy()

	eng := mimir.engine_create()
	defer mimir.engine_destroy(eng)

	mimir.run_selfplay(eng, depth, games)
}

package qckchs

import "core:fmt"
import "core:log"
import "core:strings"

import mustache "lib:mustache4c"

import "chess"


template_strings: map[string]string
compiled_pages: map[string]mustache.Template
compiled_partials: map[string]mustache.Template
compiled_layout: mustache.Template

Square_Data :: struct {
	piece:     chess.Piece,
	index:     u8,
	has_piece: bool,
	targets:   string,
	hl_from:   bool,
	hl_to:     bool,
}

Game_Player_Data :: struct {
	name:    string,
	code:    string,
	periods: u16,
	has_won: bool,
}

Game_Page_Data :: struct {
	using assets: Asset_Paths,
	game_id:      Game_Id,
	code:         string,
	active:       bool,
	squares:      []Square_Data,
	result:       string,
	turn:         string,
	state:        string,
	white:        Game_Player_Data,
	black:        Game_Player_Data,
	color:        string,
	max_ply:      int,
	paired:       int,
}

Mini_Square_Data :: struct {
	piece:     chess.Piece,
	has_piece: bool,
}

Mini_Game_Data :: struct {
	using assets: Asset_Paths,
	game_id:      Game_Id,
	code:         string,
	squares:      []Mini_Square_Data,
	white:        Game_Player_Data,
	black:        Game_Player_Data,
}

Index_Page_Data :: struct {
	using assets: Asset_Paths,
	games:        []Mini_Game_Data,
}

Profile_Page_Data :: struct {
	using assets: Asset_Paths,
	edit_profile: bool,
	name:         string,
	pk:           string,
	pk_full:      string,
	claimed:      bool,
	saved:        bool,
	next:         string,
	played:       int,
	wins:         int,
	losses:       int,
	draws:        int,
	games:        []Mini_Game_Data,
	player_code:  string,
}

build_mini_squares :: proc(board: chess.Board, flipped: bool) -> []Mini_Square_Data {
	squares := new([chess.RANKS * chess.FILES]Mini_Square_Data)
	for sq in 0 ..< chess.RANKS * chess.FILES {
		board_idx := flipped ? u8(chess.RANKS * chess.FILES - 1 - sq) : u8(sq)
		piece := board[board_idx]
		squares[sq] = {
			piece     = piece,
			has_piece = piece != .X,
		}
	}
	return squares[:]
}

build_mini_game_data :: proc(id: Game_Id, game: ^Game, flipped: bool) -> Mini_Game_Data {
	w := Game_Player_Data {
		name    = game.white_name,
		has_won = game.result in White_Wins,
	}
	b := Game_Player_Data {
		name    = game.black_name,
		has_won = game.result in Black_Wins,
	}
	return Mini_Game_Data {
		assets = g_assets,
		game_id = id,
		code = game_code(id),
		squares = build_mini_squares(game.board, flipped),
		white = flipped ? b : w,
		black = flipped ? w : b,
	}
}

render_mini_game :: proc(id: Game_Id, game: ^Game, flipped: bool) -> (string, bool) {
	data := build_mini_game_data(id, game, flipped)
	return render_partial("_miniboard", data)
}

render_lobby_game :: proc(id: Game_Id, game: ^Game) -> (string, bool) {
	return render_mini_game(id, game, false)
}

board_squares :: proc(board: chess.Board, viewer: chess.Player) -> [chess.RANKS * chess.FILES]Square_Data {
	result: [chess.RANKS * chess.FILES]Square_Data

	viewer_pieces: chess.Pieces
	switch viewer {
	case .White:
		viewer_pieces = chess.White_Pieces
	case .Black:
		viewer_pieces = chess.Black_Pieces
	case .None:
		viewer_pieces = {}
	}

	for sq in 0 ..< chess.RANKS * chess.FILES {
		board_idx := viewer == .Black ? (chess.RANKS * chess.FILES - 1 - sq) : sq
		piece := board[board_idx]

		targets_str: string
		if piece in viewer_pieces {
			targets := chess.piece_targets(board, board_idx)
			targets_str = format_targets(targets)
		}

		result[sq] = {
			piece     = piece,
			index     = board_idx,
			has_piece = piece != .X,
			targets   = targets_str,
		}
	}
	return result
}

board_squares_at_ply :: proc(
	initial_board: chess.Board,
	moves: []chess.Move,
	ply: int,
	viewer: chess.Player,
) -> [chess.RANKS * chess.FILES]Square_Data {
	board := initial_board
	for i in 0 ..< ply { chess.apply_move(&board, moves[i]) }

	result: [chess.RANKS * chess.FILES]Square_Data
	for sq in 0 ..< chess.RANKS * chess.FILES {
		board_idx := viewer == .Black ? (chess.RANKS * chess.FILES - 1 - sq) : sq
		piece := board[board_idx]
		result[sq] = {
			piece     = piece,
			index     = board_idx,
			has_piece = piece != .X,
		}
	}

	if ply > 0 {
		move := moves[ply - 1]
		for sq in 0 ..< chess.RANKS * chess.FILES {
			board_idx := viewer == .Black ? u8(chess.RANKS * chess.FILES - 1 - sq) : u8(sq)
			if board_idx == move.from {
				result[sq].hl_from = true
			}
			if board_idx == move.to {
				result[sq].hl_to = true
			}
		}
	}

	return result
}

format_targets :: proc(targets: chess.Targets) -> string {
	b := strings.builder_make()
	first := true
	for idx: u8 = 0; idx < chess.RANKS * chess.FILES; idx += 1 {
		if int(idx) in targets {
			if !first { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, "%d", int(idx))
			first = false
		}
	}
	return strings.to_string(b)
}

render_board :: proc(game: ^Game, viewer: chess.Player) -> (string, bool) {
	squares := board_squares(game.board, viewer)
	data: Game_Page_Data = {
		assets  = g_assets,
		squares = squares[:],
	}
	return render_partial("_board", data)
}

load_templates :: proc() {
	template_strings = load_template_strings()

	layout_str, has_layout := template_strings["layout"]
	if !has_layout {
		log.errorf("No layout template found")
		return
	}
	compiled_layout = mustache.compile(layout_str)
	if compiled_layout == nil {
		log.errorf("Failed to compile layout template")
	}

	partial_strs := make(map[string]string)
	compiled_pages = make(map[string]mustache.Template)
	for key, content in template_strings {
		if key == "layout" { continue }
		if strings.has_prefix(key, "partials/") {
			partial_strs[strings.trim_prefix(key, "partials/")] = content
		} else {
			t := mustache.compile(content)
			if t == nil {
				log.errorf("Failed to compile template: %s", key)
			} else {
				compiled_pages[key] = t
			}
		}
	}
	compiled_partials = mustache.compile_partials(partial_strs)
	delete(partial_strs)

	log.infof("Loaded %d templates", len(template_strings))
}

cleanup_templates :: proc() {
	for _, t in compiled_pages {
		mustache.release(t)
	}
	delete(compiled_pages)
	mustache.release_partials(compiled_partials)
	mustache.release(compiled_layout)
	delete(template_strings)
}

render_partial :: proc(partial_name: string, data: any) -> (string, bool) {
	t, found := compiled_partials[partial_name]
	if !found {
		log.errorf("Partial not found: %s", partial_name)
		return "", false
	}

	output, ok := mustache.render(t, data, compiled_partials)
	if !ok {
		log.errorf("Failed to render partial %s", partial_name)
		return "", false
	}

	return output, true
}

render_template :: proc(name: string, data: any) -> (string, bool) {
	t, found := compiled_pages[name]
	if !found {
		log.errorf("Template not found: %s", name)
		return "", false
	}

	if compiled_layout == nil {
		log.errorf("Layout template not available")
		return "", false
	}

	output, ok := mustache.render_in_layout(t, data, compiled_layout, compiled_partials)
	if !ok {
		log.errorf("Failed to render template: %s", name)
		return "", false
	}

	return output, true
}

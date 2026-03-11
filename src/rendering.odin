package qckchs

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import mustache "lib:mustache4c"

import "chess"


Asset_Paths :: struct {
	favicon:       string,
	css_normalize: string,
	css_main:      string,
	js_datastar:   string,
	js_utils:      string,
	js_board:      string,
	js_clock:      string,
	piece_hash:    string,
}

g_assets: Asset_Paths

template_strings: map[string]string
compiled_partials: map[string]mustache.Template
compiled_layout: mustache.Template

Square_Data :: struct {
	piece:     chess.Piece,
	index:     u8,
	has_piece: bool,
	targets:   string,
}

Game_Page_Data :: struct {
	using assets: Asset_Paths,
	code:         string,
	active:       bool,
	squares:      []Square_Data,
	result:       string,
	turn:         string,
	state:        string,
	wp:           u16,
	bp:           u16,
	wn:           string,
	bn:           string,
	color:        string,
}

Mini_Square_Data :: struct {
	piece:     chess.Piece,
	has_piece: bool,
}

Mini_Game_Data :: struct {
	using assets: Asset_Paths,
	code:         string,
	squares:      []Mini_Square_Data,
	wn:           string,
	bn:           string,
	w_win:        bool,
	b_win:        bool,
}

Index_Page_Data :: struct {
	using assets: Asset_Paths,
	games:        []Mini_Game_Data,
}

Profile_Page_Data :: struct {
	using assets: Asset_Paths,
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

render_mini_game :: proc(id: Game_Id, game: ^Game, flipped: bool) -> (string, bool) {
	code := game_code(id)
	wn := game.white_name
	bn := game.black_name
	w_win := game.result in White_Wins
	b_win := game.result in Black_Wins
	data := Mini_Game_Data {
		assets  = g_assets,
		code    = code,
		squares = build_mini_squares(game.board, flipped),
		wn      = flipped ? bn : wn,
		bn      = flipped ? wn : bn,
		w_win   = flipped ? b_win : w_win,
		b_win   = flipped ? w_win : b_win,
	}
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

load_asset_digest :: proc() {
	data, file_ok := os.read_entire_file("digest.json", global_context.allocator)
	if !file_ok { return }
	defer delete(data, global_context.allocator)

	digest: map[string]string
	uerr := json.unmarshal(data, &digest, allocator = global_context.allocator)
	if uerr != nil {
		log.errorf("Failed to parse digest.json")
		return
	}
	defer {
		for k, v in digest {
			delete(k, global_context.allocator)
			delete(v, global_context.allocator)
		}
		delete(digest)
	}

	clone :: proc(s: string) -> string {
		return strings.clone(s, global_context.allocator)
	}

	g_assets = Asset_Paths {
		favicon       = clone(digest["favicon.ico"] or_else ""),
		css_normalize = clone(digest["styles/modern-normalize.min.css"] or_else ""),
		css_main      = clone(digest["styles/qckchs.css"] or_else ""),
		js_datastar   = clone(digest["scripts/datastar.js"] or_else ""),
		js_utils      = clone(digest["scripts/utils.js"] or_else ""),
		js_board      = clone(digest["scripts/board.js"] or_else ""),
		js_clock      = clone(digest["scripts/clock.js"] or_else ""),
		piece_hash    = clone(digest["_piece_hash"] or_else ""),
	}

	log.infof("Loaded asset digest: piece_hash=%s", g_assets.piece_hash)
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
	for key, content in template_strings {
		if key == "layout" { continue }
		partial_key := strings.trim_prefix(key, "partials/")
		partial_strs[partial_key] = content
	}
	compiled_partials = mustache.compile_partials(partial_strs)
	delete(partial_strs)

	log.infof("Loaded %d templates", len(template_strings))
}

cleanup_asset_digest :: proc() {
	delete(g_assets.favicon, global_context.allocator)
	delete(g_assets.css_normalize, global_context.allocator)
	delete(g_assets.css_main, global_context.allocator)
	delete(g_assets.js_datastar, global_context.allocator)
	delete(g_assets.js_utils, global_context.allocator)
	delete(g_assets.js_board, global_context.allocator)
	delete(g_assets.js_clock, global_context.allocator)
	delete(g_assets.piece_hash, global_context.allocator)
}

cleanup_templates :: proc() {
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
	template_str, found := template_strings[name]
	if !found {
		log.errorf("Template not found: %s", name)
		return "", false
	}

	t := mustache.compile(template_str)
	if t == nil {
		log.errorf("Failed to compile template: %s", name)
		return "", false
	}
	defer mustache.release(t)

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

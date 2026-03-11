package tests

import src "../src"
import chess "../src/chess"
import t "core:testing"

// --- encode_id / decode_id ---

@(test)
test_encode_decode_game_id_roundtrip :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	for id in ([]src.Game_Id{0, 1, 42, 1000, 99999}) {
		code := src.game_code(id)
		decoded, ok := src.game_id_from_code(code)
		t.expect(test, ok)
		t.expect_value(test, decoded, id)
	}
}

@(test)
test_encode_decode_player_id_roundtrip :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	for id in ([]i64{0, 1, 42, 1000, 99999}) {
		code := src.player_code(id)
		decoded, ok := src.player_id_from_code(code)
		t.expect(test, ok)
		t.expect_value(test, decoded, id)
	}
}

@(test)
test_decode_invalid_code :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	_, ok1 := src.game_id_from_code("")
	t.expect(test, !ok1)

	_, ok2 := src.game_id_from_code("!!!")
	t.expect(test, !ok2)
}

@(test)
test_game_and_player_codes_differ :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	// Same numeric id should produce different codes for game vs player
	game_code := src.encode_id(42, .Game)
	player_code := src.encode_id(42, .Player)
	t.expect(test, game_code != player_code, "game and player codes should differ due to offsets")
}

// --- random_board ---

@(test)
test_random_board_valid :: proc(test: ^t.T) {
	board := chess.random_board()

	// Count pieces
	wk, wq, wr, wb, wn, wp: u8
	bk, bq, br, bb, bn, bp: u8
	empty: u8
	for sq in board {
		switch sq {
		case .WK:
			wk += 1
		case .WQ:
			wq += 1
		case .WR:
			wr += 1
		case .WB:
			wb += 1
		case .WN:
			wn += 1
		case .WP:
			wp += 1
		case .BK:
			bk += 1
		case .BQ:
			bq += 1
		case .BR:
			br += 1
		case .BB:
			bb += 1
		case .BN:
			bn += 1
		case .BP:
			bp += 1
		case .X:
			empty += 1
		}
	}

	// Each side: 1K, 1Q, 1R, 1B, 1N, 5P
	t.expect_value(test, wk, u8(1))
	t.expect_value(test, wq, u8(1))
	t.expect_value(test, wr, u8(1))
	t.expect_value(test, wb, u8(1))
	t.expect_value(test, wn, u8(1))
	t.expect_value(test, wp, u8(5))
	t.expect_value(test, bk, u8(1))
	t.expect_value(test, bq, u8(1))
	t.expect_value(test, br, u8(1))
	t.expect_value(test, bb, u8(1))
	t.expect_value(test, bn, u8(1))
	t.expect_value(test, bp, u8(5))
	t.expect_value(test, empty, u8(10))

	// Pawns on ranks 2 and 5
	for f: u8 = 0; f < chess.FILES; f += 1 {
		t.expect_value(test, board[f + chess.FILES], chess.Piece.BP)
		t.expect_value(test, board[f + 4 * chess.FILES], chess.Piece.WP)
	}

	// Middle ranks empty
	for sq: u8 = 10; sq < 20; sq += 1 {
		t.expect_value(test, board[sq], chess.Piece.X)
	}

	// Back rank pieces mirror: same piece type on each file
	for f: u8 = 0; f < chess.FILES; f += 1 {
		w := board[f + 5 * chess.FILES]
		b := board[f]
		t.expect_value(test, chess.piece_owner(w), chess.Player.White)
		t.expect_value(test, chess.piece_owner(b), chess.Player.Black)
	}
}

// --- path_params ---

@(test)
test_path_params_basic :: proc(test: ^t.T) {
	params, ok := src.path_params("/game/abc123/move", "/game/", 2)
	t.expect(test, ok)
	t.expect_value(test, params[0], "abc123")
	t.expect_value(test, params[1], "move")
}

@(test)
test_path_params_single :: proc(test: ^t.T) {
	params, ok := src.path_params("/game/abc", "/game/", 1)
	t.expect(test, ok)
	t.expect_value(test, params[0], "abc")
}

@(test)
test_path_params_prefix_mismatch :: proc(test: ^t.T) {
	_, ok := src.path_params("/other/abc", "/game/", 1)
	t.expect(test, !ok)
}

@(test)
test_path_params_wrong_count :: proc(test: ^t.T) {
	_, ok := src.path_params("/game/abc", "/game/", 2)
	t.expect(test, !ok)
}

@(test)
test_path_params_too_many_segments :: proc(test: ^t.T) {
	_, ok := src.path_params("/game/a/b/c", "/game/", 2)
	t.expect(test, !ok)
}

// --- get_query_param ---

@(test)
test_get_query_param_basic :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	t.expect_value(test, src.get_query_param("foo=bar", "foo"), "bar")
}

@(test)
test_get_query_param_multiple :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	query := "a=1&b=2&c=3"
	t.expect_value(test, src.get_query_param(query, "a"), "1")
	t.expect_value(test, src.get_query_param(query, "b"), "2")
	t.expect_value(test, src.get_query_param(query, "c"), "3")
}

@(test)
test_get_query_param_missing :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	t.expect_value(test, src.get_query_param("foo=bar", "baz"), "")
}

@(test)
test_get_query_param_empty_query :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	t.expect_value(test, src.get_query_param("", "foo"), "")
}

@(test)
test_get_query_param_last_param :: proc(test: ^t.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)

	t.expect_value(test, src.get_query_param("a=1&next=/game/abc", "next"), "/game/abc")
}

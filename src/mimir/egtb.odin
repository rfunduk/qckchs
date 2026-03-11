package mimir

import "core:fmt"
import "core:os"

import "../chess"

// ---------------------------------------------------------------------------
// Endgame Tablebase probe
// ---------------------------------------------------------------------------

// Byte encoding (matches gen_egtb.py)
EGTB_INVALID :: 0
EGTB_DRAW :: 1
EGTB_WIN_BASE :: 2 // WIN_BASE + dtm - 1
EGTB_LOSS_BASE :: 128 // LOSS_BASE + dtm - 1
EGTB_MAX_DTM :: 126

// Score returned by probe
TB_WIN :: 30_000

// Header
EGTB_MAGIC :: "EGTB"
EGTB_VERSION :: 1
EGTB_HEADER_SIZE :: 64

// ---------------------------------------------------------------------------
// Table storage
// ---------------------------------------------------------------------------

EGTB_Table :: struct {
	num_pieces:  u8,
	piece_types: [12]chess.Piece, // ordered: wK, white pieces, bK, black pieces
	num_white:   u8, // how many of piece_types are white
	data:        []u8,
	table_size:  u64,
	file_data:   []u8, // original allocation from read_entire_file
}

// Global registry: material key -> table pointer
EGTB_MAX_TABLES :: 64
egtb_tables: [EGTB_MAX_TABLES]^EGTB_Table
egtb_keys: [EGTB_MAX_TABLES]u64
egtb_table_count: int
egtb_max_pieces: u8 // max piece count among loaded tables

// ---------------------------------------------------------------------------
// Material key: canonical hash of piece counts
// ---------------------------------------------------------------------------

// Piece value for normalization (stronger side = white)
egtb_piece_strength := [chess.Piece]i32 {
	.X  = 0,
	.WK = 0,
	.WQ = 900,
	.WR = 500,
	.WB = 330,
	.WN = 320,
	.WP = 100,
	.BK = 0,
	.BQ = 900,
	.BR = 500,
	.BB = 330,
	.BN = 320,
	.BP = 100,
}

// Map a colored piece to its abstract type index (K=0,Q=1,R=2,B=3,N=4,P=5)
piece_abstract :: proc(p: chess.Piece) -> u8 {
	switch p {
	case .WK, .BK:
		return 0
	case .WQ, .BQ:
		return 1
	case .WR, .BR:
		return 2
	case .WB, .BB:
		return 3
	case .WN, .BN:
		return 4
	case .WP, .BP:
		return 5
	case .X:
		return 0xFF
	}
	return 0xFF
}

// Compute material key from piece counts: [wK,wQ,wR,wB,wN,wP, bK,bQ,bR,bB,bN,bP]
material_key :: proc(counts: [12]u8) -> u64 {
	key: u64 = 0
	for i := 0; i < 12; i += 1 {
		key = key * 11 + u64(counts[i])
	}
	return key
}

// Count pieces on the board and return material key + piece count + normalized counts
board_material :: proc(board: chess.Board) -> (key: u64, piece_count: u8, counts: [12]u8, need_flip: bool) {
	// Count: [wK,wQ,wR,wB,wN,wP, bK,bQ,bR,bB,bN,bP]
	raw: [12]u8
	total: u8 = 0
	for sq: u8 = 0; sq < 30; sq += 1 {
		p := board[sq]
		if p == .X { continue }
		total += 1
		switch p {
		case .WK:
			raw[0] += 1
		case .WQ:
			raw[1] += 1
		case .WR:
			raw[2] += 1
		case .WB:
			raw[3] += 1
		case .WN:
			raw[4] += 1
		case .WP:
			raw[5] += 1
		case .BK:
			raw[6] += 1
		case .BQ:
			raw[7] += 1
		case .BR:
			raw[8] += 1
		case .BB:
			raw[9] += 1
		case .BN:
			raw[10] += 1
		case .BP:
			raw[11] += 1
		case .X: // handled above
		}
	}

	// Determine which side is "stronger" for normalization
	w_strength: i32 = 0
	b_strength: i32 = 0
	w_max_piece: i32 = 0
	b_max_piece: i32 = 0
	for i := 1; i < 6; i += 1 {
		vals := [6]i32{0, 900, 500, 330, 320, 100} // K,Q,R,B,N,P
		v := vals[i]
		w_strength += i32(raw[i]) * v
		b_strength += i32(raw[i + 6]) * v
		if raw[i] > 0 && v > w_max_piece { w_max_piece = v }
		if raw[i + 6] > 0 && v > b_max_piece { b_max_piece = v }
	}

	need_flip = false
	if b_strength > w_strength || (b_strength == w_strength && b_max_piece > w_max_piece) {
		need_flip = true
		// Swap white and black counts
		for i := 0; i < 6; i += 1 {
			raw[i], raw[i + 6] = raw[i + 6], raw[i]
		}
	}

	return material_key(raw), total, raw, need_flip
}

// ---------------------------------------------------------------------------
// Position encoding
// ---------------------------------------------------------------------------

encode_position :: proc(board: chess.Board, tbl: ^EGTB_Table, flipped: bool) -> (index: u64, ok: bool) {
	n := int(tbl.num_pieces)

	used: [30]bool
	squares: [12]u8

	for i := 0; i < n; i += 1 {
		expected := tbl.piece_types[i]
		if flipped {
			expected = flip_piece_color(expected)
		}

		found := false
		for sq: u8 = 0; sq < 30; sq += 1 {
			if used[sq] { continue }
			if board[sq] == expected {
				actual_sq := sq
				if flipped {
					actual_sq = mirror[sq]
				}
				squares[i] = actual_sq
				used[sq] = true
				found = true
				break
			}
		}
		if !found { return 0, false }
	}

	return encode_index_from_squares(squares[:n], tbl), true
}

encode_index_from_squares :: proc(squares: []u8, tbl: ^EGTB_Table) -> u64 {
	idx: u64 = 0
	for sq in squares {
		idx = idx * 30 + u64(sq)
	}
	return idx
}

flip_piece_color :: proc(p: chess.Piece) -> chess.Piece {
	switch p {
	case .WK:
		return .BK
	case .WQ:
		return .BQ
	case .WR:
		return .BR
	case .WB:
		return .BB
	case .WN:
		return .BN
	case .WP:
		return .BP
	case .BK:
		return .WK
	case .BQ:
		return .WQ
	case .BR:
		return .WR
	case .BB:
		return .WB
	case .BN:
		return .WN
	case .BP:
		return .WP
	case .X:
		return .X
	}
	return .X
}

// ---------------------------------------------------------------------------
// Probe
// ---------------------------------------------------------------------------

egtb_probe :: proc(board: chess.Board, player: chess.Player) -> (score: i32, found: bool) {
	key, piece_count, _, need_flip := board_material(board)

	if piece_count > egtb_max_pieces || piece_count < 2 {
		return 0, false
	}

	// Look up table
	tbl: ^EGTB_Table = nil
	for i := 0; i < egtb_table_count; i += 1 {
		if egtb_keys[i] == key {
			tbl = egtb_tables[i]
			break
		}
	}
	if tbl == nil { return 0, false }

	// Encode position
	idx, ok := encode_position(board, tbl, need_flip)
	if !ok { return 0, false }

	// Side to move: 0 = normalized white, 1 = normalized black
	side: u64 = 0
	if player == .White {
		side = need_flip ? 1 : 0
	} else {
		side = need_flip ? 0 : 1
	}

	// Final index: side * 30^N + piece squares
	table_half := tbl.table_size / 2
	final_idx := side * table_half + idx

	if final_idx >= tbl.table_size { return 0, false }

	val := tbl.data[final_idx]

	switch {
	case val == EGTB_INVALID:
		return 0, false
	case val == EGTB_DRAW:
		return 0, true
	case val >= EGTB_WIN_BASE && val < EGTB_LOSS_BASE:
		dtm := i32(val) - EGTB_WIN_BASE + 1
		return TB_WIN - dtm, true
	case val >= EGTB_LOSS_BASE:
		dtm := i32(val) - EGTB_LOSS_BASE + 1
		return -TB_WIN + dtm, true
	}

	return 0, false
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

destroy_egtb :: proc() {
	for i := 0; i < egtb_table_count; i += 1 {
		tbl := egtb_tables[i]
		if tbl != nil {
			delete(tbl.file_data)
			free(tbl)
		}
	}
	egtb_table_count = 0
}

init_egtb :: proc() {
	egtb_table_count = 0
	egtb_max_pieces = 0

	dh, err := os.open("egtb")
	if err == nil {
		defer os.close(dh)

		entries, read_err := os.read_dir(dh, 256)
		if read_err == nil {
			defer {
				for &entry in entries {
					os.file_info_delete(entry)
				}
				delete(entries)
			}

			for entry in entries {
				name := entry.name
				if len(name) < 5 { continue }
				if name[len(name) - 4:] != ".bin" { continue }
				load_egtb_file(fmt.tprintf("egtb/%s", name))
			}
		}
	}

	if egtb_table_count > 0 {
		fmt.eprintfln("EGTB: loaded %d tables (max %d pieces)", egtb_table_count, egtb_max_pieces)
	}
}

load_egtb_file :: proc(path: string) -> bool {
	if egtb_table_count >= EGTB_MAX_TABLES { return false }

	data, ok := os.read_entire_file(path)
	if !ok { return false }

	if len(data) < EGTB_HEADER_SIZE { return false }

	// Validate header
	if data[0] != 'E' || data[1] != 'G' || data[2] != 'T' || data[3] != 'B' {
		return false
	}
	if data[4] != EGTB_VERSION { return false }

	num_pieces := data[5]

	// Read piece types
	pieces: [12]chess.Piece
	piece_count: u8 = 0
	for i: u8 = 0; i < 12; i += 1 {
		v := data[6 + i]
		if v == 0xFF { break }
		pieces[i] = chess.Piece(v)
		piece_count += 1
	}

	if piece_count != num_pieces { return false }

	// Read table size (little-endian u64 at offset 18)
	tbl_size: u64 = 0
	for i: u64 = 0; i < 8; i += 1 {
		tbl_size |= u64(data[18 + i]) << (i * 8)
	}

	expected_total := u64(EGTB_HEADER_SIZE) + tbl_size
	if u64(len(data)) < expected_total { return false }

	// Determine num_white: count white pieces in the piece list
	num_white: u8 = 0
	for i: u8 = 0; i < piece_count; i += 1 {
		if pieces[i] in chess.White_Pieces {
			num_white += 1
		}
	}

	// Compute material key from the piece types
	counts: [12]u8
	for i: u8 = 0; i < piece_count; i += 1 {
		p := pieces[i]
		switch p {
		case .WK:
			counts[0] += 1
		case .WQ:
			counts[1] += 1
		case .WR:
			counts[2] += 1
		case .WB:
			counts[3] += 1
		case .WN:
			counts[4] += 1
		case .WP:
			counts[5] += 1
		case .BK:
			counts[6] += 1
		case .BQ:
			counts[7] += 1
		case .BR:
			counts[8] += 1
		case .BB:
			counts[9] += 1
		case .BN:
			counts[10] += 1
		case .BP:
			counts[11] += 1
		case .X: // skip
		}
	}

	key := material_key(counts)

	// Allocate table struct
	tbl := new(EGTB_Table)
	tbl.num_pieces = num_pieces
	tbl.piece_types = pieces
	tbl.num_white = num_white
	tbl.data = data[EGTB_HEADER_SIZE:][:tbl_size]
	tbl.table_size = tbl_size
	tbl.file_data = data

	idx := egtb_table_count
	egtb_tables[idx] = tbl
	egtb_keys[idx] = key
	egtb_table_count += 1

	if num_pieces > egtb_max_pieces {
		egtb_max_pieces = num_pieces
	}

	return true
}

package mimir

import "core:fmt"
import "core:os"

import "../chess"

// Input size is fixed by the board: 30 squares × 12 piece types
NNUE_INPUT_SIZE :: 360

NNUE_Weights :: struct {
	loaded:          bool,
	hidden_size:     int,
	qa:              i32,
	qb:              i32,
	feature_weights: []i16, // [INPUT_SIZE * hidden_size], feature-major
	feature_biases:  []i16, // [hidden_size]
	output_weights:  []i16, // [hidden_size]
	output_bias:     i16,
}

nnue_weights: NNUE_Weights

// --- Loading ---

read_i16_le :: proc(data: []u8, offset: int) -> i16 {
	return i16(u16(data[offset]) | (u16(data[offset + 1]) << 8))
}

read_u16_le :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | (u16(data[offset + 1]) << 8)
}

init_nnue :: proc(path: string = "mimir.nnue") {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("NNUE: %s not found, using HCE", path)
		return
	}
	defer delete(data)

	if len(data) < 16 {
		fmt.eprintln("NNUE: file too small")
		return
	}

	// Validate magic
	if data[0] != 'N' || data[1] != 'N' || data[2] != 'U' || data[3] != 'E' {
		fmt.eprintln("NNUE: invalid magic")
		return
	}

	// Read header fields
	version := data[4]
	input_size := int(read_u16_le(data[:], 5))
	hidden_size := int(read_u16_le(data[:], 7))
	qa := i32(read_u16_le(data[:], 9))
	qb := i32(read_u16_le(data[:], 11))

	if version != 1 {
		fmt.eprintfln("NNUE: unsupported version %d", version)
		return
	}
	if input_size != NNUE_INPUT_SIZE {
		fmt.eprintfln("NNUE: expected input_size=%d, got %d", NNUE_INPUT_SIZE, input_size)
		return
	}

	expected_size := 16 + input_size * hidden_size * 2 + hidden_size * 2 + hidden_size * 2 + 2
	if len(data) < expected_size {
		fmt.eprintfln("NNUE: file too small (need %d bytes, got %d)", expected_size, len(data))
		return
	}

	// Allocate weight arrays
	feature_weights := make([]i16, input_size * hidden_size)
	feature_biases := make([]i16, hidden_size)
	output_weights := make([]i16, hidden_size)

	offset := 16

	// Feature weights: [input_size][hidden_size] i16, stored feature-major
	for i in 0 ..< input_size * hidden_size {
		feature_weights[i] = read_i16_le(data[:], offset)
		offset += 2
	}

	// Feature biases: [hidden_size] i16
	for i in 0 ..< hidden_size {
		feature_biases[i] = read_i16_le(data[:], offset)
		offset += 2
	}

	// Output weights: [hidden_size] i16
	for i in 0 ..< hidden_size {
		output_weights[i] = read_i16_le(data[:], offset)
		offset += 2
	}

	// Output bias: i16
	output_bias := read_i16_le(data[:], offset)

	nnue_weights = NNUE_Weights {
		loaded          = true,
		hidden_size     = hidden_size,
		qa              = qa,
		qb              = qb,
		feature_weights = feature_weights,
		feature_biases  = feature_biases,
		output_weights  = output_weights,
		output_bias     = output_bias,
	}
	fmt.eprintfln("NNUE: loaded %s (%d→%d→1, QA=%d QB=%d)", path, input_size, hidden_size, qa, qb)
}

destroy_nnue :: proc() {
	if nnue_weights.loaded {
		delete(nnue_weights.feature_weights)
		delete(nnue_weights.feature_biases)
		delete(nnue_weights.output_weights)
		nnue_weights.loaded = false
	}
}

load_nnue_weights :: proc(path: string) -> (^NNUE_Weights, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("NNUE: %s not found", path)
		return nil, false
	}
	defer delete(data)

	if len(data) < 16 {
		fmt.eprintln("NNUE: file too small")
		return nil, false
	}

	if data[0] != 'N' || data[1] != 'N' || data[2] != 'U' || data[3] != 'E' {
		fmt.eprintln("NNUE: invalid magic")
		return nil, false
	}

	version := data[4]
	input_size := int(read_u16_le(data[:], 5))
	hidden_size := int(read_u16_le(data[:], 7))
	qa := i32(read_u16_le(data[:], 9))
	qb := i32(read_u16_le(data[:], 11))

	if version != 1 {
		fmt.eprintfln("NNUE: unsupported version %d", version)
		return nil, false
	}
	if input_size != NNUE_INPUT_SIZE {
		fmt.eprintfln("NNUE: expected input_size=%d, got %d", NNUE_INPUT_SIZE, input_size)
		return nil, false
	}

	expected_size := 16 + input_size * hidden_size * 2 + hidden_size * 2 + hidden_size * 2 + 2
	if len(data) < expected_size {
		fmt.eprintfln("NNUE: file too small (need %d bytes, got %d)", expected_size, len(data))
		return nil, false
	}

	feature_weights := make([]i16, input_size * hidden_size)
	feature_biases := make([]i16, hidden_size)
	output_weights := make([]i16, hidden_size)

	offset := 16
	for i in 0 ..< input_size * hidden_size {
		feature_weights[i] = read_i16_le(data[:], offset)
		offset += 2
	}
	for i in 0 ..< hidden_size {
		feature_biases[i] = read_i16_le(data[:], offset)
		offset += 2
	}
	for i in 0 ..< hidden_size {
		output_weights[i] = read_i16_le(data[:], offset)
		offset += 2
	}
	output_bias := read_i16_le(data[:], offset)

	w := new(NNUE_Weights)
	w^ = NNUE_Weights {
		loaded          = true,
		hidden_size     = hidden_size,
		qa              = qa,
		qb              = qb,
		feature_weights = feature_weights,
		feature_biases  = feature_biases,
		output_weights  = output_weights,
		output_bias     = output_bias,
	}
	fmt.eprintfln("NNUE: loaded %s (%d→%d→1, QA=%d QB=%d)", path, input_size, hidden_size, qa, qb)
	return w, true
}

destroy_nnue_weights :: proc(w: ^NNUE_Weights) {
	if w == nil { return }
	delete(w.feature_weights)
	delete(w.feature_biases)
	delete(w.output_weights)
	free(w)
}

// --- Inference ---

// Map Piece enum to NNUE piece index (0-11), returns -1 for empty.
piece_to_nnue_index :: proc(p: chess.Piece) -> i32 {
	switch p {
	case .WK:
		return 0
	case .WQ:
		return 1
	case .WN:
		return 2
	case .WB:
		return 3
	case .WR:
		return 4
	case .WP:
		return 5
	case .BK:
		return 6
	case .BQ:
		return 7
	case .BN:
		return 8
	case .BB:
		return 9
	case .BR:
		return 10
	case .BP:
		return 11
	case .X:
		return -1
	}
	return -1
}

nnue_evaluate :: proc(w: ^NNUE_Weights, board: chess.Board, player: chess.Player) -> i32 {
	hidden_size := w.hidden_size

	// Stack-allocate accumulator (max reasonable hidden size)
	MAX_HIDDEN :: 1024
	accumulator_buf: [MAX_HIDDEN]i32
	accumulator := accumulator_buf[:hidden_size]

	// Initialize with biases
	for i in 0 ..< hidden_size {
		accumulator[i] = i32(w.feature_biases[i])
	}

	is_black := player == .Black

	// Accumulate active features
	for sq in 0 ..< 30 {
		piece := board[sq]
		if piece == .X { continue }

		actual_sq: int
		actual_piece: chess.Piece

		if is_black {
			actual_sq = int(mirror[sq])
			actual_piece = flip_piece_color(piece)
		} else {
			actual_sq = int(sq)
			actual_piece = piece
		}

		piece_idx := piece_to_nnue_index(actual_piece)
		if piece_idx < 0 { continue }

		feature := actual_sq * 12 + int(piece_idx)
		fw_offset := feature * hidden_size

		for i in 0 ..< hidden_size {
			accumulator[i] += i32(w.feature_weights[fw_offset + i])
		}
	}

	// Output layer with ClippedReLU
	qa := w.qa
	output: i32 = i32(w.output_bias)
	for i in 0 ..< hidden_size {
		clamped := clamp(accumulator[i], 0, qa)
		output += clamped * i32(w.output_weights[i])
	}

	// Convert from quantized logit to centipawns:
	// float_logit = output / (QA * QB) ≈ score / 400
	// centipawns = float_logit * 400 = output * 400 / (QA * QB)
	return i32(i64(output) * 400 / (i64(qa) * i64(w.qb)))
}

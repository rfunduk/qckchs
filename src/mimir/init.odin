package mimir

// init_no_nnue initializes all mimir subsystems except NNUE weights.
// Use when engines will load their own weights.
init_no_nnue :: proc() {
	init_zobrist()
	init_egtb()
	init_lmr()
}

// init initializes all mimir subsystems (shared read-only state).
// Must be called after chess.init().
init :: proc(nnue_path: string = "mimir.nnue") {
	init_no_nnue()
	init_nnue(nnue_path)
}

// destroy frees all shared mimir state.
destroy :: proc() {
	destroy_egtb()
	destroy_nnue()
}

// engine_create allocates an Engine with a configurable TT size.
// tt_size must be a power of 2. Pass 0 for the default (1M entries).
engine_create :: proc(tt_size: u64 = DEFAULT_TT_SIZE, allocator := context.allocator) -> ^Engine {
	eng := new(Engine, allocator)
	size := tt_size == 0 ? u64(DEFAULT_TT_SIZE) : tt_size
	eng.tt = make([]TT_Entry, size, allocator)
	eng.tt_mask = size - 1
	return eng
}

engine_destroy :: proc(eng: ^Engine, allocator := context.allocator) {
	delete(eng.tt, allocator)
	free(eng, allocator)
}

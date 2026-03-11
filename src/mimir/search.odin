package mimir

import sa "core:container/small_array"
import "core:math"
import "core:time"

import "../chess"

// --- Transposition Table ---

TT_Flag :: enum u8 {
	Exact,
	Lower, // score >= stored (beta cutoff)
	Upper, // score <= stored (failed to raise alpha)
}

TT_Entry :: struct {
	key:   u32,
	score: i32,
	move:  Move,
	depth: u8,
	flag:  TT_Flag,
	age:   u8,
}

DEFAULT_TT_SIZE :: 1 << 20 // ~1M entries

// --- Seen position for repetition detection ---

Seen_Entry :: struct {
	hash:  u64,
	count: u8,
}

SEEN_SIZE :: 256
SEEN_MASK :: SEEN_SIZE - 1

// --- LMR Table ---

LMR_C :: 0.4
lmr_table: [64][128]i32

init_lmr :: proc() {
	for d := 1; d < 64; d += 1 {
		for m := 1; m < 128; m += 1 {
			lmr_table[d][m] = max(0, i32(math.ln(f64(d)) * math.ln(f64(m)) * LMR_C))
		}
	}
}

// --- Engine ---

Engine :: struct {
	tt:              []TT_Entry,
	tt_mask:         u64,
	history:         [2][30][30]i32,
	killers:         [64][2]Move,
	seen_positions:  [SEEN_SIZE]Seen_Entry,
	halfmove_clock:  i32,
	prev_board:      chess.Board,
	has_prev:        bool,
	// Time control
	aborted:         bool,
	deadline:        time.Tick,
	// Stats
	egtb_hits:       i32,
	nodes:           i32,
	// Last search result
	last_score:      i32,
	// Mode
	selfplay:        bool,
	// TT aging
	tt_age:          u8,
	// Counter move heuristic
	counter_moves:   [2][30][30]Move,
	// Capture history
	capture_history: [chess.Piece][30][chess.Piece]i32,
	// Eval noise (centipawns, per-engine for thread safety)
	eval_noise:      i32,
}

// --- Constants ---

MAX_QDEPTH :: 6
DELTA_MARGIN :: 200
REPETITION_PENALTY :: 500
LMR_MOVE_THRESHOLD :: 3
LMR_DEPTH_THRESHOLD :: 3
FUTILITY_MARGIN_1 :: 150
FUTILITY_MARGIN_2 :: 300
RFP_MARGIN_PER_DEPTH :: 120
HALFMOVE_URGENCY_START :: 60
HALFMOVE_URGENCY_SCALE :: 12
ASP_WINDOW :: 150

// --- TT operations ---

tt_probe :: proc(
	eng: ^Engine,
	zhash: u64,
	depth: i32,
	alpha: i32,
	beta: i32,
) -> (
	tt_move: Move,
	cutoff: bool,
	score: i32,
) {
	idx := zhash & eng.tt_mask
	e := eng.tt[idx]
	key := u32(zhash >> 32)

	if e.key == key {
		tt_move = e.move
		if i32(e.depth) >= depth {
			switch e.flag {
			case .Exact:
				return tt_move, true, e.score
			case .Lower:
				if e.score >= beta {
					return tt_move, true, e.score
				}
			case .Upper:
				if e.score <= alpha {
					return tt_move, true, e.score
				}
			}
		}
	}

	return tt_move, false, 0
}

tt_store :: proc(eng: ^Engine, zhash: u64, depth: i32, score: i32, flag: TT_Flag, m: Move) {
	idx := zhash & eng.tt_mask
	e := &eng.tt[idx]
	key := u32(zhash >> 32)
	if key != e.key || i32(e.depth) <= depth || (eng.tt_age - e.age) >= 2 {
		e.key = key
		e.score = score
		e.move = m
		e.depth = u8(depth)
		e.flag = flag
		e.age = eng.tt_age
	}
}

// --- Seen positions (repetition detection) ---

seen_get :: proc(eng: ^Engine, zhash: u64) -> u8 {
	idx := zhash & SEEN_MASK
	if eng.seen_positions[idx].hash == zhash {
		return eng.seen_positions[idx].count
	}
	return 0
}

seen_record :: proc(eng: ^Engine, zhash: u64) {
	idx := zhash & SEEN_MASK
	if eng.seen_positions[idx].hash == zhash {
		eng.seen_positions[idx].count += 1
	} else {
		eng.seen_positions[idx] = Seen_Entry {
			hash  = zhash,
			count = 1,
		}
	}
}

// --- Static Exchange Evaluation (SEE) ---

see_find_lva :: proc(board: chess.Board, target: u8, side: chess.Player) -> (sq: u8, found: bool) {
	best_value: i32 = 999_999
	best_sq: u8 = 0
	found_any := false
	color_idx := side == .White ? 0 : 1

	for ; sq < 30; sq += 1 {
		p := board[sq]
		if chess.piece_owner(p) != side { continue }

		attacks: bool
		switch {
		case p in chess.Pawns:
			attacks = int(target) in chess.pawn_table[color_idx][sq]
		case p in chess.Knights:
			attacks = int(target) in chess.knight_table[sq]
		case p in chess.Kings:
			attacks = int(target) in chess.king_table[sq]
		case p in chess.Sliding_Pieces:
			targets := sliding_attack_targets(board, sq, p)
			attacks = int(target) in targets
		}

		if attacks {
			v := piece_values[p]
			if v < best_value {
				best_value = v
				best_sq = sq
				found_any = true
			}
		}
	}

	return best_sq, found_any
}

see :: proc(board: chess.Board, from_sq: u8, to_sq: u8) -> i32 {
	gain: [16]i32
	d: i32 = 0

	b := board
	attacker := b[from_sq]
	gain[0] = piece_values[b[to_sq]]

	b[from_sq] = .X
	side := chess.piece_owner(attacker)
	side = chess.opponent(side)

	for {
		d += 1
		gain[d] = piece_values[attacker] - gain[d - 1]

		// Stand pat pruning
		if max(-gain[d - 1], gain[d]) < 0 { break }

		attacker_sq, found := see_find_lva(b, to_sq, side)
		if !found { break }

		attacker = b[attacker_sq]
		b[attacker_sq] = .X
		side = chess.opponent(side)

		if d >= 15 { break }
	}

	for d > 0 {
		d -= 1
		gain[d] = -max(-gain[d], gain[d + 1])
	}

	return gain[0]
}

// --- Move ordering ---

pick_next_move :: proc(list: ^Move_List, start: int) {
	n := sa.len(list^)
	if start >= n - 1 { return }
	best_idx := start
	best_score := sa.get(list^, start).score
	for i := start + 1; i < n; i += 1 {
		s := sa.get(list^, i).score
		if s > best_score {
			best_score = s
			best_idx = i
		}
	}
	if best_idx != start {
		tmp := sa.get(list^, start)
		sa.set(&list^, start, sa.get(list^, best_idx))
		sa.set(&list^, best_idx, tmp)
	}
}

score_moves :: proc(
	eng: ^Engine,
	board: chess.Board,
	player: chess.Player,
	list: ^Move_List,
	tt_move: Move,
	ply: i32,
	prev_move: Move = NULL_MOVE,
) {
	side := player == .White ? 0 : 1
	n := sa.len(list^)

	// Counter move lookup
	cm := NULL_MOVE
	if prev_move != NULL_MOVE {
		cm = eng.counter_moves[side][move_from(prev_move)][move_to(prev_move)]
	}

	for i := 0; i < n; i += 1 {
		entry := sa.get_ptr(&list^, i)
		m := entry.move
		from := move_from(m)
		to := move_to(m)

		if m == tt_move {
			entry.score = 1_000_000
			continue
		}

		captured := board[to]
		if captured != .X {
			// MVV-LVA
			victim_val := piece_values[captured]
			attacker_val := piece_values[board[from]]
			entry.score = 100_000 + victim_val - attacker_val
		} else if ply >= 0 && ply < 64 && m == eng.killers[ply][0] {
			entry.score = 50_000
		} else if ply >= 0 && ply < 64 && m == eng.killers[ply][1] {
			entry.score = 49_000
		} else if cm != NULL_MOVE && m == cm {
			// Counter move bonus
			entry.score = 48_000
		} else {
			entry.score = eng.history[side][from][to]
		}
	}
}

score_captures :: proc(board: chess.Board, list: ^Move_List) {
	n := sa.len(list^)
	for i := 0; i < n; i += 1 {
		entry := sa.get_ptr(&list^, i)
		from := move_from(entry.move)
		to := move_to(entry.move)
		victim_val := piece_values[board[to]]
		attacker_val := piece_values[board[from]]
		entry.score = victim_val - attacker_val
	}
}

// --- Time check ---

check_time :: proc(eng: ^Engine) {
	if eng.aborted { return }
	now := time.tick_now()
	// tick_diff(start, end) = end - start. If now > deadline, diff is positive.
	if time.tick_diff(eng.deadline, now) > {} {
		eng.aborted = true
	}
}

// --- Quiescence Search ---

quiesce :: proc(
	eng: ^Engine,
	board: chess.Board,
	player: chess.Player,
	hash: u64,
	alpha_in: i32,
	beta: i32,
	qdepth: i32,
) -> i32 {
	eng.nodes += 1
	// Tablebase probe — only trust decisive (WIN/LOSS) results;
	// DRAW (0) suppressed so heuristic eval can press advantages.
	tb_score, tb_found := egtb_probe(board, player)
	if tb_found && tb_score != 0 { eng.egtb_hits += 1;return tb_score }

	stand_pat := evaluate(board, player, eng.eval_noise)
	if stand_pat >= beta { return beta }
	alpha := alpha_in
	if stand_pat > alpha { alpha = stand_pat }
	if qdepth >= MAX_QDEPTH { return alpha }

	opp := chess.opponent(player)

	caps: Move_List
	generate_captures(board, player, &caps)
	score_captures(board, &caps)

	n := sa.len(caps)
	for i := 0; i < n; i += 1 {
		pick_next_move(&caps, i)
		entry := sa.get(caps, i)
		m := entry.move
		to := move_to(m)

		// Delta pruning
		captured_val := piece_values[board[to]]
		if stand_pat + captured_val + DELTA_MARGIN < alpha { continue }

		new_board := apply_move(board, m)
		if !has_king(new_board, opp) { return INF }

		new_hash := zobrist_apply_move(hash, board, m)
		score := -quiesce(eng, new_board, opp, new_hash, -beta, -alpha, qdepth + 1)

		if score >= beta { return beta }
		if score > alpha { alpha = score }
	}

	return alpha
}

// --- Negamax with PVS + LMR ---

negamax :: proc(
	eng: ^Engine,
	board: chess.Board,
	player: chess.Player,
	hash: u64,
	depth: i32,
	alpha_in: i32,
	beta: i32,
	ply: i32,
	prev_move: Move = NULL_MOVE,
) -> i32 {
	check_time(eng)
	if eng.aborted { return 0 }
	eng.nodes += 1

	opp := chess.opponent(player)

	if !has_king(board, player) { return -INF }

	if depth <= 0 {
		return quiesce(eng, board, player, hash, alpha_in, beta, 0)
	}

	// TT probe
	tt_move, cutoff, tt_score := tt_probe(eng, hash, depth, alpha_in, beta)
	if cutoff { return tt_score }

	orig_alpha := alpha_in
	alpha := alpha_in

	moves: Move_List
	generate_moves(board, player, &moves)
	if sa.len(moves) == 0 { return -INF }

	// Score and sort moves
	side := player == .White ? 0 : 1
	score_moves(eng, board, player, &moves, tt_move, ply, prev_move)

	// Futility pruning
	futility_margin: i32 = 0
	can_futility := false
	if depth == 1 {
		futility_margin = FUTILITY_MARGIN_1
		can_futility = true
	} else if depth == 2 {
		futility_margin = FUTILITY_MARGIN_2
		can_futility = true
	}

	futile := false
	if can_futility && !king_is_attacked(board, player) && abs(alpha) < INF - 1000 {
		static_eval := evaluate(board, player, eng.eval_noise)
		futile = static_eval + futility_margin <= alpha
	}

	best_move := sa.get(moves, 0).move
	best_score: i32 = -INF

	n := sa.len(moves)
	for move_count := 0; move_count < n; move_count += 1 {
		if eng.aborted { return 0 }

		pick_next_move(&moves, move_count)
		entry := sa.get(moves, move_count)
		m := entry.move
		from := move_from(m)
		to := move_to(m)
		is_capture := board[to] != .X

		// Futility: skip quiet moves
		if futile && move_count > 0 && !is_capture { continue }

		new_board := apply_move(board, m)
		if !has_king(new_board, opp) {
			tt_store(eng, hash, depth, INF, .Lower, m)
			return INF
		}

		new_hash := zobrist_apply_move(hash, board, m)
		score: i32

		if move_count == 0 {
			// PV node: full window
			score = -negamax(eng, new_board, opp, new_hash, depth - 1, -beta, -alpha, ply + 1, m)
		} else {
			// LMR
			reduction: i32 = 0
			if move_count >= LMR_MOVE_THRESHOLD &&
			   depth >= LMR_DEPTH_THRESHOLD &&
			   !is_capture &&
			   !king_is_attacked(board, player) {
				reduction = 1
			}

			// Null window (possibly reduced)
			score = -negamax(
				eng,
				new_board,
				opp,
				new_hash,
				depth - 1 - reduction,
				-alpha - 1,
				-alpha,
				ply + 1,
				m,
			)

			// Re-search at full depth if LMR reduced search beat alpha
			if reduction > 0 && score > alpha {
				score = -negamax(eng, new_board, opp, new_hash, depth - 1, -alpha - 1, -alpha, ply + 1, m)
			}

			// PVS re-search with full window
			if score > alpha && score < beta {
				score = -negamax(eng, new_board, opp, new_hash, depth - 1, -beta, -alpha, ply + 1, m)
			}
		}

		if score > best_score {
			best_score = score
			best_move = m
		}
		if score >= beta {
			if !is_capture {
				// Killer + history update on cutoff (quiet moves only)
				if ply >= 0 && ply < 64 {
					if m != eng.killers[ply][0] {
						eng.killers[ply][1] = eng.killers[ply][0]
						eng.killers[ply][0] = m
					}
				}
				eng.history[side][from][to] += depth * depth
				// Counter move update
				if prev_move != NULL_MOVE {
					eng.counter_moves[side][move_from(prev_move)][move_to(prev_move)] = m
				}
			}
			tt_store(eng, hash, depth, score, .Lower, best_move)
			return score
		}
		if score > alpha {
			alpha = score
		}
	}

	flag: TT_Flag = best_score <= orig_alpha ? .Upper : .Exact
	tt_store(eng, hash, depth, best_score, flag, best_move)

	return best_score
}

// --- Root search ---

search_root :: proc(
	eng: ^Engine,
	board: chess.Board,
	player: chess.Player,
	hash: u64,
	depth: i32,
	moves: ^Move_List,
	alpha_in: i32,
	beta: i32,
) -> (
	Move,
	i32,
) {
	opp := chess.opponent(player)

	// Score moves for ordering
	tt_move, _, _ := tt_probe(eng, hash, 0, -INF, INF)
	score_moves(eng, board, player, moves, tt_move, 0)

	n := sa.len(moves^)
	best_move := sa.get(moves^, 0).move
	best_raw_score: i32 = -INF
	orig_alpha := alpha_in
	alpha := alpha_in

	for move_count := 0; move_count < n; move_count += 1 {
		if eng.aborted { return best_move, alpha }

		pick_next_move(moves, move_count)
		entry := sa.get(moves^, move_count)
		m := entry.move
		to := move_to(m)
		from := move_from(m)

		new_board := apply_move(board, m)
		if !has_king(new_board, opp) {
			return m, INF // king capture
		}

		new_hash := zobrist_apply_move(hash, board, m)
		raw_score: i32

		if move_count == 0 {
			raw_score = -negamax(eng, new_board, opp, new_hash, depth - 1, -beta, -alpha, 1, m)
		} else {
			raw_score = -negamax(eng, new_board, opp, new_hash, depth - 1, -alpha - 1, -alpha, 1, m)
			if raw_score > alpha && raw_score < beta {
				raw_score = -negamax(eng, new_board, opp, new_hash, depth - 1, -beta, -alpha, 1, m)
			}
		}

		// Repetition penalty — penalize any move leading to a previously seen position.
		// Threshold >= 1 catches the 2nd occurrence, preventing a 3rd (threefold draw).
		result_hash := zobrist_hash(new_board, opp)
		times_visited := seen_get(eng, result_hash)
		score := raw_score
		if times_visited >= 1 {
			score = raw_score - REPETITION_PENALTY * i32(times_visited)
		}

		// 50-move urgency
		if eng.halfmove_clock > HALFMOVE_URGENCY_START {
			piece := board[from]
			is_pawn := piece in chess.Pawns
			is_capture := board[to] != .X
			if is_pawn || is_capture {
				score += (eng.halfmove_clock - HALFMOVE_URGENCY_START) * HALFMOVE_URGENCY_SCALE
			}
		}

		if move_count == 0 {
			best_raw_score = raw_score
		}
		if score > alpha {
			alpha = score
			best_move = m
			best_raw_score = raw_score
		}
	}

	flag: TT_Flag = alpha > orig_alpha ? .Exact : .Upper
	tt_store(eng, hash, depth, best_raw_score, flag, best_move)

	return best_move, alpha
}

// --- Progress detection ---

detect_progress :: proc(prev, curr: chess.Board) -> bool {
	prev_count: i32 = 0
	curr_count: i32 = 0
	for sq: u8 = 0; sq < 30; sq += 1 {
		if prev[sq] != .X { prev_count += 1 }
		if curr[sq] != .X { curr_count += 1 }
	}
	if curr_count < prev_count { return true }

	for sq: u8 = 0; sq < 30; sq += 1 {
		if prev[sq] in chess.Pawns || curr[sq] in chess.Pawns {
			if prev[sq] != curr[sq] { return true }
		}
	}

	return false
}

// --- Time management ---

compute_budget :: proc(remaining_periods: i32, move_number: i32) -> time.Duration {
	if remaining_periods <= 3 { return 200 * time.Millisecond }
	if remaining_periods <= 6 { return 400 * time.Millisecond }

	base: i32 = 800

	// Opening bonus (moves 1-5)
	if move_number <= 2 {
		base = 2500
	} else if move_number <= 5 {
		base = 1800
	}

	// Safety cap: never burn below 5 reserve periods
	max_ms := (remaining_periods - 5) * 1000
	if max_ms < 200 { max_ms = 200 }
	if base > max_ms { base = max_ms }

	return time.Duration(base) * time.Millisecond
}

compute_max_budget :: proc(remaining_periods: i32) -> time.Duration {
	max_ms := (remaining_periods - 5) * 1000
	if max_ms < 200 { max_ms = 200 }
	return time.Duration(max_ms) * time.Millisecond
}

// --- Pick best move (main entry point) ---

pick_best_move :: proc(
	eng: ^Engine,
	board: chess.Board,
	player: chess.Player,
	remaining_periods: i32,
	move_number: i32,
	max_depth: i32 = 64,
) -> Move {
	// Reset stats
	eng.egtb_hits = 0
	eng.nodes = 0

	// Increment TT age for this search
	eng.tt_age += 1

	// Update halfmove clock
	if eng.has_prev {
		if detect_progress(eng.prev_board, board) {
			eng.halfmove_clock = 0
		} else {
			eng.halfmove_clock += 2
		}
	}
	eng.prev_board = board
	eng.has_prev = true

	// Record current position
	hash := zobrist_hash(board, player)
	seen_record(eng, hash)

	// Generate moves
	moves: Move_List
	generate_moves(board, player, &moves)
	if sa.len(moves) == 0 { return NULL_MOVE }

	// Single legal move — instant return
	if sa.len(moves) == 1 {
		eng.last_score = 0
		return sa.get(moves, 0).move
	}

	// Decay history tables
	for side := 0; side < 2; side += 1 {
		for from := 0; from < 30; from += 1 {
			for to := 0; to < 30; to += 1 {
				eng.history[side][from][to] >>= 1
			}
		}
	}

	// Set up timing
	budget := compute_budget(remaining_periods, move_number)
	max_budget := compute_max_budget(remaining_periods)
	start := time.tick_now()
	if remaining_periods >= 9999 {
		eng.deadline = time.tick_add(start, 60 * time.Second)
	} else {
		eng.deadline = time.tick_add(start, budget)
	}
	eng.aborted = false

	best_move := sa.get(moves, 0).move
	prev_score: i32 = 0
	prev_best_move: Move = NULL_MOVE
	unstable_count: i32 = 0

	for depth: i32 = 1; depth <= max_depth; depth += 1 {
		asp_alpha: i32
		asp_beta: i32
		if depth >= 2 {
			asp_alpha = prev_score - ASP_WINDOW
			asp_beta = prev_score + ASP_WINDOW
		} else {
			asp_alpha = -INF
			asp_beta = INF
		}

		move, score := search_root(eng, board, player, hash, depth, &moves, asp_alpha, asp_beta)
		if eng.aborted { break }

		if score <= asp_alpha || score >= asp_beta {
			move, score = search_root(eng, board, player, hash, depth, &moves, -INF, INF)
			if eng.aborted { break }
		}

		prev_score = score
		best_move = move

		// Eval swing detection — extend time if position changed dramatically
		if depth == 2 && eng.has_prev {
			swing := abs(score - eng.last_score)
			if swing >= 200 {
				budget = min(budget * 3, max_budget)
				eng.deadline = time.tick_add(start, budget)
			} else if swing >= 100 {
				budget = min(budget * 2, max_budget)
				eng.deadline = time.tick_add(start, budget)
			}
		}

		// Best-move stability tracking
		if depth >= 2 && move != prev_best_move {
			unstable_count += 1
		}
		prev_best_move = move

		// Early exit based on stability
		elapsed := time.tick_diff(start, time.tick_now())
		threshold: time.Duration
		if unstable_count == 0 {
			threshold = budget / 4 // very stable, safe to stop early
		} else if unstable_count >= 2 {
			threshold = budget * 3 / 4 // unstable, keep thinking
		} else {
			threshold = budget / 2 // default
		}
		if elapsed > threshold { break }
	}

	eng.last_score = prev_score

	// Record resulting position
	result := apply_move(board, best_move)
	result_hash := zobrist_hash(result, chess.opponent(player))
	seen_record(eng, result_hash)

	eng.prev_board = result
	eng.has_prev = true

	return best_move
}

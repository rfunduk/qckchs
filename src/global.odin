package qckchs

import sa "core:container/small_array"
import "core:time"

import "chess"
import "mimir"

GAME_ID_OFFSET :: 10000
PLAYER_ID_OFFSET :: 20000
PERIOD_SECONDS :: 1
INITIAL_PERIODS :: 120
ABANDON_TIMEOUT :: i64(time.Minute * 10)
BOT_ABANDON_TIMEOUT :: i64(time.Second * 30)

Engine_Memory :: struct {
	last_id: Game_Id,
	games:   map[Game_Id]Game,
}

engine_init :: proc() {
	g = new(Engine_Memory)
	g.games = make(map[Game_Id]Game, 100)
	g.last_id = 0
	chess.init()
	mimir.init()
}

State :: enum {
	Waiting,
	Turn_White,
	Turn_Black,
	Stalemate,
	Resolved,
}

Tick_Result :: enum {
	No_Change,
	Timed_Out,
	Abandoned,
	Cleanup,
}

Clock :: struct {
	white_periods: u16,
	black_periods: u16,
	last_move_at:  i64,
}

Game_Id :: u32

Player_Key :: [32]u8
EMPTY_KEY: Player_Key : {}

Game_Result :: enum {
	In_Progress,
	Stalemate,
	White_By_Capture,
	Black_By_Capture,
	White_By_Resignation,
	Black_By_Resignation,
	White_By_Timeout,
	Black_By_Timeout,
	Draw_Repetition,
	Draw_No_Progress,
}

White_Wins :: bit_set[Game_Result]{.White_By_Capture, .White_By_Resignation, .White_By_Timeout}
Black_Wins :: bit_set[Game_Result]{.Black_By_Capture, .Black_By_Resignation, .Black_By_Timeout}

Game :: struct {
	id:                Game_Id,
	created_at:        i64,
	board:             chess.Board,
	initial_board:     chess.Board,
	current_player:    chess.Player,
	clock:             Clock,
	state:             State,
	result:            Game_Result,
	moves:             [dynamic]chess.Move,
	white_key:         Player_Key,
	black_key:         Player_Key,
	white_name:        string,
	black_name:        string,
	position_hashes:   sa.Small_Array(50, u32),
	no_progress_count: u8,
	difficulty:        Difficulty,
	bot:               ^Bot_Handle,
}

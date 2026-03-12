package qckchs

import "core:log"
import "core:mem/virtual"
import "core:time"

lifecycle_tick :: proc "c" (_arg: rawptr) {
	context = global_context

	if len(g.games) == 0 { return }

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != .None { return }
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	now := time.to_unix_nanoseconds(time.now())

	to_free: [dynamic]Game_Id
	to_publish: [dynamic]Game_Id
	defer delete(to_free)
	defer delete(to_publish)

	to_resolve: [dynamic]Game_Id
	defer delete(to_resolve)

	to_remove_players: [dynamic]Game_Id
	defer delete(to_remove_players)

	for id, &game in g.games {
		result := game_tick(&game, now)
		switch result {
		case .Started:
			log.infof("Game %d: both players present, starting", id)
			append(&to_publish, id)
		case .Timed_Out:
			log.debugf("Game %d: timed out", id)
			append(&to_publish, id)
			append(&to_resolve, id)
		case .Abandoned:
			log.debugf("Game %d: abandoned", id)
			db_delete(id)
			append(&to_free, id)
			append(&to_remove_players, id)
		case .Cleanup:
			log.debugf("Game %d: cleanup", id)
			append(&to_free, id)
		case .No_Change:
		}
	}

	for id in to_publish {
		code := game_code(id)
		publish_game(code)
	}

	for id in to_resolve {
		if id in g.games {
			publish_players(&g.games[id], id, .Resolve)
		}
	}

	// Publish lobby removes BEFORE freeing games
	for id in to_free {
		publish_lobby(id, .Remove)
	}

	// Only notify players for abandoned games (cleanup games stay on profile via DB)
	for id in to_remove_players {
		if id in g.games {
			publish_players(&g.games[id], id, .Remove)
		}
	}

	for id in to_free {
		if id in g.games {
			game := &g.games[id]
			kill_bot(game)
			game_free(game)
		}
	}
}

package qckchs

import "core:encoding/base32"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import mg "lib:mongoose"

import "chess"

// --- HTTP helpers ---

get_path :: proc(req: mg.Req) -> string {
	path_len: u32
	path_ptr := mg.get_path(req, &path_len)
	return string(path_ptr[:path_len])
}

get_body :: proc(req: mg.Req) -> (string, bool) {
	body_len: u32
	body_ptr := mg.get_body(req, &body_len)
	if body_ptr == nil || body_len == 0 { return "", false }
	return string(body_ptr[:body_len]), true
}

get_method :: proc(req: mg.Req) -> string {
	method_len: u32
	method_ptr := mg.get_method(req, &method_len)
	return string(method_ptr[:method_len])
}

get_query :: proc(req: mg.Req) -> string {
	query_len: u32
	query_ptr := mg.get_query(req, &query_len)
	if query_ptr == nil || query_len == 0 { return "" }
	return string(query_ptr[:query_len])
}

get_query_param :: proc(query, name: string) -> string {
	if len(query) == 0 { return "" }
	search := fmt.tprintf("%s=", name)
	idx := strings.index(query, search)
	if idx < 0 { return "" }
	rest := query[idx + len(search):]
	end := strings.index(rest, "&")
	if end < 0 { return rest }
	return rest[:end]
}

respond_html :: proc(req: mg.Req, html: string) {
	mg.respond(req, 200, "text/html", raw_data(html), u32(len(html)), "no-store")
}

respond_ok :: proc(req: mg.Req) {
	msg: string = "OK"
	mg.respond(req, 200, "text/plain", raw_data(msg), u32(len(msg)), "no-store")
}

respond_404 :: proc(req: mg.Req) {
	msg: string = "Not found"
	mg.respond(req, 404, "text/plain", raw_data(msg), u32(len(msg)), "no-store")
}

respond_400 :: proc(req: mg.Req) {
	msg: string = "Bad request"
	mg.respond(req, 400, "text/plain", raw_data(msg), u32(len(msg)), "no-store")
}

respond_500 :: proc(req: mg.Req) {
	msg: string = "Internal server error"
	mg.respond(req, 500, "text/plain", raw_data(msg), u32(len(msg)), "no-store")
}

respond_redirect :: proc(req: mg.Req, location: string) {
	mg.redirect(req, raw_data(location), u32(len(location)))
}

// --- Routing helpers ---

path_params :: proc(path, prefix: string, $N: int) -> (result: [N]string, ok: bool) {
	if !strings.has_prefix(path, prefix) { return }
	rest := path[len(prefix):]
	i := 0
	it := rest
	for seg in strings.split_iterator(&it, "/") {
		if i >= N { return }
		result[i] = seg
		i += 1
	}
	ok = i == N
	return
}

parse_u8 :: proc(s: string) -> (u8, bool) {
	val, ok := strconv.parse_int(s)
	if !ok || val < 0 || val > 255 { return 0, false }
	return u8(val), true
}

//odinfmt: disable
content_type_for :: proc(path: string) -> cstring {
	ext := filepath.ext(path)
	switch ext {
	case ".js": return "text/javascript"
	case ".css": return "text/css"
	case ".svg": return "image/svg+xml"
	case ".png": return "image/png"
	case ".html": return "text/html"
	case: return "application/octet-stream"
	}
}
//odinfmt: enable

require_claimed :: proc(req: mg.Req, current_path: string) -> bool {
	pk, ok := get_cookie_pk(req)
	if !ok || !db_is_player_claimed(pk) {
		location := fmt.aprintf("/profile?next=%s", current_path)
		respond_redirect(req, location)
		return true
	}
	return false
}

viewer_from_cookie :: proc(req: mg.Req, game: Game) -> chess.Player {
	pk, ok := get_cookie_pk(req)
	if !ok { return .None }
	if pk == game.white_key { return .White }
	if pk == game.black_key { return .Black }
	return .None
}

// --- ID encoding ---

//odinfmt: disable
LOWERCASE_ENC_TABLE := [32]byte {
	'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h',
	'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p',
	'q', 'r', 's', 't', 'u', 'v', 'w', 'x',
	'y', 'z', '2', '3', '4', '5', '6', '7',
}
//odinfmt: enable

Code_Kind :: enum {
	Game,
	Player,
}

//odinfmt: disable
CODE_OFFSETS := [Code_Kind]u32 {
	.Game   = GAME_ID_OFFSET,
	.Player = PLAYER_ID_OFFSET,
}
//odinfmt: enable

encode_id :: proc(id: u32, kind: Code_Kind, allocator := context.allocator) -> string {
	val := u32be(id + CODE_OFFSETS[kind])
	bytes := transmute([4]u8)val

	start := 0
	for start < 4 && bytes[start] == 0 { start += 1 }
	if start == 4 { start = 3 }

	encoded := base32.encode(bytes[start:], LOWERCASE_ENC_TABLE)
	defer delete(encoded)
	return strings.clone(strings.trim_right(encoded, "="), allocator)
}

decode_id :: proc(code: string, kind: Code_Kind) -> (u32, bool) {
	padded_len := ((len(code) + 7) / 8) * 8
	pad_buf: [16]u8
	if padded_len > len(pad_buf) { return 0, false }

	copy(pad_buf[:], code)
	// Uppercase in-place — base32.decode expects uppercase, avoids allocating via strings.to_upper
	for i in 0 ..< len(code) {
		c := pad_buf[i]
		if c >= 'a' && c <= 'z' { pad_buf[i] = c - 32 }
	}
	for i in len(code) ..< padded_len { pad_buf[i] = '=' }

	decoded, err := base32.decode(string(pad_buf[:padded_len]))
	defer delete(decoded)
	if err != .None { return 0, false }

	if len(decoded) == 0 || len(decoded) > 4 { return 0, false }

	val: u32 = 0
	for b in decoded { val = (val << 8) | u32(b) }

	offset := CODE_OFFSETS[kind]
	if val < offset { return 0, false }
	return val - offset, true
}

game_code :: proc(id: Game_Id, allocator := context.allocator) -> string {
	return encode_id(u32(id), .Game, allocator)
}

game_id_from_code :: proc(code: string) -> (Game_Id, bool) {
	val, ok := decode_id(code, .Game)
	return Game_Id(val), ok
}

player_code :: proc(id: i64, allocator := context.allocator) -> string {
	return encode_id(u32(id), .Player, allocator)
}

player_id_from_code :: proc(code: string) -> (i64, bool) {
	val, ok := decode_id(code, .Player)
	return i64(val), ok
}

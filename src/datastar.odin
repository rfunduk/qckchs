package qckchs

import "core:log"
import "core:strings"

import fio "lib:facilio"

// Write SSE data, close connection on failure (write queue overflow / dead connection).
sse_write_or_close :: proc(sse: fio.SSE, event: cstring, data: string) {
	result := fio.sse_write(sse, event, raw_data(data), u32(len(data)))
	if result < 0 {
		log.warnf("SSE write failed (%s, %d bytes), closing connection", event, len(data))
		fio.sse_close(sse)
	}
}

// --- Response helpers ---

// For HTTP responses: we build the full SSE frame, so lines need explicit "data: " prefixes.
http_elements :: proc(b: ^strings.Builder, html: string) {
	first := true
	it := html
	for line in strings.split_iterator(&it, "\n") {
		strings.write_string(b, first ? "elements " : "\r\ndata: elements ")
		strings.write_string(b, strings.trim_right(line, "\r"))
		first = false
	}
}

// For SSE writes: facil.io adds "data: " per line, so we just separate with "\n".
sse_elements :: proc(b: ^strings.Builder, html: string) {
	first := true
	it := html
	for line in strings.split_iterator(&it, "\n") {
		if !first { strings.write_string(b, "\n") }
		strings.write_string(b, "elements ")
		strings.write_string(b, strings.trim_right(line, "\r"))
		first = false
	}
}

ds_patch :: proc(sse: fio.SSE, html: string) {
	b := strings.builder_make()
	sse_elements(&b, html)
	sse_write_or_close(sse, "datastar-patch-elements", strings.to_string(b))
}

ds_patch_el :: proc(sse: fio.SSE, selector: string, html: string) {
	b := strings.builder_make()
	strings.write_string(&b, "selector ")
	strings.write_string(&b, selector)
	strings.write_string(&b, "\nmode outer\n")
	sse_elements(&b, html)
	sse_write_or_close(sse, "datastar-patch-elements", strings.to_string(b))
}

ds_morph :: proc(req: fio.Req, html: string) {
	b := strings.builder_make()
	strings.write_string(
		&b,
		"event: datastar-patch-elements\r\ndata: selector body\r\ndata: mode inner\r\ndata: ",
	)
	http_elements(&b, html)
	strings.write_string(&b, "\r\n\r\n")
	data := strings.to_string(b)
	fio.respond(req, 200, "text/event-stream", raw_data(data), u32(len(data)), "no-store")
}

ds_morph_el :: proc(req: fio.Req, selector: string, html: string) {
	b := strings.builder_make()
	sse_append_morph_el(&b, selector, html)
	sse_respond(req, &b)
}

ds_append_el :: proc(sse: fio.SSE, selector: string, html: string) {
	b := strings.builder_make()
	strings.write_string(&b, "selector ")
	strings.write_string(&b, selector)
	strings.write_string(&b, "\nmode append\n")
	sse_elements(&b, html)
	sse_write_or_close(sse, "datastar-patch-elements", strings.to_string(b))
}

ds_prepend_el :: proc(sse: fio.SSE, selector: string, html: string) {
	b := strings.builder_make()
	strings.write_string(&b, "selector ")
	strings.write_string(&b, selector)
	strings.write_string(&b, "\nmode prepend\n")
	sse_elements(&b, html)
	sse_write_or_close(sse, "datastar-patch-elements", strings.to_string(b))
}

ds_remove_el :: proc(sse: fio.SSE, selector: string) {
	b := strings.builder_make()
	strings.write_string(&b, "selector ")
	strings.write_string(&b, selector)
	strings.write_string(&b, "\nmode remove")
	sse_write_or_close(sse, "datastar-patch-elements", strings.to_string(b))
}

ds_patch_signals :: proc(sse: fio.SSE, signals: string) {
	b := strings.builder_make()
	strings.write_string(&b, "signals ")
	strings.write_string(&b, signals)
	sse_write_or_close(sse, "datastar-patch-signals", strings.to_string(b))
}

sse_append_signals :: proc(b: ^strings.Builder, signals: string) {
	strings.write_string(b, "event: datastar-patch-signals\r\ndata: signals ")
	strings.write_string(b, signals)
	strings.write_string(b, "\r\n\r\n")
}

sse_append_morph_el :: proc(b: ^strings.Builder, selector: string, html: string) {
	strings.write_string(b, "event: datastar-patch-elements\r\ndata: selector ")
	strings.write_string(b, selector)
	strings.write_string(b, "\r\ndata: mode outer\r\ndata: ")
	http_elements(b, html)
	strings.write_string(b, "\r\n\r\n")
}

sse_respond :: proc(req: fio.Req, b: ^strings.Builder) {
	data := strings.to_string(b^)
	fio.respond(req, 200, "text/event-stream", raw_data(data), u32(len(data)), "no-store")
}

// --- Signal parsing ---


udata_pk :: proc(ud: ^fio.SSE_Udata) -> (Player_Key, bool) {
	if ud.pk[0] == 0 { return {}, false }
	pk: Player_Key
	copy(pk[:], string(ud.pk[:32]))
	return pk, true
}

get_cookie_pk :: proc(req: fio.Req) -> (Player_Key, bool) {
	cookie_len: u32
	cookie_cstr := fio.get_cookie(req, "pk", 2, &cookie_len)
	if cookie_cstr == nil || cookie_len != 32 { return {}, false }
	pk: Player_Key
	copy(pk[:], string(cookie_cstr)[:32])
	return pk, true
}

get_form_pk :: proc(req: fio.Req) -> (Player_Key, bool) {
	val_len: u32
	val_cstr := fio.get_form_param(req, "pk", 2, &val_len)
	if val_cstr == nil || val_len != 32 { return {}, false }
	val := strings.clone_from_cstring(val_cstr)
	key: Player_Key
	copy(key[:], val)
	return key, true
}

// --- JSON SSE ---

sse_write_json :: proc(sse: fio.SSE, data: string) {
	sse_write_or_close(sse, "game-state", data)
}

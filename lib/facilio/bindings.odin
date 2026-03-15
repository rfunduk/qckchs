package facilio

foreign import wrapper "system:facilio_wrapper"

Req :: distinct rawptr
SSE :: distinct rawptr

SSE_Udata :: struct {
	suffix:   [32]u8,
	body:     [1024]u8,
	body_len: u32,
	pk:       [33]u8,
}

Handler :: #type proc "c" (req: Req)
SSE_Handler :: #type proc "c" (sse: SSE)
SSE_Msg_Handler :: #type proc "c" (sse: SSE, udata: rawptr, msg: [^]u8, msg_len: u32)
Log_Fn :: #type proc "c" (level: i32, msg: [^]u8, len: u32)

@(link_prefix = "fiow_")
@(default_calling_convention = "c")
foreign wrapper {
	listen :: proc(port: cstring) ---
	start :: proc() ---
	on_request :: proc(handler: Handler) ---
	on_stream :: proc(prefix: cstring, on_open: SSE_Handler, on_close: SSE_Handler) ---
	respond :: proc(req: Req, status: i32, content_type: cstring, body: [^]u8, body_len: u32, cache_control: cstring) ---
	redirect :: proc(req: Req, location: [^]u8, location_len: u32) ---
	get_form_param :: proc(req: Req, name: cstring, name_len: u32, out_len: ^u32) -> cstring ---
	sse_write :: proc(sse: SSE, event: cstring, data: [^]u8, data_len: u32) -> i32 ---
	sse_close :: proc(sse: SSE) -> i32 ---
	get_path :: proc(req: Req, out_len: ^u32) -> [^]u8 ---
	get_body :: proc(req: Req, out_len: ^u32) -> [^]u8 ---
	sse_get_udata :: proc(sse: SSE) -> rawptr ---
	free :: proc(ptr: rawptr) ---
	run_every :: proc(ms: u32, task: proc "c" (arg: rawptr), arg: rawptr) ---
	set_log :: proc(fn: Log_Fn) ---
	set_origin :: proc(origin: cstring) ---
	on_sse_message :: proc(handler: SSE_Msg_Handler) ---
	sse_subscribe :: proc(sse: SSE, channel: [^]u8, channel_len: u32, udata: rawptr) ---
	publish :: proc(channel: [^]u8, channel_len: u32, msg: [^]u8, msg_len: u32) ---
	get_cookie :: proc(req: Req, name: cstring, name_len: u32, out_len: ^u32) -> cstring ---
	get_method :: proc(req: Req, out_len: ^u32) -> [^]u8 ---
	get_query :: proc(req: Req, out_len: ^u32) -> [^]u8 ---
	get_header :: proc(req: Req, name: cstring, name_len: u32, out_len: ^u32) -> cstring ---
	defer_task :: proc(task: proc "c" (udata1: rawptr, udata2: rawptr), udata1: rawptr, udata2: rawptr) ---
}

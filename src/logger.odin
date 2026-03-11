package qckchs

import "core:log"
import "core:os"
import "core:sync"

// Thread-safe logger wrapper — mutex around Odin's non-thread-safe file logger
TS_Logger_Data :: struct {
	mutex:      sync.Mutex,
	inner_proc: log.Logger_Proc,
	inner_data: rawptr,
}

ts_logger_data: ^TS_Logger_Data

ts_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	d := cast(^TS_Logger_Data)data
	sync.lock(&d.mutex)
	defer sync.unlock(&d.mutex)
	d.inner_proc(d.inner_data, level, text, options, location)
}

make_ts_logger :: proc() -> log.Logger {
	base := log.create_file_logger(
		os.stderr,
		.Debug when ODIN_DEBUG else .Info,
		{.Level, .Time, .Terminal_Color},
	)
	ts_logger_data = new(TS_Logger_Data)
	ts_logger_data.inner_proc = base.procedure
	ts_logger_data.inner_data = base.data
	return log.Logger {
		procedure = ts_logger_proc,
		data = ts_logger_data,
		lowest_level = base.lowest_level,
		options = base.options,
	}
}

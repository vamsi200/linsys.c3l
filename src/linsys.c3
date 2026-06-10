import std::os;
import std::io::file;
import std::collections::list;

faultdef
    NO_SUCH_PROCESS, PERMISSION_DENIED, PARSE_ERROR, NOT_SUPPORTED, PROCESS_EXITED, IO_ERROR, SCHED_NO_SUCH_PROCESS, SCHED_PERMISSION_DENIED, SCHED_INVALID, NICE_PERMISSION_DENIED, NICE_NO_SUCH_PROCESS, NICE_INVALID, UNKNOWN, NOT_FOUND, PATH_NOT_FOUND
;

macro void free_slice(slice, Allocator allocator) @private {
    $assert $defined(slice[0].free(allocator)) : "element type must have .free(Allocator)";
    foreach (item : slice) item.free(allocator);
    mem::alloc::free(allocator, slice);
}

macro void free_fields(self, Allocator allocator) @private {
    $foreach $field : $Typeof(self)::members:
        $if $field.type.name == "String":
            mem::alloc::free(allocator, self.$eval($field.name));
        $endif
    $endforeach
}

struct FieldError {
   String field;
   fault f;
}

alias ErrorList = List { FieldError };
tlocal ErrorList* field_errors = null;
tlocal ErrorContext error_ctx_storage;

struct ErrorContext {
    Allocator allocator;
    ErrorList errors;
}

tlocal ErrorContext* error_ctx = null;

fn void init_errors(Allocator allocator) {
    error_ctx = &error_ctx_storage;
    error_ctx.allocator = allocator;
    error_ctx.errors.init(allocator);
}

fn void push_error(String field, fault f) {
    if (error_ctx == null) return;
    error_ctx.errors.push({ field, f });
}

fn ErrorList* list_errors() {
    if (error_ctx == null) return null;
    return &error_ctx.errors;
}

fn void free_errors() {
    if (error_ctx == null) return;
    error_ctx.errors.free();
    error_ctx = null;
}

macro void @try_field(#v, #expr, String field, #fallback) {
    var res = #expr;
    if (catch err = res) {
        linsys::push_error(field, err);
        #v = #fallback;
    } else {
        #v = res;
    }
}

fn TcpState tcp_state(String hex) @private {
    switch (hex) {
        case "01": return TcpState.ESTABLISHED;
        case "02": return TcpState.SYN_SENT;
        case "03": return TcpState.SYN_RECV;
        case "04": return TcpState.FIN_WAIT1;
        case "05": return TcpState.FIN_WAIT2;
        case "06": return TcpState.TIME_WAIT;
        case "07": return TcpState.CLOSE;
        case "08": return TcpState.CLOSE_WAIT;
        case "09": return TcpState.LAST_ACK;
        case "0A": return TcpState.LISTEN;
        case "0B": return TcpState.CLOSING;
        default: return TcpState.UNKNOWN;
    }
}


fn String ip_to_string(Allocator allocator, uint ip) @private {
    return string::format(allocator, "%d.%d.%d.%d", (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF);
}

fn String ip_to_string_v6(Allocator allocator, uint128 ip) @private {
    ushort[8] groups;
    for (int i = 0; i < 8; i++) {
        groups[i] = (ushort)((ip >> (i * 16)) & 0xFFFF);
    }
    return string::format(
        allocator,
        "%x:%x:%x:%x:%x:%x:%x:%x",
        groups[7],
        groups[6],
        groups[5],
        groups[4],
        groups[3],
        groups[2],
        groups[1],
        groups[0]
    );
}

fn uint parse_addr(String hex)  @private {
    uint i = (uint)hex.to_long(16) ?? 0;
    return ((i & 0xFF) << 24) | ((i & 0xFF00) << 8) | ((i & 0xFF0000) >> 8) | ((i >> 24) & 0xFF);
}

fn uint128 parse_addr6(String hex)  @private {
    if (hex.len != 32) return (uint128)0;
    uint128 result = 0;
    for (int i = 0; i < 4; i++) {
        uint word = (uint)(hex[i * 8:8].to_long(16) ?? 0);
        result |= (uint128)word << (i * 32);
    }
    return result;
}

fn String? read_file(Allocator allocator, File file)  @private {
    char[4096] temp;
    DString builder = dstring::new_with_capacity(allocator, 4096);

    while (true) {
        sz n = file.read(&temp)!;
        if (n == 0) break;
        builder.append(temp[:n]);
    }

    return builder.str_view();
}

fn String[] split_whitespace(Allocator allocator, String s)  @private {
    List{String} parts;
    parts.init(allocator);
    foreach (word : s.split(allocator, " ")) {
        if (word.len > 0) parts.push(word);
    }
    return parts.array_view();
}

fn ulong? read_ulong_file(String path)  @private {
    File file = file::open(path, "r")!;
    defer (void)file.close();

    return io::treadline(&file)!.trim().to_ulong();
}

fn ulong? read_total_cpu_time() @private{
    @pool(){
	File file = file::open("/proc/stat", "r")!;
	defer (void)file.close();

    	String line = linsys::read_file(tmem, file)!;

	sz i = line.index_of("cpu ")!;
	if (i == -1) return 0;

	String[] split = linsys::split_whitespace(tmem, line[(i + 4)..].trim());

	if (split.len < 8) return 0;

	return split[0].to_ulong()! + split[1].to_ulong()! + split[2].to_ulong()!
		+ split[3].to_ulong()!
		+ split[4].to_ulong()!
		+ split[5].to_ulong()!
		+ split[6].to_ulong()!
		+ split[7].to_ulong()!;
   };
}

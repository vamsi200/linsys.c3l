module sys;
import std::os;
import std::io::file;

faultdef
    NO_SUCH_PROCESS, PERMISSION_DENIED, PARSE_ERROR, NOT_SUPPORTED, PROCESS_EXITED, IO_ERROR, SCHED_NO_SUCH_PROCESS, SCHED_PERMISSION_DENIED, SCHED_INVALID, NICE_PERMISSION_DENIED, NICE_NO_SUCH_PROCESS, NICE_INVALID
;

fn TcpState tcp_state(String hex) {
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


fn String ip_to_string(Allocator allocator, uint ip) {
    return string::format(allocator, "%d.%d.%d.%d", (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF);
}


fn uint parse_addr(String hex) {
    uint i = (uint)hex.to_long(16) ?? 0;
    return ((i & 0xFF) << 24) | ((i & 0xFF00) << 8) | ((i & 0xFF0000) >> 8) | ((i >> 24) & 0xFF);
}

fn String? read_file(Allocator allocator, File file) {
    char[4096] temp;
    DString builder = dstring::new_with_capacity(allocator, 4096);

    while (true) {
        sz n = file.read(&temp)!;
        if (n == 0) break;
        builder.append(temp[:n]);
    }

    return builder.str_view();
}

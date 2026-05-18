import std::io;
import std::io::file;
import libc;
import std::core::string;
import std::collections::list;
import std::net;
import std::os::posix;
import std::thread;
import std::collections::maybe;

struct Process {
    int pid;
    int ppid;
    String name;
    char state;
}

struct MemoryMap {
    String address_range;
    String perms;
    long offset;
    String device;
    long inode;
    String pathname;
}

struct ProcessInfo {
    Process process;
    Maybe{String} exe_path;
    String cmdline;
    int uid;
    int gid;
    int threads;
    long vm_size;
    long vm_rss;
}

struct ProcStat {
    int pid;
    String comm;
    char state;
    int ppid;
    int pgrp;
    int session;
    int tty_nr;
}

struct CpuTimes {
    double user;
    double system;
    double children_user;
    double children_system;
}

struct IoCounters {
    ulong read_count;
    ulong write_count;
    ulong read_bytes;
    ulong write_bytes;
}

struct OpenFile {
    int fd;
    String path;
    String mode;
}

struct Connection {
    String local_addr;
    int local_port;
    String remote_addr;
    int remote_port;
    TcpState state;
    Protocol protocol;
}

enum Protocol {
    TCP,
    UDP,
}

enum TcpState {
    ESTABLISHED,
    SYN_SENT,
    SYN_RECV,
    FIN_WAIT1,
    FIN_WAIT2,
    TIME_WAIT,
    CLOSE,
    CLOSE_WAIT,
    LAST_ACK,
    LISTEN,
    CLOSING,
    UNKNOWN
}

struct RLimit {
    ulong soft;
    ulong hard;
}

struct ThreadInfo {
    int tid;
    CpuTimes cpu_times;
}

struct EnvVar {
    String key;
    String value;
}

struct RLimitEntry {
    String name;
    RLimit limit;
}

faultdef NO_SUCH_PROCESS, PERMISSION_DENIED, PARSE_ERROR, NOT_SUPPORTED, PROCESS_EXITED, IO_ERROR;

fn String? read_file(Allocator allocator, File file) {
    char[4096] temp;
    DString builder;
    builder.init(allocator);

    while (true) {
        sz n = file.read(&temp)!;
        if (n == 0) break;
        builder.append(temp[:n]);
    }

    return builder.str_view();
}

fn ProcessInfo? get_info(Allocator allocator, int pid) {
    ProcessInfo proc = { };
    @pool() {
        String path = string::tformat("/proc/%d/status", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();

        String content = read_file(allocator, file)!;
        String[] lines = content.split(allocator, "\n");

        foreach (line : lines) {
            long? idx = line.index_of_char(':');
            if (catch err = idx) continue;
            if (idx == -1) return PARSE_ERROR~;

            String key   = line[:idx].trim();
            String data  = line[idx + 1..].trim();
            String first = data.trim();

            switch (key) {
                case "Threads":
                    proc.threads = data.to_int()!;

                case "Uid":
                    long uid_idx = first.index_of_char('\t')!;
                    first = uid_idx == -1 ? first : first[:uid_idx];
                    if (try int uid = first.to_int()) proc.uid = uid;

                case "Gid":
                    long gid_idx = first.index_of_char('\t')!;
                    first = gid_idx == -1 ? first : first[:gid_idx];
                    if (try int gid = first.to_int()) proc.gid = gid;

                case "VmSize":
                    long vms_idx = first.index_of_char(' ')!;
                    first = vms_idx == -1 ? first : first[:vms_idx];
                    if (try long vms = first.to_long()) proc.vm_size = vms;

                case "VmRSS":
                    long vmrss_idx = first.index_of_char(' ')!;
                    first = vmrss_idx == -1 ? first : first[:vmrss_idx];
                    if (try long vmrss = first.to_long()) proc.vm_rss = vmrss;

                default:
                    continue;
            }
        }
    };

    Process p = get_proc(allocator, pid)!;
    if (try String s = read_exe(allocator, pid)) {
        proc.exe_path = { .has_value = true, .value = s };
    } else {
        proc.exe_path = { .has_value = false };
    }

    proc.cmdline = read_cmdline(allocator, pid)!;
    proc.process = p;

    return proc;
}


fn Process? get_proc(Allocator allocator, int pid) {
    Process p;

    @pool() {
        String path = string::tformat("/proc/%d/status", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();

        String content = read_file(allocator, file)!;
        String[] lines = content.split(allocator, "\n");

        foreach (line : lines) {
            long? idx = line.index_of_char(':');
            if (catch err = idx) continue;
            if (idx == -1) continue;

            String key  = line[:idx].trim();
            String data = line[idx + 1..].trim();

            switch (key) {
                case "Pid":
                    p.pid = data.to_int()!;

                case "PPid":
                    p.ppid = data.to_int()!;

                case "Name":
                    p.name = data.copy(allocator);

                case "State":
                    p.state = data[0];

                default:
                    continue;
            }
        }
    };

    return p;
}

fn String? read_cmdline(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/cmdline", pid);
    File file   = file::open(path, "r")!;
    defer (void)file.close();
    String cmdline;
    String content = read_file(tmem, file)!;

    if (content.len == 0) {
        cmdline = "";
    }

    for (sz i = 0; i < content.len; i++) {
        if (content[i] == '\0') {
            content[i] = ' ';
        }
    }

    return content.trim_right().copy(allocator);
}

fn String? read_exe(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/exe", pid);
    char[4096] buf;

    sz len = libc::readlink((ZString)path, &buf, buf.len - 1);

    if (len < 0) {
        switch (libc::errno()) {
            case EACCES:
            case EPERM:
                return PERMISSION_DENIED~;

            case ENOENT:
                return PROCESS_EXITED~;

            default:
                return IO_ERROR~;
        }
    }

    return ((String)buf[:len]).copy(allocator);
}

// NOTE: We could skip the first iter and pre-allocate with the len of list
// so it could be slight perf imp vs memory usage, will need to check furthur.
fn int[]? list_pids(Allocator allocator) {
    Path p = io::path::new(allocator, "/proc")!;
    defer alloc::free(allocator, p);

    PathList list = io::path::ls(allocator, p)!;
    defer catch list.free();
    sz count = 0;
    foreach (l : list) {
        if (try l.file_tbasename().to_int()) {
            count++;
        }
    }

    int[] proc_list = mem::alloc::alloc_array(allocator, int, count);
    int i           = 0;

    foreach (l : list) {
        if (try int pid = l.file_tbasename().to_int()) {
            proc_list[i++] = pid;
        }
    }

    return proc_list[:i];
}

fn bool exists(int pid) {
    int[]? list = list_pids(tmem);
    if (catch err = list) return false; // This is fine i guess.

    foreach (p : list) {
        if (p == pid) {
            return true;
        }
    }
    return false;
}

fn String? cwd(Allocator allocator, int pid) {
    char[4096] buf;
    String path = string::tformat("/proc/%d/cwd", pid);

    sz len = libc::readlink((ZString)path, &buf, buf.len - 1);

    if (len <= 0) {
        return "";
    }

    return ((String)buf[:len]).copy(allocator);
}

fn EnvVar[]? environ(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/environ", pid);
    EnvVar[] ev = { };
    File file  = file::open(path, "r")!;
    defer (void)file.close();

    String content = read_file(tmem, file)!;

    String[] s = content.split(tmem, "\0");

    ev = mem::alloc::alloc_array(allocator, EnvVar, s.len);

    int i = 0;

    foreach (line : s) {
        long? idx = line.index_of_char('=');

        if (catch err = idx) continue;
        if (idx == -1) continue;

        ev[i].key = line[:idx].trim().copy(allocator);
        ev[i].value = line[idx + 1..].trim().copy(allocator);

        i++;
    }

    return ev[:i];
}

fn String[]? fd_paths(Allocator allocator, int pid) {
    String[] fds;

    @pool() {
        String proc_fd = string::tformat("/proc/%d/fd", pid);

        Path path     = path::new(tmem, proc_fd)!;
        PathList list = io::path::ls(tmem, path)!;

        fds = mem::alloc::alloc_array(allocator, String, list.len());

        char[4096] buf;
        int i = 0;

        foreach (l : list) {
            String full   = string::tformat("%s/%s", proc_fd, l.file_tbasename()!);
            ZString zpath = full.zstr_tcopy();
            sz n          = libc::readlink(zpath, &buf, buf.len - 1);

            if (n < 0) continue;

            fds[i++] = ((String)buf[:n]).copy(allocator);
        }

        return fds[:i];
    };
}

fn int[]? fds(Allocator allocator, int pid) {
    @pool() {
        String proc_fd = string::tformat("/proc/%d/fd", pid);

        Path path     = path::new(tmem, proc_fd)!;
        PathList list = io::path::ls(tmem, path)!;

        int[] fds = mem::alloc::alloc_array(allocator, int, list.len());

        int i = 0;

        foreach (fd : list) {
            if (try int ifd = fd.file_tbasename().to_int()) {
                fds[i++] = ifd;
            }
        }

        return fds[:i];
    };
}

// Should I even keep this function and the struct???
fn ProcStat? read_stat(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/stat", pid);
    File file   = file::open(path, "r")!;
    defer (void)file.close();
    String s = read_file(allocator, file)!;
    sz close = s.rindex_of_char(')')!;
    sz open  = s.index_of_char('(')!;

    ProcStat ps = { };
    ps.pid = pid;
    ps.comm = s[open + 1..close].strip_suffix(")").copy(allocator);

    String rest     = s[close + 2..];
    String[] fields = rest.split(allocator, " ");
    if (fields.len < 3) return string::CONVERSION_FAILED~;

    ps.state = fields[0][0];
    if (try int ppid = fields[1].to_int()) ps.ppid = ppid;
    if (try int pgrp = fields[2].to_int()) ps.pgrp = pgrp;
    if (try int tty = fields[4].to_int()) ps.tty_nr = tty;

    return ps;
}

fn MemoryMap[]? maps(Allocator allocator, int pid) {
    @pool() {
        String p = string::tformat("/proc/%d/maps", pid);

        File file = file::open(p, "r")!;
        defer (void)file.close();

        String content = read_file(tmem, file)!;
        String[] lines = content.tsplit("\n");

        MemoryMap[] mm = mem::alloc::alloc_array(allocator, MemoryMap, lines.len);

        int i = 0;

        foreach (line : lines) {
            if (line.len == 0) continue;

            String[] split = line.tsplit(" ");

            if (split.len < 5) continue;

            MemoryMap entry = { };

            entry.address_range = split[0].copy(allocator);
            entry.perms = split[1].copy(allocator);

            if (try long offset = split[2].to_long()) {
                entry.offset = offset;
            }

            entry.device = split[3].copy(allocator);

            if (try long inode = split[4].to_long()) {
                entry.inode = inode;
            }

            if (split.len > 5) {
                entry.pathname = string::tjoin(split[5..], " ").trim().copy(allocator);
            }

            mm[i++] = entry;
        }

        return mm[:i];
    };
}

struct FlagInfo {
    int flag;
    String name;
}

fn String flags_to_mode(int flags, Allocator allocator) @private {
    String access;

    switch (flags & 3) {
        case 0: access = "r";
        case 1: access = "w";
        case 2: access = "rw";
        default: access = "?";
    }

    FlagInfo[*] infos = {
        { 0o02000, "append" }, // O_APPEND
        { 0o04000, "nonblock" }, // O_NONBLOCK
        { 0o010000, "dsync" }, // O_DSYNC
        { 0o020000, "async" }, // O_ASYNC
        { 0o040000, "direct" }, // O_DIRECT
        { 0o100000, "largefile" }, // O_LARGEFILE
        { 0o1000000, "noatime" }, // O_NOATIME
        { 0o2000000, "cloexec" }, // O_CLOEXEC
        };

    DString result = dstring::new_with_capacity(allocator, 32);

    result.append(access);

    foreach (info : infos) {
        if (flags & info.flag) {
            result.append_char('+');
            result.append(info.name);
        }
    }

    return result.copy_str(allocator);
}

fn OpenFile[]? open_files(Allocator allocator, int pid) {
    @pool() {
        int[] fd_list = fds(tmem, pid)!;

        OpenFile[] of = mem::alloc::alloc_array(allocator, OpenFile, fd_list.len);

        char[4096] link_buf;
        char[4096] fdinfo_buf;

        int i = 0;

        foreach (fd : fd_list) {
            OpenFile entry = { };

            String fd_path = string::tformat("/proc/%d/fd/%d", pid, fd);

            if (!os::native_file_or_dir_exists(fd_path)) {
                continue;
            }

            ZString zpath = fd_path.zstr_tcopy();

            sz n = libc::readlink(zpath, &link_buf, link_buf.len - 1);

            if (n < 0) continue;

            String target = (String)link_buf[0:n];

            if (!target.starts_with("/") || target.ends_with(" (deleted)")) {
                continue;
            }

            if (!os::native_file_or_dir_exists(target)) {
                continue;
            }

            entry.fd = fd;
            entry.path = target.copy(allocator);

            String info_path = string::tformat("/proc/%d/fdinfo/%d", pid, fd);

            File file = file::open(info_path, "r")!;
            defer (void)file.close();

            String text = read_file(tmem, file)!;

            foreach (line : text.tsplit("\n")) {
                line = line.trim();

                if (!line.starts_with("flags:")) {
                    continue;
                }

                String flags_str = line["flags:".len..].trim();

                if (try int flags = flags_str.to_int(8)) {
                    entry.mode = flags_to_mode(flags, allocator);
                }

                break;
            }

            of[i++] = entry;
        }

        return of[:i];
    };
}

fn uint parse_addr(String hex) @private {
    uint i = (uint)hex.to_long(16) ?? 0;
    return ((i & 0xFF) << 24) | ((i & 0xFF00) << 8) | ((i & 0xFF0000) >> 8) | ((i >> 24) & 0xFF);
}

fn String ip_to_string(Allocator allocator, uint ip) {
    return string::format(allocator, "%d.%d.%d.%d", (ip >> 24) & 0xFF, (ip >> 16) & 0xFF, (ip >> 8) & 0xFF, ip & 0xFF);
}

fn TcpState tcp_state(String hex) @private{
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

// TODO: add v6 support
fn void? read_connections(Allocator allocator, int pid, Protocol proto, List{Connection}* out) {
    @pool() {
        String filename;

        switch (proto) {
            case TCP: filename = "tcp";
            case UDP: filename = "udp";
        }

        String path = string::tformat("/proc/%d/net/%s", pid, filename);

        if (!os::native_file_or_dir_exists(path)) {
            return;
        }

        File file = file::open(path, "r")!;
        defer (void)file.close();

        String content = read_file(tmem, file)!;
        String[] lines = content.split(tmem, "\n");

        foreach (i, line : lines) {
            if (i == 0 || line.len == 0) {
                continue;
            }

            String[] raw = line.trim().split(tmem, " ");

            List{String} fields;
            fields.init(tmem);

            foreach (f : raw) {
                if (f.len > 0) {
                    fields.push(f);
                }
            }

            if (fields.len() < 4) {
                continue;
            }

            String[] local = fields[1].split(tmem, ":");

            String[] remote = fields[2].split(tmem, ":");

            if (local.len < 2 || remote.len < 2) {
                continue;
            }

            Connection entry = {
                .local_addr = ip_to_string(allocator, parse_addr(local[0])),
                .remote_addr = ip_to_string(allocator, parse_addr(remote[0])),
                .local_port = (ushort)(local[1].to_long(16) ?? 0),
                .remote_port = (ushort)(remote[1].to_long(16) ?? 0),
                .state = tcp_state(fields[3]),
                .protocol = proto,
            };

            out.push(entry);
        }
    };
}

fn Connection[]? connections(Allocator allocator, int pid) {
    List{Connection} list;
    list.init(allocator);
    defer catch list.free();

    read_connections(allocator, pid, Protocol.TCP, &list)!;
    read_connections(allocator, pid, Protocol.UDP, &list)!;

    return list.to_array(allocator);
}

fn ulong? read_boot_time() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();

    ulong btime;

    String[] lines = read_file(tmem, file)!.split(tmem, "\n");

    foreach (line : lines) {
        if (line.contains("btime")) {
            String s = line.strip_prefix("btime ");

            if (try ulong bt = s.to_ulong()) {
                btime = bt;
            }
        }
    }

    return btime;
}

// getconf CLK_TCK
fn ulong? read_clktck() {
    File file = file::open("/proc/self/auxv", "rb")!!;
    defer (void)file.close();
    char[4096] buf;
    sz n = file.read(&buf)!;

    sz i = 0;
    while (i + 16 <= n) {
        ulong type, val;
        mem::copy(&type, &buf[i], 8);
        mem::copy(&val, &buf[i + 8], 8);

        if (type == 17) return val; // AT_CLKTCK
        if (type == 0) break; // AT_NULL
        i += 16;
    }
    return 100;
}

// re-check this impl
fn double? create_time(int pid) {
    String p  = string::tformat("/proc/%d/stat", pid);
    File file = file::open(p, "r")!!;
    defer (void)file.close();

    double start_time;
    String raw      = read_file(tmem, file)!;
    sz rp           = raw.rindex_of(")")!;
    String after    = raw[(rp + 2)..];
    String[] fields = after.split(tmem, " ");

    if (fields.len < 20) return 0;
    if (try ulong val = fields[19].to_ulong()) {
        ulong btime  = read_boot_time()!;
        ulong clktck = read_clktck()!;
        start_time = (double)btime + ((double)val / (double)clktck);
    }
    return start_time;
}

fn CpuTimes? cpu_times_parse(String path) @private {
    CpuTimes cpu = { };
    File file    = file::open(path, "r")!;
    defer (void)file.close();
    String raw = read_file(tmem, file)!;
    sz rp      = raw.rindex_of(")")!;

    String after    = raw[(rp + 2)..];
    String[] fields = after.split(tmem, " ");

    if (fields.len > 14) {
        double clktck = (double)read_clktck()!;
        if (try double utime = fields[11]
            .to_double() && try double stime = fields[12]
                .to_double() && try double cutime = fields[13]
                    .to_double() && try double cstime = fields[14].to_double()) {
            cpu.user = utime / clktck;
            cpu.system = stime / clktck;
            cpu.children_user = cutime / clktck;
            cpu.children_system = cstime / clktck;
        }
    }
    return cpu;
}

fn CpuTimes? cpu_times(int pid) {
    String p = string::tformat("/proc/%d/stat", pid);
    return cpu_times_parse(p)!;
}

fn CpuTimes? cpu_times_threads(int pid, int tid) {
    String p = string::tformat("/proc/%d/task/%d/stat", pid, tid);
    return cpu_times_parse(p)!;
}

fn double? cpu_percent(int pid, double interval) {
    CpuTimes first = cpu_times(pid)!;
    double proc1   = first.user + first.system;

    ulong total1 = read_total_cpu_time()!;

    thread::sleep_ms((long)(interval * 1000));

    CpuTimes second = cpu_times(pid)!;
    double proc2    = second.user + second.system;

    ulong total2 = read_total_cpu_time()!;

    double delta       = proc2 - proc1;
    double total_delta = (double)(total2 - total1);

    if (total_delta <= 0) return 0.0;

    return (delta / total_delta) * 100.0;
}

fn ulong? read_total_cpu_time() {
    File file = file::open("/proc/stat", "r")!!;
    defer (void)file.close();

    String line = read_file(tmem, file)!;

    sz i = line.index_of("cpu ")!!;
    if (i == -1) return 0;

    String[] split = line[(i + 4)..].trim().split(tmem, " ");

    if (split.len < 8) return 0;

    return split[0].to_ulong()! + split[1].to_ulong()! + split[2].to_ulong()! + split[3].to_ulong()!
        + split[4].to_ulong()!
        + split[5].to_ulong()!
        + split[6].to_ulong()!
        + split[7].to_ulong()!;
}

fn ulong? parse_proc_ulong(String path, String key) {
    ulong result = 0;
    @pool() {
        File file = file::open(path, "r")!;
        defer (void)file.close();
        char[4096] buf;
        sz n           = file.read(&buf)!;
        String[] lines = ((String)buf[:n]).split(tmem, "\n");
        foreach (line : lines) {
            if (!line.starts_with(key)) continue;
            String[] s = line.trim().split(tmem, ":");
            if (s.len < 2) continue;
            if (try ulong v = s[1].trim().strip_suffix(" kB").to_ulong()) result = v;
            break;
        }
    };
    return result;
}

fn double? memory_percent(int pid) {
    @pool() {
        String p        = string::tformat("/proc/%d/status", pid);
        ulong vmrs      = parse_proc_ulong(p, "VmRSS")!;
        ulong total_mem = parse_proc_ulong("/proc/meminfo", "MemTotal")!;
        if (total_mem == 0) return 0.0;
        return ((double)vmrs / (double)total_mem) * 100.0;
    };
}

fn IoCounters? io_counters(int pid) {
    IoCounters ioc = { };
    @pool() {
        String path = string::tformat("/proc/%d/io", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();
        char[4096] buf;
        sz n           = file.read(&buf)!;
        String[] lines = ((String)buf[:n]).split(tmem, "\n");
        foreach (line : lines) {
            String[] split = line.split(tmem, ":");
            if (split.len < 2) continue;
            String key = split[0].trim();
            if (try v = split[1].trim().to_ulong()) {
                switch (key) {
                    case "rchar": ioc.read_count = v;
                    case "wchar": ioc.write_count = v;
                    case "read_bytes": ioc.read_bytes = v;
                    case "write_bytes": ioc.write_bytes = v;
                }
            }
        }
    };
    return ioc;
}

constdef Signal : int {
    TERM = 15,
    KILL = 9,
    STOP = 19,
    CONT = 18,
    INT  = 2,
}

fn bool send_signal(int pid, Signal signal) {
    if (pid <= 0) {
        return false;
    }
    return posix::kill(pid, (CInt)signal) == 0;
}

fn bool suspend(int pid) {
    return send_signal(pid, Signal.STOP);
}

fn bool resume(int pid) {
    return send_signal(pid, Signal.CONT);
}

fn bool kill(int pid) {
    return send_signal(pid, Signal.KILL);
}

fn bool terminate(int pid) {
    return send_signal(pid, Signal.TERM);
}

fn bool interrupt(int pid) {
    return send_signal(pid, Signal.INT);
}

// TODO: improve this later -- why??
fn int[]? children(Allocator allocator, int pid, bool recursive) {
    int[] pid_list = list_pids(allocator)!;
    defer alloc::free(allocator, pid_list);

    List{int} result;
    result.init(allocator);

    char[4096] buf;
    foreach (p : pid_list) {
        @pool() {
            String path = string::tformat("/proc/%d/stat", p);
            File? file  = file::open(path, "r");
            if (catch file) continue;
            defer (void)file.close();
            sz? n = file.read(&buf);
            if (catch n) continue;
            String stat     = (String)buf[:n];
            sz end_comm     = stat.rindex_of(")")!;
            String after    = stat[end_comm + 2..];
            String[] fields = after.split(tmem, " ");
            if (fields.len < 2) continue;
            int ppid = fields[1].to_int()!;
            if (ppid != pid) continue;
            result.push(p);
            if (recursive) {
                int[] sub = children(allocator, p, true)!;
                defer alloc::free(allocator, sub);
                foreach (child : sub) result.push(child);
            }
        };
    }
    return result.to_array(allocator);
}

fn int? parent(int pid) {
    @pool() {
        String path = string::tformat("/proc/%d/stat", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();
        char[4096] buf;
        sz n            = file.read(&buf)!;
        String stat     = (String)buf[:n];
        sz end_comm     = stat.rindex_of(")")!;
        String after    = stat[end_comm + 2..];
        String[] fields = after.split(tmem, " ");
        if (fields.len < 2) return 0;
        return fields[1].to_int()!;
    };
}

fn int? nice_get(int pid) {
    CInt p = libc::getpriority(libc::PRIO_PROCESS, pid);

    if (libc::errno() != 0) {
        return io::FILE_NOT_FOUND~;
    }

    return (int)p;
}

fn bool nice_set(int pid, int value) {
    if (value < -20) value = -20;
    if (value > 19) value = 19;

    CInt r = libc::setpriority(libc::PRIO_PROCESS, pid, value);

    return r == 0;
}

struct CpuSet {
    ulong[16] bits;
}

extern fn CInt sched_setaffinity(CInt pid, usz cpusetsize, CpuSet* mask);
extern fn CInt sched_getaffinity(CInt pid, usz cpusetsize, CpuSet* mask);

fn int[]? cpu_affinity_get(Allocator allocator, int pid) {
    CpuSet cpu_set = { };
    CInt out       = sched_getaffinity((CInt)pid, @sizeof(cpu_set), &cpu_set);
    if (out != 0) {
        io::printfn("sched_getaffinity failed: %d", out);
    }
    int count = 0;
    int[1024] tmp;
    for (sz i = 0; i < 1024; i++) {
        if (cpu_set.bits[i / 64] & (1UL << (i % 64))) {
            tmp[count++] = (int)i;
        }
    }
    int[] output = mem::alloc::alloc_array(allocator, int, count);
    output[..count] = tmp[:count];
    return output;
}

fn void cpu_affinity_set(int pid, int[] cpus) {
    CpuSet cpu_set = { };
    foreach (cpu : cpus) {
        usz i = (usz)cpu;
        if (i >= 1024) continue;
        cpu_set.bits[i / 64] |= (ulong)1 << (i % 64);
    }

    CInt out = sched_setaffinity((CInt)pid, @sizeof(cpu_set), &cpu_set);
    if (out != 0) {
        io::printfn("sched_setaffinity failed: %d", out);
    }
}

fn RLimitEntry[]? rlimits_get(Allocator allocator, int pid) {
    @pool() {
        String path = string::tformat("/proc/%d/limits", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();
        char[4096] buf;
        sz n           = file.read(&buf)!;
        String content = (String)buf[:n];
        String[] lines = content.split(tmem, "\n");

        List{RLimitEntry} entries;
        entries.init(allocator);

        foreach (line : lines[1..]) {
            if (line.len == 0) continue;
            String[] parts = line.trim().tsplit("  ");
            int pc         = 0;
            String[4] filtered;
            foreach (p : parts) {
                String t = p.trim();
                if (t.len > 0) filtered[pc++] = t;
                if (pc == 4) break;
            }
            if (pc < 3) continue;
            ulong soft = filtered[1] == "unlimited" ? ulong::max : (filtered[1].to_ulong() ?? 0);
            ulong hard = filtered[2] == "unlimited" ? ulong::max : (filtered[2].to_ulong() ?? 0);
            entries.push({ .name = filtered[0].copy(allocator), .limit = { .soft = soft, .hard = hard } });
        }
        return entries.to_array(allocator);
    };
}

fn ThreadInfo[]? threads(Allocator allocator, int pid) {
    @pool() {
        Path path     = string::tformat("/proc/%d/task", pid).to_path(tmem)!;
        PathList list = io::path::ls(tmem, path)!;

        List{ThreadInfo} ti;
        ti.init(allocator);

        foreach (l : list) {
            if (try int tid = l.basename().to_int()) {
                CpuTimes? ct = cpu_times_threads(pid, tid);
                if (catch ct) continue;
                ti.push(
                    {
                        .tid = tid,
                        .cpu_times = {
                            .user = ct.user,
                            .system = ct.system,
                            .children_user = ct.children_user,
                            .children_system = ct.children_system,
                        }
                    }
                );
            }
        }
        return ti.to_array(allocator);
    };
}

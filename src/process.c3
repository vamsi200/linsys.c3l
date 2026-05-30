module linsys;
import std::io;
import std::io::file;
import libc;
import std::core::string;
import std::collections::list;
import std::net;
import std::os::posix;
import std::thread;

struct Process {
    int pid;
    int ppid;
    String name;
    ProcState state;
}

enum ProcState {
    RUNNING,
    SLEEPING,
    DISK_SLEEP,
    ZOMBIE,
    STOPPED,
    TRACING_STOP,
    DEAD,
    IDLE,
    PARKED,
    WAKE_KILL,
    WAKING,
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
    String exe_path;
    String cmdline;
    int uid;
    int gid;
    int threads;
    ulong vm_size;
    ulong vm_rss;
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
    TCP6,
    UDP6,
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

struct CpuSnapshot {
    double proc_time;
    ulong total_time;
}

struct ProcessPoller {
    int pid;
    CpuSnapshot last_snapshot;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn ProcessInfo? get_info(Allocator allocator, int pid) {
    ProcessInfo proc = { };
    Process p        = { };

    @pool() {
        String path = string::tformat("/proc/%d/status", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();

        while (try line = io::treadline(&file)) {
            sz? idx = line.index_of_char(':');
            if (catch idx) continue;
            if (idx == -1) continue;

            String key   = line[:idx].trim();
            String data  = line[idx + 1..].trim();
            String first = data.trim();

            switch (key) {
                case "Threads":
                    if (try int threads = data.to_int()) proc.threads = threads;

                case "Uid":
                    if (try long uid_idx = first.index_of_char('\t')) {
                        first = uid_idx == -1 ? first : first[:uid_idx];
                        if (try int uid = first.to_int()) proc.uid = uid;
                    }

                case "Gid":
                    if (try long gid_idx = first.index_of_char('\t')) {
                        first = gid_idx == -1 ? first : first[:gid_idx];
                        if (try int gid = first.to_int()) proc.gid = gid;
                    }

                case "Pid":
                    if (try int parse_pid = data.to_int()) p.pid = parse_pid;

                case "PPid":
                    if (try int parse_ppid = data.to_int()) p.ppid = parse_ppid;

                case "Name":
                    p.name = data.copy(allocator);

                case "VmSize":
                    if (try long vms_idx = first.index_of_char(' ')) {
                        first = vms_idx == -1 ? first : first[:vms_idx];
                        if (try ulong vms = first.to_ulong()) proc.vm_size = vms;
                    }

                case "VmRSS":
                    if (try long vmrss_idx = first.index_of_char(' ')) {
                        first = vmrss_idx == -1 ? first : first[:vmrss_idx];
                        if (try ulong vmrss = first.to_ulong()) proc.vm_rss = vmrss;
                    }
                case "State":
                    p.state = proc_state((char)data[0]);

                default:
                    continue;
            }
        }
    };

    proc.exe_path = read_exe(allocator, pid) ?? "";
    proc.cmdline = read_cmdline(allocator, pid) ?? "";
    proc.process = p;

    return proc;
}

fn ProcState proc_state(char c) @private {
    switch (c) {
        case 'R': return ProcState.RUNNING;
        case 'S': return ProcState.SLEEPING;
        case 'D': return ProcState.DISK_SLEEP;
        case 'Z': return ProcState.ZOMBIE;
        case 'T': return ProcState.STOPPED;
        case 't': return ProcState.TRACING_STOP;
        case 'X': return ProcState.DEAD;
        case 'I': return ProcState.IDLE;
        case 'P': return ProcState.PARKED;
        case 'K': return ProcState.WAKE_KILL;
        case 'W': return ProcState.WAKING;
        default: return ProcState.RUNNING;
    }
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn Process? get_proc(Allocator allocator, int pid) {
    Process p;

    @pool() {
        String path = string::tformat("/proc/%d/status", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();

        while (try line = io::treadline(&file)) {
            long? idx = line.index_of_char(':');
            if (catch err = idx) continue;
            if (idx == -1) continue;

            String key  = line[:idx].trim();
            String data = line[idx + 1..].trim();

            switch (key) {
                case "Pid":
                    if (try parse_pid = data.to_int()) p.pid = parse_pid;

                case "PPid":
                    if (try parse_ppid = data.to_int()) p.ppid = parse_ppid;

                case "Name":
                    p.name = data.copy(allocator);

                case "State":
                    p.state = proc_state((char)data[0]);

                default:
                    continue;
            }
        }
    };

    return p;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? read_cmdline(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/cmdline", pid);
    File file   = file::open(path, "r")!;
    defer (void)file.close();
    String content = read_file(tmem, file)!;

    // It is common - there would be no cmdline in many cases.
    if (content.len == 0) return "".copy(allocator);

    for (usz i = 0; i < content.len; i++) {
        if (content[i] == '\0') content[i] = ' ';
    }

    return content.trim_right().copy(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
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

fn int[]? list_pids(Allocator allocator) {
    List{int} pids;

    pids.init(allocator);
    @pool() {
        Path p        = io::path::new(tmem, "/proc")!;
        PathList list = io::path::ls(tmem, p)!;
        foreach (l : list) {
            if (try int pid = l.file_tbasename().to_int()) {
                pids.push(pid);
            }
        }
    };
    defer pids.free();
    return pids.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn bool exists(int pid) {
    String path = string::tformat("/proc/%d", pid);
    return os::native_file_or_dir_exists(path);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? cwd(Allocator allocator, int pid) {
    char[4096] buf;
    String path = string::tformat("/proc/%d/cwd", pid);

    sz len = libc::readlink((ZString)path, &buf, buf.len - 1);

    if (len == 0) return "".copy(allocator);
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

<*
 @require pid > 0 : "pid must be positive"
*>
fn EnvVar[]? environ(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/environ", pid);
    File file   = file::open(path, "r")!;
    defer (void)file.close();
    String content = read_file(tmem, file)!;
    String[] s     = content.split(tmem, "\0");

    List{EnvVar} ev;
    ev.init(allocator);

    foreach (line : s) {
        long? idx = line.index_of_char('=');
        if (catch idx) continue;
        if (idx == -1) continue;
        ev.push({ .key = line[:idx].trim().copy(allocator), .value = line[idx + 1..].trim().copy(allocator), });
    }
    return ev.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
 @require key.len > 0 : "key must not be empty"
*>
fn String? environ_get(Allocator allocator, int pid, String key) {
    String path = string::tformat("/proc/%d/environ", pid);
    File file   = file::open(path, "r")!;
    defer (void)file.close();
    String content = read_file(tmem, file)!;
    foreach (line : content.split(tmem, "\0")) {
        long? idx = line.index_of_char('=');
        if (catch idx) continue;
        if (line[:idx].trim() == key) {
            return line[idx + 1..].trim().copy(allocator);
        }
    }
    return NOT_FOUND~;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String[]? fd_paths(Allocator allocator, int pid) {
    List{String} fds;
    fds.init(allocator);

    @pool() {
        String proc_fd = string::tformat("/proc/%d/fd", pid);
        Path path      = path::new(tmem, proc_fd)!;
        PathList list  = io::path::ls(tmem, path)!;
        char[4096] buf;
        foreach (l : list) {
            String full   = string::tformat("%s/%s", proc_fd, l.file_tbasename()!);
            ZString zpath = full.zstr_tcopy();
            sz n          = libc::readlink(zpath, &buf, buf.len - 1);
            if (n < 0) continue;
            fds.push(((String)buf[:n]).copy(allocator));
        }
    };
    defer fds.free();
    return fds.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn int[]? fds(Allocator allocator, int pid) {
    List{int} fds;
    fds.init(allocator);

    @pool() {
        String proc_fd = string::tformat("/proc/%d/fd", pid);
        Path path      = path::new(tmem, proc_fd)!;
        PathList list  = io::path::ls(tmem, path)!;
        foreach (fd : list) {
            if (try int ifd = fd.file_tbasename().to_int()) {
                fds.push(ifd);
            }
        }
    };
    defer fds.free();
    return fds.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn MemoryMap[]? maps(Allocator allocator, int pid) {
    List{MemoryMap} mm;
    mm.init(allocator);

    @pool() {
        String p  = string::tformat("/proc/%d/maps", pid);
        File file = file::open(p, "r")!;
        defer (void)file.close();
        String content = read_file(tmem, file)!;
        foreach (line : content.tsplit("\n")) {
            if (line.len == 0) continue;
            String[] split = split_whitespace(tmem, line);
            if (split.len < 5) continue;
            MemoryMap entry = {
                .address_range = split[0].copy(allocator),
                .perms = split[1].copy(allocator),
                .device = split[3].copy(allocator),
            };
            if (try long o = split[2].to_long()) entry.offset = o;
            if (try long n = split[4].to_long()) entry.inode = n;
            if (split.len > 5) entry.pathname = string::tjoin(split[5..], " ").trim().copy(allocator);
            mm.push(entry);
        }
    };

    defer mm.free();
    return mm.to_array(allocator);
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

<*
 @require pid > 0 : "pid must be positive"
*>
fn OpenFile[]? open_files(Allocator allocator, int pid) {
    List{OpenFile} of;
    of.init(allocator);

    @pool() {
        int[] fd_list = fds(tmem, pid)!;
        char[4096] link_buf;
        foreach (fd : fd_list) {
            String fd_path = string::tformat("/proc/%d/fd/%d", pid, fd);
            if (!os::native_file_or_dir_exists(fd_path)) continue;
            ZString zpath = fd_path.zstr_tcopy();
            sz n          = libc::readlink(zpath, &link_buf, link_buf.len - 1);

            if (n < 0) continue;
            String target = (String)link_buf[0:n];

            if (!target.starts_with("/") || target.ends_with(" (deleted)")) continue;
            if (!os::native_file_or_dir_exists(target)) continue;

            OpenFile entry   = { .fd = fd, .path = target.copy(allocator) };
            String info_path = string::tformat("/proc/%d/fdinfo/%d", pid, fd);
            File file        = file::open(info_path, "r")!;
            defer (void)file.close();

            while (try line = io::treadline(&file)) {
                line = line.trim();
                if (!line.starts_with("flags:")) continue;
                String flags_str = line["flags:".len..].trim();
                if (try int flags = flags_str.to_int(8)) {
                    entry.mode = flags_to_mode(flags, allocator);
                }
                break;
            }
            of.push(entry);
        }
    };
    defer of.free();
    return of.to_array(allocator);
}

fn void? read_connections(Allocator allocator, int pid, Protocol proto, List{Connection}* out) @private {
    @pool() {
        String filename;

        switch (proto) {
            case TCP: filename = "tcp";
            case UDP: filename = "udp";
            case TCP6: filename = "tcp6";
            case UDP6: filename = "udp6";
        }

        String path = string::tformat("/proc/%d/net/%s", pid, filename);

        if (!os::native_file_or_dir_exists(path)) return;

        File file = file::open(path, "r")!;
        defer (void)file.close();
        String content = read_file(tmem, file)!;
        bool is_v6     = proto == Protocol.TCP6 || proto == Protocol.UDP6;

        foreach (i, line : content.split(tmem, "\n")) {
            if (i == 0 || line.len == 0) continue;
            String[] raw = split_whitespace(tmem, line.trim());

            usz n = 0;
            foreach (f : raw) {
                if (f.len > 0) raw[n++] = f;
            }

            if (n < 4) continue;
            sz? colon_l = raw[1].index_of_char(':');
            sz? colon_r = raw[2].index_of_char(':');
            if (catch colon_l) continue;
            if (catch colon_r) continue;

            out.push(
                {
                    .local_addr = is_v6 ? ip_to_string_v6(
                        allocator,
                        parse_addr6(raw[1][:colon_l])
                    ) : ip_to_string(allocator, parse_addr(raw[1][:colon_l])),
                    .remote_addr = is_v6 ? ip_to_string_v6(
                        allocator,
                        parse_addr6(raw[2][:colon_r])
                    ) : ip_to_string(allocator, parse_addr(raw[2][:colon_r])),
                    .local_port = (ushort)(raw[1][colon_l + 1..].to_long(16) ?? 0),
                    .remote_port = (ushort)(raw[2][colon_r + 1..].to_long(16) ?? 0),
                    .state = tcp_state(raw[3]),
                    .protocol = proto,
                }
            );
        }
    };
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn Connection[]? connections(Allocator allocator, int pid) {
    List{Connection} list;
    list.init(allocator);
    defer catch list.free();

    read_connections(allocator, pid, Protocol.TCP, &list)!;
    read_connections(allocator, pid, Protocol.UDP, &list)!;
    read_connections(allocator, pid, Protocol.TCP6, &list)!;
    read_connections(allocator, pid, Protocol.UDP6, &list)!;

    return list.to_array(allocator);
}

macro ulong boot_time() {
    static ulong cached = 0;
    if (cached == 0) cached = read_boot_time() ?? 0;
    return cached;
}

fn ulong? read_boot_time() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();

    ulong btime;

    while (try line = io::treadline(&file)) {
        if (line.contains("btime")) {
            String s = line.strip_prefix("btime ");

            if (try ulong bt = s.to_ulong()) {
                btime = bt;
            }
        }
    }

    return btime;
}

macro ulong clktck() {
    static ulong cached = 0;
    if (cached == 0) cached = read_clktck() ?? 100;
    return cached;
}

// getconf CLK_TCK
fn ulong? read_clktck() @private {
    File file = file::open("/proc/self/auxv", "rb")!;
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

<*
 @require pid > 0 : "pid must be positive"
*>
fn double? create_time(int pid) {
    String p  = string::tformat("/proc/%d/stat", pid);
    File file = file::open(p, "r")!;
    defer (void)file.close();

    double start_time;
    String raw      = read_file(tmem, file)!;
    sz rp           = raw.rindex_of(")")!;
    String after    = raw[(rp + 2)..];
    String[] fields = parse_proc_stat_fields(tmem, raw)!;

    if (fields.len < 20) return PARSE_ERROR~;
    if (try ulong val = fields[19].to_ulong()) {
        ulong btime = boot_time();
        ulong clk   = clktck();
        start_time = (double)btime + ((double)val / (double)clk);
    }
    return start_time;
}

fn String[]? parse_proc_stat_fields(Allocator allocator, String raw) @private {
    sz rp = raw.rindex_of(")")!;

    String after = raw[(rp + 2)..];

    String[] raw_fields = split_whitespace(tmem, after);

    List{String} fields;
    fields.init(allocator);

    foreach (f : raw_fields) {
        if (f.len > 0) {
            fields.push(f);
        }
    }

    return fields.to_array(allocator);
}

fn CpuTimes? cpu_times_parse(String path) @private {
    CpuTimes cpu = { };
    File file    = file::open(path, "r")!;
    defer (void)file.close();
    String raw      = read_file(tmem, file)!;
    String[] fields = parse_proc_stat_fields(tmem, raw)!;

    if (fields.len > 14) {
        double clk = clktck();
        if (try double utime = fields[11].to_double()) cpu.user = utime / clk;
        if (try double stime = fields[12].to_double()) cpu.system = stime / clk;
        if (try double cutime = fields[13].to_double()) cpu.children_user = cutime / clk;
        if (try double cstime = fields[14].to_double()) cpu.children_system = cstime / clk;
    }
    return cpu;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn CpuTimes? cpu_times(int pid) {
    String p = string::tformat("/proc/%d/stat", pid);
    return cpu_times_parse(p)!;
}

<*
 @require pid > 0 : "pid must be positive"
 @require tid > 0 : "tid must be positive"
*>
fn CpuTimes? cpu_times_threads(int pid, int tid) {
    String p = string::tformat("/proc/%d/task/%d/stat", pid, tid);
    return cpu_times_parse(p)!;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn ProcessPoller? process_poller_new(int pid) {
    return { .pid = pid, .last_snapshot = cpu_snapshot(pid)!, };
}

<*
 @require self.pid > 0 : "pid must be positive"
*>
fn double? ProcessPoller.cpu_percent(&self) {
    double pct = cpu_percent_from(self.last_snapshot, self.pid)!;
    self.last_snapshot = cpu_snapshot(self.pid)!;
    return pct;
}

<*
 @require self.pid > 0 : "pid must be positive"
*>
fn double? ProcessPoller.memory_percent(&self) {
    return memory_percent(self.pid);
}

<*
 @require self.pid > 0 : "pid must be positive"
*>
fn IoCounters? ProcessPoller.io_counters(&self) {
    return io_counters(self.pid);
}

fn bool ProcessPoller.exists(&self) => exists(self.pid);

<*
 @require pid > 0 : "pid must be positive"
*>
fn CpuSnapshot? cpu_snapshot(int pid) {
    CpuTimes times = cpu_times(pid)!;
    ulong total    = read_total_cpu_time()!;
    return { times.user + times.system, total };
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn double? cpu_percent_from(CpuSnapshot first, int pid) {
    CpuTimes times     = cpu_times(pid)!;
    ulong total2       = read_total_cpu_time()!;
    double delta       = (times.user + times.system) - first.proc_time;
    double total_delta = (double)(total2 - first.total_time);
    if (total_delta <= 0) return 0.0;
    return (delta / total_delta) * 100.0;
}

<*
 @require pid > 0 : "pid must be positive"
 @require interval >= 0.0 : "interval must be non-negative"
*>
fn double? cpu_percent(int pid, double interval) {
    CpuSnapshot snap = cpu_snapshot(pid)!;
    thread::sleep_ms((long)(interval * 1000));
    return cpu_percent_from(snap, pid);
}

fn ulong? read_total_cpu_time() {
    File file = file::open("/proc/stat", "r")!;
    defer (void)file.close();

    String line = read_file(tmem, file)!;

    sz i = line.index_of("cpu ")!;
    if (i == -1) return 0;

    String[] split = split_whitespace(tmem, line[(i + 4)..].trim());

    if (split.len < 8) return 0;

    return split[0].to_ulong()! + split[1].to_ulong()! + split[2].to_ulong()! + split[3].to_ulong()!
        + split[4].to_ulong()!
        + split[5].to_ulong()!
        + split[6].to_ulong()!
        + split[7].to_ulong()!;
}

fn ulong? parse_proc_ulong(String path, String key) @private {
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

<*
 @require pid > 0 : "pid must be positive"
*>
fn double? memory_percent(int pid) {
    @pool() {
        String p        = string::tformat("/proc/%d/status", pid);
        ulong vmrs      = parse_proc_ulong(p, "VmRSS")!;
        ulong total_mem = parse_proc_ulong("/proc/meminfo", "MemTotal")!;
        if (total_mem == 0) return 0.0;
        return ((double)vmrs / (double)total_mem) * 100.0;
    };
}

<*
 @require pid > 0 : "pid must be positive"
*>
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
            ulong v    = split[1].trim().to_ulong() ?? 0;
            switch (key) {
                case "rchar": ioc.read_count = v;
                case "wchar": ioc.write_count = v;
                case "read_bytes": ioc.read_bytes = v;
                case "write_bytes": ioc.write_bytes = v;
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

<*
 @require pid > 1 : "cannot signal init process"
 @require pid > 0 : "pid must be positive"
*>
fn void? send_signal(int pid, Signal signal) {
    if (posix::kill(pid, (CInt)signal) == 0) return;
    switch (libc::errno()) {
        case EPERM: return PERMISSION_DENIED~;
        case ESRCH: return NO_SUCH_PROCESS~;
        default: return UNKNOWN~;
    }
}

fn void? suspend(int pid) => send_signal(pid, Signal.STOP);
fn void? resume(int pid) => send_signal(pid, Signal.CONT);
fn void? kill(int pid) => send_signal(pid, Signal.KILL);
fn void? terminate(int pid) => send_signal(pid, Signal.TERM);
fn void? interrupt(int pid) => send_signal(pid, Signal.INT);

struct PidEntry {
    int pid;
    int ppid;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn int[]? children(Allocator allocator, int pid, bool recursive) {
    int[] pid_list = list_pids(tmem)!;

    List{PidEntry} entries;
    entries.init(tmem);

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
            String[] fields = split_whitespace(tmem, after);
            if (fields.len < 2) continue;
            int ppid = fields[1].to_int()!;
            entries.push({ p, ppid });
        };
    }

    List{int} result;
    result.init(allocator);
    List{int} queue;
    queue.init(tmem);
    queue.push(pid);

    while (queue.len() > 0) {
        int current = queue.pop()!;
        foreach (e : entries) {
            if (e.ppid != current) continue;
            result.push(e.pid);
            if (recursive) queue.push(e.pid);
        }
    }

    return result.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn int? parent(int pid) {
    @pool() {
        String path = string::tformat("/proc/%d/stat", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();
        char[4096] buf;
        sz n            = file.read(&buf)!;
        String stat     = (String)buf[:n];
        String[] fields = parse_proc_stat_fields(tmem, stat)!;
        if (fields.len < 2) return 0;
        return fields[1].to_int()!;
    };
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn int? nice_get(int pid) {
    CInt p = libc::getpriority(libc::PRIO_PROCESS, pid);
    if (libc::errno() != 0) {
        switch (libc::errno()) {
            case ESRCH: return NICE_NO_SUCH_PROCESS~;
            case EPERM: return NICE_PERMISSION_DENIED~;
            default: return NICE_INVALID~;
        }
    }
    return (int)p;
}

<*
 @require pid > 0 : "pid must be positive"
 @require value >= -20 && value <= 19 : "nice value must be in range -20..19"
*>
fn void? nice_set(int pid, int value) {
    value = value < -20 ? -20 : (value > 19 ? 19 : value);
    if (libc::setpriority(libc::PRIO_PROCESS, pid, value) != 0) {
        switch (libc::errno()) {
            case ESRCH: return NICE_NO_SUCH_PROCESS~;
            case EPERM: return NICE_PERMISSION_DENIED~;
            default: return NICE_INVALID~;
        }
    }
}

struct CpuSet {
    ulong[16] bits;
}

extern fn CInt sched_setaffinity(CInt pid, usz cpusetsize, CpuSet* mask);
extern fn CInt sched_getaffinity(CInt pid, usz cpusetsize, CpuSet* mask);

<*
 @require pid > 0 : "pid must be positive"
*>
fn int[]? cpu_affinity_get(Allocator allocator, int pid) {
    CpuSet cpu_set = { };
    if (sched_getaffinity((CInt)pid, @sizeof(cpu_set), &cpu_set) != 0) {
        switch (libc::errno()) {
            case ESRCH: return SCHED_NO_SUCH_PROCESS~;
            case EPERM: return SCHED_PERMISSION_DENIED~;
            default: return SCHED_INVALID~;
        }
    }

    int count = 0;
    int[1024] tmp;
    for (sz i = 0; i < 1024; i++) {
        if (cpu_set.bits[i / 64] & (1UL << (i % 64))) {
            tmp[count++] = (int)i;
        }
    }
    int[] output = mem::alloc::alloc_array(allocator, int, count);
    output[:count] = tmp[:count];
    return output;
}

<*
 @require pid > 0 : "pid must be positive"
 @require cpus.len > 0 : "cpu affinity must have at least one cpu"
*>
fn void? cpu_affinity_set(int pid, int[] cpus) {
    CpuSet cpu_set = { };
    foreach (cpu : cpus) {
        usz i = (usz)cpu;
        if (i >= 1024) continue;
        cpu_set.bits[i / 64] |= (ulong)1 << (i % 64);
    }

    if (sched_setaffinity((CInt)pid, @sizeof(cpu_set), &cpu_set) != 0) {
        switch (libc::errno()) {
            case ESRCH: return SCHED_NO_SUCH_PROCESS~;
            case EPERM: return SCHED_PERMISSION_DENIED~;
            default: return SCHED_INVALID~;
        }
    }
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn RLimitEntry[]? rlimits_get(Allocator allocator, int pid) {
    @pool() {
        String path = string::tformat("/proc/%d/limits", pid);
        File file   = file::open(path, "r")!;
        defer (void)file.close();
        List{RLimitEntry} entries;
        entries.init(allocator);
        int i = 0;
        while (try line = io::treadline(&file)) {
            if (i++ == 0 || line.len == 0) continue;
            String[] parts = split_whitespace(tmem, line.trim());
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

<*
 @require pid > 0 : "pid must be positive"
*>
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

fn Process[]? all_processes(Allocator allocator) {
    int[] pids = list_pids(tmem)!;
    List{Process} result;
    result.init(allocator);
    foreach (pid : pids) {
        if (try Process p = get_proc(allocator, pid)) {
            result.push(p);
        }
    }
    return result.to_array(allocator);
}

<*
 @require name.len > 0 : "name must not be empty"
*>
fn Process[]? find_by_name(Allocator allocator, String name) {
    int[] pids = list_pids(tmem)!;
    List{Process} result;
    result.init(allocator);
    foreach (pid : pids) {
        if (try Process p = get_proc(allocator, pid)) {
            if (p.name == name) result.push(p);
        }
    }
    return result.to_array(allocator);
}

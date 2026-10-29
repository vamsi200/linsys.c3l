module linsys::process;
import linsys @public;
import std::io;
import std::io::file;
import libc;
import std::core::string;
import std::collections::list;
import std::net;
import std::os::posix;
import std::thread;
import std::math;

struct ProcContext @private {
    int pid;
    int dirfd;
}

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
    UNKNOWN
}

struct MemoryMap {
    String address_range;
    char[4] perms;
    long offset;
    char[9] device;
    long inode;
    String pathname;
}

struct ProcessInfo {
    Process process;
    String exe_path;
    String cmdline;
    String terminal;
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

const CInt O_RDONLY    = 0x0000;
const CInt O_DIRECTORY = 0x10000;
const CInt O_CLOEXEC   = 0x80000;

extern fn CInt open(ZString pathname, CInt flags) @private;
extern fn CInt openat(CInt dirfd, ZString pathname, CInt flags) @private;
extern fn CInt close(CInt fd) @private;

fn ProcContext? open_proc_context(int pid) @private => @pool() {
    ZString path = string::tformat("/proc/%d", pid).zstr_tcopy();
    CInt fd      = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        return linsys::errno_to_fault()~;
    }

    ProcContext ctx = { .pid = pid, .dirfd = fd };

    return ctx;
}

fn void close_proc_context(ProcContext ctx) @private {
    (void)close(ctx.dirfd);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn ProcessInfo? info(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CFile? stream = open_proc_stream(ctx, "status");
    defer (void)libc::fclose(stream);

    char[4096] buf;

    ProcessInfo proc = { };
    Process p        = { };

    String? lines = linsys::read_proc_stream(tmem, stream);
    if (catch lines) return linsys::IO_ERROR~;

    foreach (line : lines.tsplit("\n")) {
        sz? idx = line.index_of_char(':');
        if (catch idx) continue;
        if (idx == -1) continue;

        String key   = line[:idx].trim();
        String data  = line[idx + 1..].trim();
        String first = data.trim();

        switch (key) {
            case "Threads":
                linsys::@try_field(proc.threads, data.to_int(), "processinfo::threads", 0);

            case "Uid":
                if (try long uid_idx = first.index_of_char('\t')) {
                    first = uid_idx == -1 ? first : first[:uid_idx];
                    linsys::@try_field(proc.uid, first.to_int(), "processinfo::uid", 0);
                }

            case "Gid":
                if (try long gid_idx = first.index_of_char('\t')) {
                    first = gid_idx == -1 ? first : first[:gid_idx];
                    linsys::@try_field(proc.gid, first.to_int(), "processinfo::gid", 0);
                }

            case "Pid":
                linsys::@try_field(p.pid, data.to_int(), "processinfo::pid", 0);

            case "PPid":
                linsys::@try_field(p.ppid, data.to_int(), "processinfo::ppid", 0);

            case "Name":
                p.name = data.copy(allocator);

            case "VmSize":
                if (try long vms_idx = first.index_of_char(' ')) {
                    first = vms_idx == -1 ? first : first[:vms_idx];
                    linsys::@try_field(proc.vm_size, first.to_ulong(), "processinfo::vmsize", 0);
                }

            case "VmRSS":
                if (try long vmrss_idx = first.index_of_char(' ')) {
                    first = vmrss_idx == -1 ? first : first[:vmrss_idx];
                    linsys::@try_field(proc.vm_rss, first.to_ulong(), "processinfo::vmrss", 0);
                }

            case "State":
                p.state = proc_state((char)data[0]);

            default:
                continue;
        }
    }

    linsys::@try_field(proc.exe_path, read_exe_helper(allocator, ctx), "exe", "".copy(allocator));
    linsys::@try_field(
        proc.cmdline,
        read_cmdline_helper(allocator, ctx),
        "cmdline",
        "".copy(allocator)
    );
    linsys::@try_field(
        proc.terminal,
        terminal_helper(allocator, ctx),
        "terminal",
        "".copy(allocator)
    );

    proc.process = p;


    return proc;
}

fn void ProcessInfo.free(self, Allocator allocator) {
    linsys::free_fields(self, allocator);
    linsys::free_fields(self.process, allocator);
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
        default: return ProcState.UNKNOWN;
    }
}

fn Process? proc_helper(Allocator allocator, ProcContext ctx) @private => @pool() {
    Process p = { };

    CFile stream = open_proc_stream(ctx, "status")!;
    defer (void)libc::fclose(stream);

    char[4096] buf;

    while (true) {
        ZString raw_line = libc::fgets(&buf, 4096, stream);
        if (raw_line == null) break;

        String line = raw_line.str_view();

        long? idx = line.index_of_char(':');
        if (catch idx) continue;

        String key  = line[:idx].trim();
        String data = line[idx + 1..].trim();

        switch (key) {
            case "Pid":
                linsys::@try_field(p.pid, data.to_int(), "process::pid", 0);

            case "PPid":
                linsys::@try_field(p.ppid, data.to_int(), "process::ppid", 0);

            case "Name":
                p.name = data.copy(allocator);

            case "State":
                if (data.len > 0) {
                    p.state = proc_state((char)data[0]);
                }

            default:
                continue;
        }
    }

    if (libc::ferror(stream) != 0) {
        p.free(allocator);
        return linsys::IO_ERROR~;
    }

    return p;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn Process? proc(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    return proc_helper(allocator, ctx);
}

fn void Process[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void Process.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn CFile? open_proc_stream(ProcContext ctx, ZString filename) @private {
    CInt fd = openat(ctx.dirfd, filename, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return linsys::errno_to_fault()~;
    }

    CFile stream = libc::fdopen(fd, "r");

    if (stream == null) {
        (void)close(fd);
        return linsys::errno_to_fault()~;
    }

    return stream;
}

fn String? read_cmdline_helper(Allocator allocator, ProcContext ctx) @private => @pool() {
    CFile stream = open_proc_stream(ctx, "cmdline")!;
    defer (void)libc::fclose(stream);

    DString content;
    content.init(tmem);
    defer content.free();

    char[4096] buf;

    while (true) {
        usz n = libc::fread(&buf, 1, 4096, stream);
        if (n == 0) break;
        content.append(buf[:n]);
    }

    if (libc::ferror(stream) != 0) return linsys::IO_ERROR~;

    if (content.len() == 0) return "".copy(allocator);

    String result = content.str_view();

    for (usz i = 0; i < result.len; i++) {
        if (result[i] == '\0') result[i] = ' ';
    }

    return result.trim_right().copy(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? read_cmdline(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    return read_cmdline_helper(allocator, ctx);
}

fn String? readlink_alloc(Allocator allocator, ZString path) @private {
    char[256] buf;
    DString result = dstring::new_with_capacity(allocator, 256);
    defer result.free();
    while (true) {
        sz n = libc::readlink(path, &buf, buf.len);
        if (n < 0) {
            switch (libc::errno()) {
                case EACCES: return linsys::PERMISSION_DENIED~;
                case ENOENT: return linsys::PROCESS_EXITED~;
                default: return linsys::IO_ERROR~;
            }
        }
        result.append((String)buf[:n]);
        if (n < buf.len) break;
    }
    return result.copy_str(allocator);
}

extern fn sz readlinkat(CInt dirfd, ZString pathname, char* buf, usz bufsiz);

fn String? read_exe_helper(Allocator allocator, ProcContext ctx) @private {
    char[4096] buf;

    sz n = readlinkat(ctx.dirfd, "exe", &buf, 4096);
    if (n < 0) return linsys::IO_ERROR~;

    return ((String)buf[:(usz)n]).copy(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? read_exe(Allocator allocator, int pid) {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    return read_exe_helper(allocator, ctx);
}

fn int[]? list_pids(Allocator allocator) => @pool() {
    List{int} pids;

    pids.init(allocator);
    Path p        = io::path::new(tmem, "/proc")!;
    PathList list = io::path::ls(tmem, p)!;
    foreach (l : list) {
        if (try int pid = l.file_tbasename().to_int()) {
            pids.push(pid);
        }
    }
    defer pids.free();
    return pids.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn bool exists(int pid) => @pool() {
    String path = string::tformat("/proc/%d", pid);
    return os::native_file_or_dir_exists(path);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? cwd(Allocator allocator, int pid) {
    String path    = string::tformat("/proc/%d/cwd", pid);
    String? result = readlink_alloc(allocator, path.zstr_tcopy());
    if (catch result) {
        switch (libc::errno()) {
            case EACCES:
            case EPERM: return linsys::PERMISSION_DENIED~;
            case ENOENT: return linsys::PROCESS_EXITED~;
            default: return linsys::IO_ERROR~;
        }
    }
    return result;
}

fn String? read_environ_helper(Allocator allocator, ProcContext ctx) @private {
    CFile stream = open_proc_stream(ctx, "environ")!;
    defer (void)libc::fclose(stream);

    return linsys::read_proc_stream(allocator, stream);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn EnvVar[]? environ(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    String content = read_environ_helper(tmem, ctx)!;

    List{EnvVar} ev;
    ev.init(allocator);
    defer ev.free();

    foreach (line : content.split(tmem, "\0")) {
        long? idx = line.index_of_char('=');
        if (catch idx) continue;

        ev.push({ .key = line[:idx].copy(allocator), .value = line[idx + 1..].copy(allocator) });
    }

    return ev.to_array(allocator);
}

fn void EnvVar[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void EnvVar.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

<*
 @require pid > 0 : "pid must be positive"
 @require key.len > 0 : "key must not be empty"
*>
fn String? environ_get(Allocator allocator, int pid, String key) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    String content = read_environ_helper(tmem, ctx)!;

    foreach (line : content.split(tmem, "\0")) {
        long? idx = line.index_of_char('=');
        if (catch idx) continue;

        if (line[:idx] == key) {
            return line[idx + 1..].copy(allocator);
        }
    }

    return linsys::NOT_FOUND~;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String[]? fd_paths(Allocator allocator, int pid) => @pool() {
    List{String} fds;
    fds.init(allocator);

    String proc_fd = string::tformat("/proc/%d/fd", pid);
    Path path      = path::new(tmem, proc_fd)!;
    PathList list  = io::path::ls(tmem, path)!;

    foreach (l : list) {
        String full = string::tformat("%s/%s", proc_fd, l.file_tbasename()!);
        if (try String target = readlink_alloc(allocator, full.zstr_tcopy())) {
            fds.push(target);
        }
    }

    defer fds.free();
    return fds.to_array(allocator);
}

extern fn void* fdopendir(CInt fd) @private;

fn int[]? fds_helper(Allocator allocator, ProcContext ctx) @private => @pool() {
    CInt fd = openat(ctx.dirfd, "fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) {
        return linsys::errno_to_fault()~;
    }

    void* dir = fdopendir(fd);
    if (dir == null) {
        (void)close(fd);
        return linsys::IO_ERROR~;
    }
    defer (void)posix::closedir((DIRPtr)dir);

    List{int} fds;
    fds.init(allocator);
    defer fds.free();

    while (posix::Posix_dirent* entry = posix::readdir((DIRPtr)dir)) {
        String name = ((ZString)&entry.name).str_view();

        if (try int ifd = name.to_int()) {
            fds.push(ifd);
        }
    }

    return fds.to_array(allocator);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn int[]? fds(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    return fds_helper(allocator, ctx);
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn MemoryMap[]? maps(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CFile stream = open_proc_stream(ctx, "maps")!;
    defer (void)libc::fclose(stream);

    String content = linsys::read_proc_stream(tmem, stream)!;

    List{MemoryMap} mm;
    mm.init(allocator);
    defer mm.free();

    foreach (line : content.split(tmem, "\n")) {
        if (line.len == 0) continue;

        String[] split = linsys::split_whitespace(line);

        if (split.len < 5) {
            linsys::push_error("memorymap::maps", linsys::PARSE_ERROR);
            continue;
        }

        MemoryMap entry = { };

        entry.address_range = split[0].copy(allocator);
        mem::copy(&entry.perms, split[1].ptr, math::min(split[1].len, entry.perms.len));
        mem::copy(&entry.device, split[3].ptr, math::min(split[3].len, entry.device.len));

        linsys::@try_field(entry.offset, split[2].to_long(), "memorymap::offset", 0);
        linsys::@try_field(entry.inode, split[4].to_long(), "memorymap::inode", 0);

        if (split.len > 5) {
            entry.pathname = string::tjoin(split[5..], " ").trim().copy(allocator);
        }

        mm.push(entry);
    }

    return mm.to_array(allocator);
}

fn void MemoryMap.free(self, Allocator allocator) => linsys::free_fields(self, allocator);
fn void MemoryMap[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);

struct FlagInfo {
    int flag;
    String name;
}

fn String flags_to_mode(int flags, Allocator allocator) @private => @pool() {
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

    DString result = dstring::new_with_capacity(tmem, 32);

    result.append(access);

    foreach (info : infos) {
        if (flags & info.flag) {
            result.append_char('+');
            result.append(info.name);
        }
    }

    return result.copy_str(allocator);
}

fn String? readlinkat_alloc(Allocator allocator, CInt dirfd, ZString path) @private {
    sz capacity = 256;

    while (true) {
        char* buf = mem::alloc::malloc(allocator, capacity);

        sz n = readlinkat(dirfd, path, buf, (ulong)capacity);

        if (n < 0) {
            fault err = linsys::errno_to_fault();
            mem::alloc::free(allocator, buf);
            return err~;
        }

        if ((usz)n < (ulong)capacity) {
            String result = (String)buf[0..(usz)n];
            return result;
        }

        mem::alloc::free(allocator, buf);

        if (capacity > 1024 * 1024) {
            return linsys::IO_ERROR~;
        }

        capacity *= 2;
    }
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn OpenFile[]? open_files(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    List{OpenFile} of;
    of.init(allocator);
    defer of.free();

    int[] fd_list = fds_helper(tmem, ctx)!;

    foreach (fd : fd_list) {
        String fd_name = string::tformat("fd/%d", fd);

        String? target = readlinkat_alloc(allocator, ctx.dirfd, fd_name.zstr_tcopy());

        if (catch target) {
            linsys::push_error("openfile::fd_link", linsys::IO_ERROR);
            continue;
        }

        if (!target.starts_with("/") || target.ends_with(" (deleted)")) {
            mem::alloc::free(allocator, target);
            continue;
        }

        OpenFile entry   = { .fd = fd, .path = target };
        String info_name = string::tformat("fdinfo/%d", fd);
        CFile stream     = open_proc_stream(ctx, info_name.zstr_tcopy())!;



        {
            defer (void)libc::fclose(stream);

            String content = linsys::read_proc_stream(tmem, stream)!;

            foreach (line : content.split(tmem, "\n")) {
                line = line.trim();

                if (!line.starts_with("flags:")) continue;

                String flags_str = line["flags:".len..].trim();

                if (try int flags = flags_str.to_int(8)) {
                    entry.mode = flags_to_mode(flags, allocator);
                }

                break;
            }
        }

        of.push(entry);
    }

    return of.to_array(allocator);
}


fn void OpenFile[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void OpenFile.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn void? read_connections(
    Allocator allocator,
    ProcContext ctx,
    Protocol proto,
    List{Connection}* out
) @private => @pool() {
    String filename;

    switch (proto) {
        case TCP: filename = "net/tcp";
        case UDP: filename = "net/udp";
        case TCP6: filename = "net/tcp6";
        case UDP6: filename = "net/udp6";
    }

    CFile stream = open_proc_stream(ctx, filename.zstr_tcopy())!;
    defer (void)libc::fclose(stream);

    String content = linsys::read_proc_stream(tmem, stream)!;
    bool is_v6     = proto == Protocol.TCP6 || proto == Protocol.UDP6;
    ushort lp      = 0;
    ushort rp      = 0;

    foreach (i, line : content.split(tmem, "\n")) {
        if (i == 0 || line.len == 0) continue;
        String[] raw = linsys::split_whitespace(line.trim());

        usz n = 0;
        foreach (f : raw) {
            if (f.len > 0) raw[n++] = f;
        }

        if (n < 4) {
            linsys::push_error("connection::line", linsys::PARSE_ERROR);
            continue;
        }

        sz? colon_l = raw[1].index_of_char(':');
        sz? colon_r = raw[2].index_of_char(':');
        if (catch colon_l) {
            linsys::push_error("connection::local_addr", linsys::PARSE_ERROR);
            continue;
        }
        if (catch colon_r) {
            linsys::push_error("connection::remote_addr", linsys::PARSE_ERROR);
            continue;
        }

        linsys::@try_field(
            lp,
            (ushort)(raw[1][colon_l + 1..].to_long(16)),
            "connection::local_port",
            0
        );
        linsys::@try_field(
            rp,
            (ushort)(raw[2][colon_l + 1..].to_long(16)),
            "connection::remote_port",
            0
        );

        out.push(
            {
                .local_addr = is_v6 ? linsys::ip_to_string_v6(
                    allocator,
                    linsys::parse_addr6(raw[1][:colon_l])
                )
                    : linsys::ip_to_string(allocator, linsys::parse_addr(raw[1][:colon_l])),
                .remote_addr = is_v6 ? linsys::ip_to_string_v6(
                    allocator,
                    linsys::parse_addr6(raw[2][:colon_r])
                )
                    : linsys::ip_to_string(allocator, linsys::parse_addr(raw[2][:colon_r])),
                .local_port = lp,
                .remote_port = rp,
                .state = linsys::tcp_state(raw[3]),
                .protocol = proto,
            }
        );
    }
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn Connection[]? connections(Allocator allocator, int pid) {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    List{Connection} list;
    list.init(allocator);
    defer list.free();

    read_connections(allocator, ctx, Protocol.TCP, &list)!;
    read_connections(allocator, ctx, Protocol.UDP, &list)!;
    read_connections(allocator, ctx, Protocol.TCP6, &list)!;
    read_connections(allocator, ctx, Protocol.UDP6, &list)!;

    return list.to_array(allocator);
}

fn void Connection[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void Connection.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

<*
 @require pid > 0 : "pid must be positive"
*>
fn double? create_time(int pid) => @pool() {
    String p  = string::tformat("/proc/%d/stat", pid);
    File file = file::open(p, "r")!;
    defer (void)file.close();

    String raw      = linsys::read_file(file)!;
    String[] fields = parse_proc_stat_fields(tmem, raw)!;

    if (fields.len < 20) return linsys::PARSE_ERROR~;

    ulong? val = fields[19].to_ulong();

    if (catch val) return linsys::PARSE_ERROR~;

    ulong btime = system::boot_time();
    ulong clk   = system::clktck();

    if (clk == 0) return linsys::PARSE_ERROR~;

    return (double)btime + ((double)val / (double)clk);
}

fn String[]? parse_proc_stat_fields(Allocator allocator, String raw) @private => @pool() {
    sz rp = raw.rindex_of(")")!;

    String after = raw[(rp + 2)..];

    String[] raw_fields = linsys::split_whitespace(after);

    List{String} fields;
    fields.init(allocator);
    defer fields.free();

    foreach (f : raw_fields) {
        if (f.len > 0) {
            fields.push(f);
        }
    }

    return fields.to_array(allocator);
}

fn CpuTimes? cpu_times_parse(String path) @private => @pool() {
    CpuTimes cpu = { };
    File file    = file::open(path, "r")!;
    defer (void)file.close();
    String raw      = linsys::read_file(file)!;
    String[] fields = parse_proc_stat_fields(tmem, raw)!;

    if (fields.len > 14) {
        double clk = system::clktck();

        if (try double utime = fields[11].to_double()) {
            cpu.user = utime / clk;
        } else {
            linsys::push_error("cputimes::user", linsys::PARSE_ERROR);
        }
        if (try double stime = fields[12].to_double()) {
            cpu.system = stime / clk;
        } else {
            linsys::push_error("cputimes::system", linsys::PARSE_ERROR);
        }

        if (try double cutime = fields[13].to_double()) {
            cpu.children_user = cutime / clk;
        } else {
            linsys::push_error("cputimes::childre_user", linsys::PARSE_ERROR);
        }

        if (try double cstime = fields[14].to_double()) {
            cpu.children_system = cstime / clk;
        } else {
            linsys::push_error("cputimes::children_system", linsys::PARSE_ERROR);
        }
    }
    return cpu;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn CpuTimes? cpu_times(int pid) => @pool() {
    String p = string::tformat("/proc/%d/stat", pid);
    return cpu_times_parse(p)!;
}

<*
 @require pid > 0 : "pid must be positive"
 @require tid > 0 : "tid must be positive"
*>
fn CpuTimes? cpu_times_threads(int pid, int tid) => @pool() {
    String p = string::tformat("/proc/%d/task/%d/stat", pid, tid);
    return cpu_times_parse(p)!;
}

// Should I even keep this?
<*
 @require pid > 0 : "pid must be positive"
*>
fn ProcessPoller? poller(int pid) {
    return {
        .pid = pid,
        .last_snapshot = cpu_snapshot(pid)!,
    };
}

fn double? ProcessPoller.cpu_percent(&self) {
    double pct = cpu_percent_from(self.last_snapshot, self.pid)!;
    self.last_snapshot = cpu_snapshot(self.pid)!;
    return pct;
}

fn double? ProcessPoller.memory_percent(&self) {
    return memory_percent(self.pid);
}

fn IoCounters? ProcessPoller.io_counters(&self) {
    return io_counters(self.pid);
}

fn bool ProcessPoller.exists(&self) => exists(self.pid);

<*
 @require pid > 0 : "pid must be positive"
*>
fn CpuSnapshot? cpu_snapshot(int pid) {
    CpuTimes times = cpu_times(pid)!;
    ulong total    = linsys::read_total_cpu_time()!;
    return { times.user + times.system, total };
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn double? cpu_percent_from(CpuSnapshot first, int pid) {
    CpuTimes times     = cpu_times(pid)!;
    ulong total2       = linsys::read_total_cpu_time()!;
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

fn ulong? parse_proc_ulong(String path, String key) @private => @pool() {
    ulong result = 0;
    File file    = file::open(path, "r")!;
    defer (void)file.close();

    while (try line = io::treadline(&file)) {
        if (!line.starts_with(key)) continue;
        String[] s = line.trim().split(tmem, ":");
        if (s.len < 2) continue;
        if (try ulong v = s[1].trim().strip_suffix(" kB").to_ulong()) result = v;
        break;
    }
    return result;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn double? memory_percent(int pid) => @pool() {
    String p        = string::tformat("/proc/%d/status", pid);
    ulong vmrs      = parse_proc_ulong(p, "VmRSS")!;
    ulong total_mem = parse_proc_ulong("/proc/meminfo", "MemTotal")!;
    if (total_mem == 0) return 0.0;
    return ((double)vmrs / (double)total_mem) * 100.0;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn IoCounters? io_counters(int pid) => @pool() {
    IoCounters ioc = { };
    String path    = string::tformat("/proc/%d/io", pid);
    File file      = file::open(path, "r")!;
    defer (void)file.close();

    while (try line = io::treadline(&file)) {
        String[] split = line.split(tmem, ":");
        if (split.len < 2) {
            linsys::push_error("iocounters::line", linsys::PARSE_ERROR);
            continue;
        }

        String key = split[0].trim();
        ulong v    = 0;
        linsys::@try_field(v, split[1].trim().to_ulong(), "iocounters::value", 0);

        switch (key) {
            case "rchar": ioc.read_count = v;
            case "wchar": ioc.write_count = v;
            case "read_bytes": ioc.read_bytes = v;
            case "write_bytes": ioc.write_bytes = v;
        }
    }
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
        case EPERM: return linsys::PERMISSION_DENIED~;
        case ESRCH: return linsys::NO_SUCH_PROCESS~;
        default: return linsys::UNKNOWN~;
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
fn int[]? children(Allocator allocator, int pid, bool recursive = false) => @pool() {
    ProcContext target = open_proc_context(pid)!;
    defer close_proc_context(target);

    int[] pid_list = list_pids(tmem)!;

    List{PidEntry} entries;
    entries.init(tmem);

    foreach (p : pid_list) {
        @pool() {
            ProcContext ctx = open_proc_context(p)!!;
            defer close_proc_context(ctx);

            CFile stream = open_proc_stream(ctx, "stat")!!;
            defer (void)libc::fclose(stream);

            String stat = linsys::read_proc_stream(tmem, stream)!!;

            sz? end_comm = stat.rindex_of(")");
            if (catch end_comm) {
                linsys::push_error("children::stat", linsys::PARSE_ERROR);
                continue;
            }

            String after    = stat[end_comm + 2..];
            String[] fields = linsys::split_whitespace(after);

            if (fields.len < 2) {
                linsys::push_error("children::fields", linsys::PARSE_ERROR);
                continue;
            }

            if (try int ppid = fields[1].to_int()) {
                entries.push({ p, ppid });
            }
        };
    }

    List{int} result;
    result.init(allocator);
    defer result.free();

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
fn int? parent(int pid) => @pool() {
    String path = string::tformat("/proc/%d/stat", pid);
    File file   = file::open(path, "r")!;
    defer (void)file.close();
    char[4096] buf;
    sz n            = file.read(&buf)!;
    String stat     = (String)buf[:n];
    String[] fields = parse_proc_stat_fields(tmem, stat)!;
    if (fields.len < 2) return linsys::PARSE_ERROR~;
    return fields[1].to_int()!;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn int? nice_get(int pid) {
    CInt p = libc::getpriority(libc::PRIO_PROCESS, pid);
    if (libc::errno() != 0) {
        switch (libc::errno()) {
            case ESRCH: return linsys::NICE_NO_SUCH_PROCESS~;
            case EPERM: return linsys::NICE_PERMISSION_DENIED~;
            default: return linsys::NICE_INVALID~;
        }
    }
    return (int)p;
}

<*
 @require pid > 0 : "pid must be positive"
 @require value >= -20 && value <= 19 : "nice value must be in range -20..19"
*>
fn void? nice_set(int pid, int value) {
    if (libc::setpriority(libc::PRIO_PROCESS, pid, value) != 0) {
        switch (libc::errno()) {
            case ESRCH: return linsys::NICE_NO_SUCH_PROCESS~;
            case EPERM: return linsys::NICE_PERMISSION_DENIED~;
            default: return linsys::NICE_INVALID~;
        }
    }
}

struct CpuSet {
    ulong[16] bits;
}

extern fn CInt sched_setaffinity(CInt pid, usz cpusetsize, CpuSet* mask) @private;
extern fn CInt sched_getaffinity(CInt pid, usz cpusetsize, CpuSet* mask) @private;

<*
 @require pid > 0 : "pid must be positive"
*>
fn int[]? cpu_affinity_get(Allocator allocator, int pid) {
    CpuSet cpu_set = { };
    if (sched_getaffinity((CInt)pid, @sizeof(cpu_set), &cpu_set) != 0) {
        switch (libc::errno()) {
            case ESRCH: return linsys::SCHED_NO_SUCH_PROCESS~;
            case EPERM: return linsys::SCHED_PERMISSION_DENIED~;
            default: return linsys::SCHED_INVALID~;
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
            case ESRCH: return linsys::SCHED_NO_SUCH_PROCESS~;
            case EPERM: return linsys::SCHED_PERMISSION_DENIED~;
            default: return linsys::SCHED_INVALID~;
        }
    }
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn RLimitEntry[]? rlimits_get(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    ZString path  = string::tformat("/proc/%d/limits", pid).zstr_tcopy();
    CFile? stream = open_proc_stream(ctx, path);
    defer (void)libc::fclose(stream);

    String? lines = linsys::read_proc_stream(tmem, stream);
    if (catch lines) return linsys::IO_ERROR~;

    List{RLimitEntry} entries;
    entries.init(allocator);
    defer entries.free();

    int i = 0;

    foreach (line : lines.tsplit("\n")) {
        if (i++ == 0 || line.len == 0) continue;
        String[] parts = linsys::split_whitespace(line.trim());
        int pc         = 0;
        String[4] filtered;

        foreach (p : parts) {
            String t = p.trim();
            if (t.len > 0) filtered[pc++] = t;
            if (pc == 4) break;
        }

        if (pc < 3) {
            linsys::push_error("rlimitentry::line", linsys::PARSE_ERROR);
            continue;
        }

        ulong soft;
        ulong hard;

        if (filtered[1] == "unlimited") {
            soft = ulong::max;
        } else {
            linsys::@try_field(soft, filtered[1].to_ulong(), "limit::soft", 0);
        }
        if (filtered[2] == "unlimited") {
            hard = ulong::max;
        } else {
            linsys::@try_field(hard, filtered[2].to_ulong(), "limit::hard", 0);
        }

        entries.push(
            { .name = filtered[0].copy(allocator), .limit = { .soft = soft, .hard = hard } }
        );
    }

    return entries.to_array(allocator);
}

fn void RLimitEntry[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void RLimitEntry.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

<*
 @require pid > 0 : "pid must be positive"
*>
fn ThreadInfo[]? threads(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CInt fd = openat(ctx.dirfd, "task", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return linsys::errno_to_fault()~;

    void* dir = fdopendir(fd);
    if (dir == null) {
        fault err = linsys::errno_to_fault();
        (void)close(fd);
        return err~;
    }
    defer (void)posix::closedir((DIRPtr)dir);

    List{ThreadInfo} ti;
    ti.init(allocator);
    defer ti.free();

    while (posix::Posix_dirent* entry = posix::readdir((DIRPtr)dir)) {
        String name = ((ZString)&entry.name).str_view();

        if (try int tid = name.to_int()) {
            // should you use existing context??
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
}

fn void ThreadInfo[].free(self, Allocator allocator) => linsys::free_slice(self, allocator);
fn void ThreadInfo.free(self, Allocator allocator) => linsys::free_fields(self, allocator);

fn Process[]? all_processes(Allocator allocator) => @pool() {
    int[] pids = list_pids(tmem)!;
    List{Process} result;
    result.init(allocator);
    defer result.free();

    foreach (pid : pids) {
        if (try Process p = proc(allocator, pid)) {
            result.push(p);
        }
    }
    return result.to_array(allocator);
}

<*
 @require name.len > 0 : "name must not be empty"
*>
fn Process[]? find_by_name(Allocator allocator, String name) => @pool() {
    int[] pids = list_pids(tmem)!;
    List{Process} result;
    result.init(allocator);
    defer result.free();

    foreach (pid : pids) {
        if (try Process p = proc(allocator, pid)) {
            if (p.name == name) {
                result.push(p);
            } else {
                p.free(allocator);
            }
        }
    }
    return result.to_array(allocator);
}

struct Passwd {
    char* pw_name;
    char* pw_passwd;
    uint pw_uid;
    uint pw_gid;
    char* pw_gecos;
    char* pw_dir;
    char* pw_shell;
}

extern fn Passwd* getpwuid(uint uid);

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? username(Allocator allocator, int pid) => @pool() {
    if (!exists(pid)) return linsys::NO_SUCH_PROCESS~;
    ProcessInfo? p = info(tmem, pid);
    if (catch p) return linsys::UNKNOWN~;

    Passwd* pw = getpwuid((uint)p.uid);

    if (pw == null) {
        return linsys::USER_NOT_FOUND~;
    }

    return ((ZString)pw.pw_name).copy(allocator);
}

struct Timespec {
    long tv_sec;
    long tv_nsec;
}

struct Stat {
    ulong st_dev;
    ulong st_ino;
    ulong st_nlink;
    uint st_mode;
    uint st_uid;
    uint st_gid;
    int __pad0;
    ulong st_rdev;
    long st_size;
    long st_blksize;
    long st_blocks;
    Timespec st_atim;
    Timespec st_mtim;
    Timespec st_ctim;
    long[3] __glibc_reserved;
}

extern fn int stat(ZString path, Stat* statbuf) @private;

fn String? terminal_helper(Allocator allocator, ProcContext ctx) @private => @pool() {
    CFile stream = open_proc_stream(ctx, "stat")!;
    defer (void)libc::fclose(stream);

    char[4096] buf;
    ZString raw = libc::fgets(&buf, 4096, stream);

    if (raw == null) return linsys::IO_ERROR~;

    String content  = raw.str_view();
    String[] fields = parse_proc_stat_fields(tmem, content)!;

    if (fields.len <= 4) return linsys::PARSE_ERROR~;

    int tty_nr = fields[4].to_int()!;

    if (tty_nr == 0) return linsys::NO_TERMINAL~;

    Stat stat;

    PathList list = io::path::ls(tmem, (Path)"/dev/pts/")!;

    foreach (l : list) {
        String device = string::tformat("/dev/pts/%s", l);

        if (process::stat(device.zstr_tcopy(), &stat) != 0) continue;

        if (stat.st_rdev == (ulong)tty_nr) {
            return device.copy(allocator);
        }
    }

    foreach (l : io::path::ls(tmem, (Path)"/dev/")!) {
        if (!l.contains("tty")) continue;

        String device = string::tformat("/dev/%s", l);

        if (process::stat(device.zstr_tcopy(), &stat) != 0) continue;

        if (stat.st_rdev == (ulong)tty_nr) {
            return device.copy(allocator);
        }
    }

    return linsys::TERMINAL_NOT_FOUND~;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn String? terminal(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    return terminal_helper(allocator, ctx);
}

struct MemoryFullInfo {
    ulong rss;
    ulong vms;
    ulong shared;
    ulong text;
    ulong lib;
    ulong data;
    ulong dirty;
    ulong uss;
    ulong pss;
    ulong swap;
}

const _SC_PAGESIZE = 30; // TODO: VERIFY THIS

fn ulong get_page_size() @private {
    CLong page_size = os::posix::sysconf(_SC_PAGESIZE);
    return (ulong)page_size;
}

fn String? read_vms_file(Allocator allocator, int pid) @private => @pool() {
    String path = string::tformat("/proc/%d/statm", pid);
    File? file  = file::open(path, "r");
    defer (void)file.close();
    if (catch file) return linsys::IO_ERROR~;

    return linsys::read_file(file).copy(allocator).trim();
}

fn MemoryFullInfo? read_statm(MemoryFullInfo* mfi, ProcContext ctx) @private => @pool() {
    CFile stream = open_proc_stream(ctx, "statm")!;
    defer (void)libc::fclose(stream);

    String statm    = linsys::read_proc_stream(tmem, stream)!;
    String[] fields = linsys::split_whitespace(statm.trim());

    if (fields.len < 7) return linsys::PARSE_ERROR~;

    if (fields.len < 7) return linsys::IO_ERROR~;

    ulong page_size = get_page_size();

    linsys::@try_field_append(
        mfi.vms,
        fields[0].to_ulong() * page_size,
        "memory_full_info::Vms",
        0
    );

    linsys::@try_field_append(
        mfi.rss,
        fields[1].to_ulong() * page_size,
        "memory_full_info::Rss",
        0
    );

    linsys::@try_field_append(
        mfi.shared,
        fields[2].to_ulong() * page_size,
        "memory_full_info::Shared",
        0
    );

    linsys::@try_field_append(
        mfi.text,
        fields[3].to_ulong() * page_size,
        "memory_full_info::Text",
        0
    );

    linsys::@try_field_append(
        mfi.lib,
        fields[4].to_ulong() * page_size,
        "memory_full_info::Lib",
        0
    );

    linsys::@try_field_append(
        mfi.data,
        fields[5].to_ulong() * page_size,
        "memory_full_info::Data",
        0
    );

    linsys::@try_field_append(
        mfi.dirty,
        fields[6].to_ulong() * page_size,
        "memory_full_info::Dirty",
        0
    );

    return *mfi;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn MemoryFullInfo? memory_full_info(int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    MemoryFullInfo mfi = { };
    read_statm(&mfi, ctx)!;

    CFile stream = open_proc_stream(ctx, "smaps")!;
    defer (void)libc::fclose(stream);

    String content = linsys::read_proc_stream(tmem, stream)!;

    foreach (line : content.tsplit("\n")) {
        sz? idx = line.index_of_char(':');
        if (catch idx) continue;

        String key   = line[:idx].trim();
        String value = line[idx + 1..].trim_right("kB").trim();

        switch (key) {
            case "Private_Clean":
                linsys::@try_field_append(
                    mfi.uss,
                    value.to_ulong() * 1024,
                    "memory_full_info::Uss",
                    0
                );

            case "Private_Dirty":
                linsys::@try_field_append(
                    mfi.uss,
                    value.to_ulong() * 1024,
                    "memory_full_info::Uss",
                    0
                );

            case "Pss":
                linsys::@try_field_append(
                    mfi.pss,
                    value.to_ulong() * 1024,
                    "memory_full_info::Pss",
                    0
                );

            case "Swap":
                linsys::@try_field_append(
                    mfi.swap,
                    value.to_ulong() * 1024,
                    "memory_full_info::Swap",
                    0
                );
        }
    }

    return mfi;
}

struct PageFault {
    int minor;
    int major;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn PageFault? page_fault(int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CFile stream = open_proc_stream(ctx, "stat")!;
    defer (void)libc::fclose(stream);

    String content  = linsys::read_proc_stream(tmem, stream)!;
    String[] fields = parse_proc_stat_fields(tmem, content)!;

    if (fields.len <= 9) return linsys::PARSE_ERROR~;

    PageFault pf = { };
    linsys::@try_field(pf.minor, fields[7].to_int(), "page_fault::minor", 0);
    linsys::@try_field(pf.major, fields[9].to_int(), "page_fault::major", 0);

    return pf;
}

struct CtxSwitches {
    int voluntary;
    int involuntary;
}

<*
 @require pid > 0 : "pid must be positive"
*>
fn CtxSwitches? ctx_switches(int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CFile stream = open_proc_stream(ctx, "status")!;
    defer (void)libc::fclose(stream);

    String content       = linsys::read_proc_stream(tmem, stream)!;
    CtxSwitches switches = { };

    foreach (line : content.tsplit("\n")) {
        sz? idx = line.index_of_char(':');
        if (catch idx) continue;

        String key   = line[:idx].trim();
        String value = line[idx + 1..].trim();

        switch (key) {
            case "voluntary_ctxt_switches":
                linsys::@try_field_append(
                    switches.voluntary,
                    value.to_int(),
                    "ctx_switches::voluntary",
                    0
                );

            case "nonvoluntary_ctxt_switches":
                linsys::@try_field_append(
                    switches.involuntary,
                    value.to_int(),
                    "ctx_switches::involuntary",
                    0
                );
        }
    }

    return switches;
}

struct ProcessCgroup {
    String controllers;
    String path;
    String name;
}

// TODO: Recheck this
<*
 @require pid > 0 : "pid must be positive"
*>
fn ProcessCgroup? cgroup(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CFile stream = open_proc_stream(ctx, "cgroup")!;
    defer (void)libc::fclose(stream);

    String content = linsys::read_proc_stream(tmem, stream)!;

    foreach (line : content.tsplit("\n")) {
        line = line.trim();

        String[] fields = line.split(tmem, ":");
        if (fields.len < 3) continue;

        String controller  = fields[1].trim();
        String cgroup_path = fields[2].trim();

        if (cgroup_path.len == 0) continue;

        ProcessCgroup result;
        result.controllers = controller.copy(allocator);
        result.path = cgroup_path.copy(allocator);

        sz? slash = cgroup_path.rindex_of_char('/');
        if (catch slash) {
            result.name = cgroup_path.copy(allocator);
        } else {
            result.name = cgroup_path[slash + 1..].copy(allocator);
        }

        return result;
    }

    return linsys::IO_ERROR~;
}

struct Namespace {
    NamespaceType type;
    ulong inode;
}

enum NamespaceType {
    PID,
    MOUNT,
    NET,
    IPC,
    UTS,
    USER,
    CGROUP,
    TIME,
}

fn Namespace? namespace_helper(ProcContext ctx, NamespaceType type) @private => @pool() {
    String name;

    switch (type) {
        case NamespaceType.PID: name = "pid";
        case NamespaceType.MOUNT: name = "mnt";
        case NamespaceType.NET: name = "net";
        case NamespaceType.IPC: name = "ipc";
        case NamespaceType.UTS: name = "uts";
        case NamespaceType.USER: name = "user";
        case NamespaceType.CGROUP: name = "cgroup";
        case NamespaceType.TIME: name = "time";
    }

    String path   = string::tformat("ns/%s", name);
    String target = readlinkat_alloc(tmem, ctx.dirfd, path.zstr_tcopy())!;

    sz start = target.index_of_char('[')!;
    sz end   = target.index_of_char(']')!;

    if (end <= start + 1) return linsys::PARSE_ERROR~;

    ulong inode = target[start + 1..end].to_ulong()!;

    return { .type = type, .inode = inode };
}

fn Namespace? namespace(Allocator allocator, int pid, NamespaceType type) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    return namespace_helper(ctx, type);
}

fn Namespace[]? namespaces(Allocator allocator, int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    List{Namespace} result;
    result.init(allocator);
    defer result.free();

    NamespaceType[] types = {
        NamespaceType.PID,
        NamespaceType.MOUNT,
        NamespaceType.NET,
        NamespaceType.IPC,
        NamespaceType.UTS,
        NamespaceType.USER,
        NamespaceType.CGROUP,
        NamespaceType.TIME,
    };

    foreach (type : types) {
        Namespace? ns = namespace_helper(ctx, type);
        if (catch ns) continue;

        result.push(ns);
    }

    return result.to_array(allocator);
}

struct SchedulingInfo {
    SchedulingPolicy policy;
    int priority;
}

constdef SchedulingPolicy : CInt {
    OTHER    = 0,
    FIFO     = 1,
    RR       = 2,
    BATCH    = 3,
    IDLE     = 5,
    DEADLINE = 6,
}

struct SchedParam {
    int sched_priority;
}

extern fn int sched_getscheduler(int pid);
extern fn int sched_setscheduler(int pid, int policy, SchedParam* param);
extern fn int sched_getparam(int pid, SchedParam* param);
extern fn int sched_setparam(int pid, SchedParam* param);

extern fn int sched_get_priority_max(int policy);
extern fn int sched_get_priority_min(int policy);
extern fn int sched_rr_get_interval(int pid, Timespec* interval);

fn SchedulingInfo? scheduling(int pid) => @pool() {
    int policy = sched_getscheduler(pid);
    if (policy < 0) return linsys::IO_ERROR~;

    SchedParam param;
    if (sched_getparam(pid, &param) != 0) return linsys::IO_ERROR~;

    SchedulingInfo result;
    result.policy = (SchedulingPolicy)policy;
    result.priority = param.sched_priority;

    return result;
}

fn void? set_scheduling(int pid, SchedulingPolicy policy, int priority) => @pool() {
    PriorityRange range = priority_range(policy)!;

    if (priority < range.min || priority > range.max) return linsys::INVALID_ARGUMENT~;

    SchedParam param;
    param.sched_priority = priority;

    if (sched_setscheduler(pid, (int)policy, &param) != 0) {
        return linsys::IO_ERROR~;
    }
}

struct PriorityRange {
    int min;
    int max;
}

fn PriorityRange? priority_range(SchedulingPolicy policy) => @pool() {
    int min = sched_get_priority_min((int)policy);
    if (min < 0) return linsys::IO_ERROR~;

    int max = sched_get_priority_max((int)policy);
    if (max < 0) return linsys::IO_ERROR~;

    PriorityRange result;
    result.min = min;
    result.max = max;

    return result;
}

fn void? set_priority(int pid, int priority) => @pool() {
    SchedParam param;
    param.sched_priority = priority;

    if (sched_setparam(pid, &param) != 0) return linsys::IO_ERROR~;
}

fn Timespec? rr_interval(int pid) => @pool() {
    Timespec interval;

    if (sched_rr_get_interval(pid, &interval) != 0) return linsys::IO_ERROR~;

    return interval;
}

struct SchedStat {
    ulong run_time_ns;
    ulong runqueue_wait_ns;
    ulong timeslices;
}

fn SchedStat? sched_stat(int pid) => @pool() {
    ProcContext ctx = open_proc_context(pid)!;
    defer close_proc_context(ctx);

    CFile stream = open_proc_stream(ctx, "schedstat")!;
    defer (void)libc::fclose(stream);

    String content  = linsys::read_proc_stream(tmem, stream)!;
    String[] fields = linsys::split_whitespace(content.trim());

    if (fields.len < 3) return linsys::PARSE_ERROR~;

    SchedStat result = { };

    linsys::@try_field(result.run_time_ns, fields[0].to_ulong(), "sched_stat::run_time_ns", 0);

    linsys::@try_field(
        result.runqueue_wait_ns,
        fields[1].to_ulong(),
        "sched_stat::runqueue_wait_ns",
        0
    );

    linsys::@try_field(result.timeslices, fields[2].to_ulong(), "sched_stat::timeslices", 0);

    return result;
}

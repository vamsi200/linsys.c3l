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
    String exe_path;
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
    TcpState state ;
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

fn String read_file(Allocator allocator, File file){
    char[4096] temp;
    DString builder;
    builder.init(allocator);

    while (true) {
	sz n = file.read(&temp)!!;
	if (n==0) break;
	builder.append(temp[:n]);
	
    }
	
   return builder.str_view();
}

fn ProcessInfo? proc_get_info(Allocator allocator, int pid){
    String path = string::tformat("/proc/%d/status", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();

    String content = read_file(allocator, file);
    defer catch alloc::free(allocator, content);

    String[] lines = content.split(allocator, "\n");
    defer catch alloc::free(allocator, lines);

    ProcessInfo proc = {};
    Process p = proc_get(allocator, pid)!;

    foreach (line : lines) {
	long? idx = line.index_of_char(':');
	if (catch err = idx) continue; 
	if (idx == -1) continue;

        String key = line[:idx].trim();
        String data = line[idx+1..].trim();
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

    proc.exe_path = proc_read_exe(pid)!;
    proc.cmdline = proc_read_cmdline(pid)!;
    proc.process = p;

    return proc;
}

fn Process? proc_get(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/status", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();

    String content = read_file(allocator, file);
    defer alloc::free(allocator, content);

    String[] lines = content.split(allocator, "\n");
    defer alloc::free(allocator, lines);

    Process p;

    foreach (line: lines) {
	long? idx = line.index_of_char(':');
	if (catch err = idx) continue;
	if (idx == -1) continue;

        String key = line[:idx].trim();
        String data = line[idx+1..].trim();

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

  return p;
}

// NOTE: is this the correct way?
fn int[]? proc_list_pids(Allocator allocator) {
    Path p = io::path::new(allocator, "/proc")!;
    defer alloc::free(allocator, p);

    PathList list = io::path::ls(allocator, p)!;
    defer list.free();
    sz count = 0;

    foreach (l: list) {
        if (try l.file_tbasename().to_int()) {
          count++;
        }
    }
  
    int[] proc_list = mem::alloc::alloc_array(allocator, int, count);
    int i = 0;

    foreach (l: list) {
      if (try int pid = l.file_tbasename().to_int()) {
        proc_list[i++] = pid;
      }
    }

    return proc_list;
}

fn bool proc_exists(int pid) {
    int[] proc_list = proc_list_pids(tmem)!!;
    foreach (p: proc_list){
       if (p == pid) {
          return true;
       }
    }
    return false;
}

fn String proc_cwd(int pid) {
    char[4096] buf;
    String path = string::tformat("/proc/%d/cwd", pid);

    sz len = libc::readlink(
        (ZString)path,
        &buf,
        buf.len - 1
    );

    if (len <= 0) {
        return "";
    }

    buf[len] = 0;

    return (String)buf[:len];
}

fn EnvVar[]? proc_environ(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/environ", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();

    String[] s = read_file(allocator, file).split(allocator, "\0");
    defer alloc::free(allocator, s);

    EnvVar[] ev = mem::alloc::alloc_array(allocator, EnvVar, s.len);

    int i = 0;
    EnvVar entry = {};

    foreach (line: s) {
	long? idx = line.index_of_char('=');
	if (catch err = idx) continue;
	if (idx == -1) continue;

        entry.key = line[:idx].trim().copy(allocator);
        entry.value = line[idx+1..].trim().copy(allocator);
        ev[i++] = entry;
    }

    return ev[:i];
}

fn String? proc_read_cmdline(int pid) {
    String path = string::tformat("/proc/%d/cmdline", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();
    String cmdline;
    String content = read_file(tmem, file);
    sz len = content.len;

    if (len == 0) {
        cmdline = "";
    } else {
        for (sz i = 0; i < len; i++) {
            if (content[i] == '\0') {
                content[i] = ' ';
            }
        }

        cmdline = ((String)content[:len]).copy(tmem);
    }

    return cmdline.trim_right();

}

fn String? proc_read_exe(int pid) {
    String path = string::tformat("/proc/%d/exe", pid);
    char[4096] buf;

    sz len = libc::readlink((ZString)path, &buf, buf.len - 1);
    String exe_path;

    if (len > 0){
        exe_path = ((String)buf[:len]).copy(tmem);
    }
    else{
        exe_path = "";
    }

  return exe_path;
}

fn String[]? proc_fds_path(Allocator allocator, int pid) {
    String p = string::tformat("/proc/%d/fd", pid);
    Path path = path::new(allocator, p)!;
    defer alloc::free(allocator, path);
    PathList list = io::path::ls(allocator, path)!;
    defer list.free();
    String[] fds = mem::alloc::alloc_array(allocator, String, list.len());
    char[4096] buf;
    int i = 0;

    foreach (l: list) {
        String full = string::tformat("%s/%s", p, l.file_tbasename()!);
        ZString zpath = full.zstr_tcopy();
        sz n = libc::readlink(zpath, &buf, buf.len - 1);
        if (n < 0) continue;
        fds[i++] = ((String)buf[:n]).copy(allocator);
    }
    return fds[:i];
}

fn int[]? proc_fds(Allocator allocator, int pid) {
    String p = string::tformat("/proc/%d/fd", pid);
    Path path = path::new(allocator, p)!;
    defer alloc::free(allocator, path);

    PathList list = io::path::ls(allocator, path)!;
    defer list.free();

    int[] fds = mem::alloc::alloc_array(allocator, int, list.len());
    int i = 0;

    foreach (fd: list) {
	if (try int ifd = fd.trim().to_int()) fds[i++] = ifd;
    }

   return fds[:i];
}

// Should I even keep this function and the struct???
fn ProcStat? proc_read_stat(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/stat", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();
    String s = read_file(allocator, file);
    sz close = s.rindex_of_char(')')!;
    sz open = s.index_of_char('(')!;

    ProcStat ps = {};
    ps.pid = pid;
    ps.comm = s[open+1..close].strip_suffix(")").copy(allocator);

    String rest = s[close+2..];
    String[] fields = rest.split(allocator, " ");
    if (fields.len < 3) return string::CONVERSION_FAILED~;

    ps.state = fields[0][0];
    if (try int ppid  = fields[1].to_int()) ps.ppid  = ppid;
    if (try int pgrp  = fields[2].to_int()) ps.pgrp  = pgrp;
    if (try int tty   = fields[4].to_int()) ps.tty_nr = tty;

    return ps;
}

fn MemoryMap[]? proc_maps(Allocator allocator, int pid) {
    String p = string::tformat("/proc/%d/maps", pid);
    File file = file::open(p, "r")!!;
    defer (void)file.close();
    String[] lines = read_file(allocator, file).tsplit("\n");
    defer alloc::free(allocator, lines);
    MemoryMap[] mm = mem::alloc::alloc_array(allocator, MemoryMap, lines.len);
    int i = 0;
    MemoryMap entry = {};

    foreach (line: lines) {
      if (line.len == 0) continue;
      String[] split = line.tsplit(" ");

      if (split.len < 5) continue;
      entry.address_range = split[0];
      entry.perms = split[1];
      if (try long offset = split[2].to_long()) entry.offset = offset;
      entry.device = split[3];
      if (try long inode = split[4].to_long()) entry.inode = inode;

      if (split.len > 5) {
          entry.pathname = string::tjoin(split[5..], " ").trim();
      }

      mm[i++] = entry;

  }

   return mm[:i];
}

fn String flags_to_mode(int flags, Allocator allocator) {
    String access;
    switch (flags & 3) {
        case 0: access = "r";
        case 1: access = "w";
        case 2: access = "rw";
        default: access = "?";
    }

    String[*] modifiers = {
        [0] = "append",
        [1] = "nonblock",
        [2] = "dsync",
        [3] = "async",
        [4] = "direct",
        [5] = "largefile",
        [6] = "noatime",
        [7] = "cloexec",
    };

    int[*] modifier_flags = {
        [0] = 0o02000,   // O_APPEND
        [1] = 0o04000,   // O_NONBLOCK
        [2] = 0o010000,  // O_DSYNC
        [3] = 0o020000,  // O_ASYNC
        [4] = 0o040000,  // O_DIRECT
        [5] = 0o100000,  // O_LARGEFILE
        [6] = 0o1000000, // O_NOATIME
        [7] = 0o2000000, // O_CLOEXEC
    };

    DString result = dstring::new_with_capacity(allocator, 32);
    result.append(access);
        
    for (int i = 0; i < modifiers.len; i++) {
        if (flags & modifier_flags[i]) {
            result.append_char('+');
            result.append(modifiers[i]);
        }
    }
    return result.tcopy_str();
}

fn OpenFile[]? proc_open_files(Allocator allocator, int pid){
    int[] fds = proc_fds(allocator, pid)!!;
    defer alloc::free(allocator, fds);
    OpenFile[] of = mem::alloc::alloc_array(allocator, OpenFile, fds.len);
    char[4096] link_buf;
    char[4096] fdinfo_buf;

    int i = 0;

    foreach (fd : fds) {
        OpenFile entry = {};
        String fd_path =  string::tformat("/proc/%d/fd/%d", pid, fd);
        if (!os::native_file_or_dir_exists(fd_path)) continue;

        ZString zpath = fd_path.zstr_tcopy();
        sz n = libc::readlink(
            zpath,
            &link_buf,
            link_buf.len - 1
        );

        if (n < 0) continue;
        String target = (String)link_buf[0:n];

        if (!target.starts_with("/") || target.ends_with(" (deleted)")) {
            continue;
        }

        if (!os::native_file_or_dir_exists(target)) continue;

        entry.fd = fd;
        entry.path = target.copy(allocator);

        String info_path =
            string::tformat("/proc/%d/fdinfo/%d", pid, fd); 

	{
            File file = file::open(info_path, "r")!!;
            defer (void)file.close();
            sz len = file.read(&fdinfo_buf)!!;
            String text = (String)fdinfo_buf[0:len];

            foreach (line : text.tsplit("\n")) {
                line = line.trim();
                if (!line.starts_with("flags:")) continue;
                String flags_str = line["flags:".len..].trim();

                if (try int flags = flags_str.to_int(8)) {
                    entry.mode = flags_to_mode(flags, tmem);
                }
                break;
            }
        }
	
        of[i++] = entry;
    }

    return of[:i];
}

fn uint parse_addr(String hex) {
	uint i = (uint)hex.to_long(16) ?? 0;
	return ((i & 0xFF) << 24) | ((i & 0xFF00) << 8) | ((i & 0xFF0000) >> 8) | ((i >> 24) & 0xFF);
}

fn String ip_to_string(Allocator allocator, uint ip) {
    return string::format(allocator, "%d.%d.%d.%d",
        (ip >> 24) & 0xFF,
        (ip >> 16) & 0xFF,
        (ip >>  8) & 0xFF,
        ip         & 0xFF);
}

fn TcpState tcp_state(String hex){
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

// TODO: add v6
fn void read_connections(Allocator allocator, int pid, Protocol proto, List {Connection}* out){
	String filename;
	switch (proto) {
		case TCP:  filename = "tcp";
		case UDP:  filename = "udp";
	}

	String path = string::tformat("/proc/%d/net/%s", pid, filename);
	if (!os::native_file_or_dir_exists(path)) return;
	File file = file::open(path, "r")!!;
	defer (void)file.close();
	String[] lines = read_file(allocator, file).split(allocator, "\n");

	foreach (i, line : lines) {
		if (i == 0 || line.len == 0) continue;

		String[] raw = line.trim().split(allocator, " ");
		List{String} fields;
		fields.init(allocator);
		foreach (f : raw) if (f.len > 0) fields.push(f);
		if (fields.len() < 4) continue;

		String[] local  = fields[1].split(allocator, ":");
		String[] remote = fields[2].split(allocator, ":");
		if (local.len < 2 || remote.len < 2) continue;
		Connection entry = {
		    .local_addr  = ip_to_string(allocator, parse_addr(local[0])),
		    .remote_addr = ip_to_string(allocator, parse_addr(remote[0])),
		    .local_port  = (ushort)(local[1].to_long(16)  ?? 0),
		    .remote_port = (ushort)(remote[1].to_long(16) ?? 0),
		    .state       = tcp_state(fields[3]),
		    .protocol    = proto,
	       };
		out.push(entry);
	}
	

}

fn Connection[]? proc_connections(Allocator allocator, int pid) {
	List{Connection} list;
	list.init(allocator);
	defer list.free();

	read_connections(allocator, pid, Protocol.TCP,  &list);
	read_connections(allocator, pid, Protocol.UDP,  &list);

	return list.to_array(allocator);
}

fn ulong proc_read_boot_time() {
	File file = file::open("/proc/stat", "r")!!;
	defer (void)file.close();
	ulong btime;
	String[] lines = read_file(tmem, file).split(tmem, "\n");
	foreach (line: lines) {
		if (line.contains("btime")) {
			String s = line.strip_suffix("btime ");
			if (try ulong bt = s.to_ulong()) btime = bt;
		}
	}
	
	return btime;
}

// getconf CLK_TCK
fn ulong read_clktck() {
	File file = file::open("/proc/self/auxv", "rb")!!;
	defer (void)file.close();
	char[4096] buf;
	sz n = file.read(&buf)!!;

	sz i = 0;
	while (i + 16 <= n) {
	ulong type, val;
	mem::copy(&type, &buf[i], 8);
	mem::copy(&val,  &buf[i + 8], 8);

	if (type == 17) return val; // AT_CLKTCK
	if (type == 0)  break;      // AT_NULL
	i += 16;
	}
	return 100;
}

// re-check this impl
fn double? proc_create_time(int pid) {
    String p = string::tformat("/proc/%d/stat", pid);
    File file = file::open(p, "r")!!;
    defer (void)file.close();
    double start_time;
    @pool() {
        String raw = read_file(tmem, file);
        sz rp = raw.rindex_of(")")!!;
        String after = raw[(rp + 2)..];
        String[] fields = after.split(tmem, " ");
        if (fields.len < 20) return 0;
        if (try ulong val = fields[19].to_ulong()) {
            ulong btime = proc_read_boot_time();
            ulong clktck = read_clktck();
            start_time = (double)btime + ((double)val / (double)clktck);
        }
    };
    return start_time;
}

fn CpuTimes? cpu_times_parse(String path) @private {
    CpuTimes cpu = {};
    File file = file::open(path, "r")!!;
    defer (void)file.close();
    String raw = read_file(tmem, file);
    sz rp = raw.rindex_of(")")!!;
    String after = raw[(rp + 2)..];
    @pool() {
        String[] fields = after.split(tmem, " ");
        if (fields.len > 14) {
            double clktck = (double)read_clktck();
            if (try double utime  = fields[11].to_double() &&
                try double stime  = fields[12].to_double() &&
                try double cutime = fields[13].to_double() &&
                try double cstime = fields[14].to_double()) {
                cpu.user            = utime  / clktck;
                cpu.system          = stime  / clktck;
                cpu.children_user   = cutime / clktck;
                cpu.children_system = cstime / clktck;
            }
        }
    };
    return cpu;
}

fn CpuTimes? proc_cpu_times(int pid) {
	String p = string::tformat(
		"/proc/%d/stat",
		pid
	);

	return cpu_times_parse(p);
}

fn CpuTimes? proc_cpu_times_threads(int pid, int tid) {
	String p = string::tformat(
		"/proc/%d/task/%d/stat",
		pid,
		tid
	);

	return cpu_times_parse(p);
}

fn double? proc_cpu_percent(int pid, double interval) {
    CpuTimes first = proc_cpu_times(pid)!!;
    double proc1 = first.user + first.system;
    ulong total1 = 0;
    int cpu_count = 0;
    @pool() {
        File file1 = file::open("/proc/stat", "r")!!;
        defer (void)file1.close();
        String[] lines1 = read_file(tmem, file1).split(tmem, "\n");
        foreach (i, line : lines1) {
            if (i == 0) {
                String[] split = line.strip_prefix("cpu ").trim().split(tmem, " ");
                if (split.len < 8) return 0.0;
                total1 =
                    split[0].to_ulong()! + split[1].to_ulong()! +
                    split[2].to_ulong()! + split[3].to_ulong()! +
                    split[4].to_ulong()! + split[5].to_ulong()! +
                    split[6].to_ulong()! + split[7].to_ulong()!;
            } else if (line.starts_with("cpu")) {
                cpu_count += 1;
            }
        }
    };

    thread::sleep_ms((long)(interval * 1000));

    CpuTimes second = proc_cpu_times(pid)!!;
    double proc2 = second.user + second.system;
    ulong total2 = 0;
    @pool() {
        char[4096] buf2;
        File file2 = file::open("/proc/stat", "r")!!;
        defer (void)file2.close();
        sz n2 = file2.read(&buf2)!!;
        String[] lines2 = ((String)buf2[:n2]).split(tmem, "\n");
        foreach (i, line : lines2) {
            if (i != 0) continue;
            String[] split = line.strip_prefix("cpu ").trim().split(tmem, " ");
            if (split.len < 8) return 0.0;
            total2 =
                split[0].to_ulong()! + split[1].to_ulong()! +
                split[2].to_ulong()! + split[3].to_ulong()! +
                split[4].to_ulong()! + split[5].to_ulong()! +
                split[6].to_ulong()! + split[7].to_ulong()!;
            break;
        }
    };

    double proc_delta = proc2 - proc1;
    double total_delta = (double)(total2 - total1);
    if (total_delta <= 0) return 0.0;
    return (proc_delta / total_delta) * cpu_count * 100.0;
}

fn double? proc_memory_percent(int pid) {
    ulong vmrs = 0;
    @pool() {
        String p = string::tformat("/proc/%d/status", pid);
        File file = file::open(p, "r")!!;
        defer (void)file.close();
        char[4096] buf;
        sz n = file.read(&buf)!!;
        String[] lines = ((String)buf[:n]).split(tmem, "\n");
        foreach (line: lines) {
            if (!line.starts_with("VmRSS")) continue;
            String[] s = line.trim().split(tmem, ":");
            if (s.len < 2) continue;
            if (try ulong v = s[1].strip_suffix(" kB").to_ulong()) vmrs = v;
        }
    };

    ulong total_mem = 0;
    @pool() {
        File file1 = file::open("/proc/meminfo", "r")!!;
        defer (void)file1.close();
        char[4096] buf1;
        sz n1 = file1.read(&buf1)!!;
        String[] lines1 = ((String)buf1[:n1]).split(tmem, "\n");
        foreach (line: lines1) {
            if (!line.starts_with("MemTotal")) continue;
            String[] s1 = line.trim().split(tmem, ":");
            if (s1.len < 2) continue;
            if (try ulong tv = s1[1].strip_suffix(" kB").to_ulong()) total_mem = tv;
        }
    };

    if (total_mem == 0) return 0.0;
    return ((double)vmrs / (double)total_mem) * 100.0;
}

fn IoCounters? proc_io_counters(int pid) {
    IoCounters ioc = {};
    @pool() {
        String p = string::tformat("/proc/%d/io", pid);
        File file = file::open(p, "r")!!;
        defer (void)file.close();
        char[4096] buf;
        sz n = file.read(&buf)!!;
        String[] lines = ((String)buf[:n]).split(tmem, "\n");
        foreach (line : lines) {
            String[] split = line.split(tmem, ":");
            if (split.len < 2) continue;
            String key = split[0].trim();
            String value = split[1].trim();
            switch (key) {
                case "rchar":
                    if (try ulong v = value.to_ulong()) ioc.read_bytes = v;
                case "wchar":
                    if (try ulong v = value.to_ulong()) ioc.write_bytes = v;
                case "read_bytes":
                    if (try ulong v = value.to_ulong()) ioc.read_count = v;
                case "write_bytes":
                    if (try ulong v = value.to_ulong()) ioc.write_count = v;
                default:
                    continue;
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
    INT = 2,
}

fn bool proc_send_signal(int pid, Signal signal) {
    if (pid <= 0) {
        return false;
    }
    return posix::kill(pid, (CInt)signal) == 0;
}

fn bool proc_suspend(int pid) {
    return proc_send_signal(pid, Signal.STOP);
}

fn bool proc_resume(int pid) {
    return proc_send_signal(pid, Signal.CONT);
}

fn bool proc_kill(int pid) {
    return proc_send_signal(pid, Signal.KILL);
}

fn bool proc_terminate(int pid) {
    return proc_send_signal(pid, Signal.TERM);
}

fn bool proc_interrupt(int pid) {
    return proc_send_signal(pid, Signal.INT);
}

//TODO: improve this later -- why??
fn int[]? proc_children(Allocator allocator, int pid, bool recursive) {
    int[] pid_list = proc_list_pids(allocator)!;
    defer alloc::free(allocator, pid_list);

    int[] children = mem::alloc::alloc_array(allocator, int, pid_list.len);
    char[4096] buf;
    int i = 0;

    foreach (p : pid_list) {
        @pool() {
            String path = string::tformat("/proc/%d/stat", p);
            File? file = file::open(path, "r");
            if (catch err = file) continue;
            defer (void)file.close();
            sz? n = file.read(&buf);
            if (catch err = n) continue; // should you continue??
            String stat = (String)buf[:n];
            sz end_comm = stat.rindex_of(")")!;
            String after = stat[end_comm + 2..];
            String[] fields = after.split(tmem, " ");
            if (fields.len < 2) continue;
            int ppid = fields[1].to_int()!;
            if (ppid == pid) {
                children[i++] = p;
                if (recursive) {
                    int[] sub = proc_children(allocator, p, true)!;
                    defer alloc::free(allocator, sub);
                    foreach (child : sub) {
                        children[i++] = child;
                    }
                }
            }
        };
    }
    return children[:i];
}

fn int? proc_parent(int pid) {
    @pool() {
        String path = string::tformat("/proc/%d/stat", pid);
        File file = file::open(path, "r")!;
        defer (void)file.close();
        char[4096] buf;
        sz n = file.read(&buf)!;
        String stat = (String)buf[:n];
        sz end_comm = stat.rindex_of(")")!;
        String after = stat[end_comm + 2..];
        String[] fields = after.split(tmem, " ");
        if (fields.len < 2) return 0;
        return fields[1].to_int()!;
    };
}

fn int? proc_nice_get(int pid) {
	CInt p = libc::getpriority(libc::PRIO_PROCESS, pid);

	if (libc::errno() != 0) {
		return io::FILE_NOT_FOUND~;
	}

	return (int)p;
}

fn bool proc_nice_set(int pid, int value) {
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

fn int[]? proc_cpu_affinity_get(Allocator allocator, int pid) {
    CpuSet cpu_set = {};
    CInt out = sched_getaffinity((CInt)pid, @sizeof(cpu_set), &cpu_set);
    if (out != 0) {
        io::printfn("sched_getaffinity failed: %d", out);
    }
    int count = 0;
    int[1024] tmp;
    for (sz i = 0; i < 1024; i++) {
        if (cpu_set.bits[i/64] & (1UL << (i % 64))) {
            tmp[count++] = (int)i;
        }
    }
    int[] output = mem::alloc::alloc_array(allocator, int, count);
    output[..count] = tmp[:count];
    return output;
}

fn void proc_cpu_affinity_set(int pid, int[] cpus) {
	CpuSet cpu_set = {};
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

fn RLimitEntry[]? proc_rlimits_get(Allocator allocator, int pid) {
    @pool() {
        String path = string::tformat("/proc/%d/limits", pid);
        File file = file::open(path, "r")!!;
        defer (void)file.close();
        char[4096] buf;
        sz n = file.read(&buf)!!;
        String content = (String)buf[:n];
        String[] lines = content.split(tmem, "\n");
        RLimitEntry[] entries = mem::alloc::alloc_array(allocator, RLimitEntry, lines.len);
        int count = 0;
        foreach (line : lines[1..]) {
            if (line.len == 0) continue;
            String[] parts = line.trim().tsplit("  ");
            int pc = 0;
            String[4] filtered;
            foreach (p : parts) {
                String t = p.trim();
                if (t.len > 0) filtered[pc++] = t;
                if (pc == 4) break;
            }
            if (pc < 2) continue;
            ulong soft = filtered[1] == "unlimited" ? ulong::max : (filtered[1].to_ulong() ?? 0);
            ulong hard = pc > 2 && filtered[2] == "unlimited" ? ulong::max : (filtered[2].to_ulong() ?? 0);
            entries[count++] = {
                .name  = filtered[0].copy(allocator),
                .limit = { .soft = soft, .hard = hard }
            };
        }
        return entries[:count];
    };
}

fn ThreadInfo[]? proc_threads(Allocator allocator, int pid) {
    @pool() {
        Path path = string::tformat("/proc/%d/task", pid).to_path(tmem)!;
        PathList list = io::path::ls(tmem, path)!;
        ThreadInfo[] ti = mem::alloc::alloc_array(allocator, ThreadInfo, list.len());
        int count = 0;
        foreach (l: list) {
            if (try int tid = l.to_int()) {
                CpuTimes? ct = proc_cpu_times_threads(pid, tid);
                if (catch err = ct) continue;
                ti[count++] = {
                    .tid = tid,
                    .cpu_times = {
                        .user            = ct.user,
                        .system          = ct.system,
                        .children_user   = ct.children_user,
                        .children_system = ct.children_system,
                    }
                };
            }
        }
        return ti[:count];
    };
}

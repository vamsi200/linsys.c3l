import std::io;
import std::io::file;
import libc;
import std::core::string;
import  std::collections::list;
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

struct ProcStatus {
    int pid;
    String name;
    char state;
    int ppid;
    int uid;
    int gid;
    int threads;
    long vm_size;
    long vm_rss;
}

struct CpuTimes {
    double user;
    double system;
    double children_user;
    double children_system;
}

struct IoCounters {
    long read_count;
    long write_count;
    long read_bytes;
    long write_bytes;
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
    long soft;
    long hard;
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

fn ProcessInfo? proc_get_info(Allocator allocator, int pid){
String path = string::tformat("/proc/%d/status", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();

    char[4096] buf;
    sz n = file.read(&buf)!!;
    String content = (String)buf[0:n];
    String[] lines = content.split(allocator, "\n");

    ProcessInfo proc;
    Process p = proc_get(allocator, pid)!;

    foreach (line : lines) {
        String[] split = line.split(allocator, ":");

        if (split.len != 2) continue;

        String key = split[0].trim();
        String data = split[1].trim();

        switch (key) {
        case "Threads":
            proc.threads = data.to_int()!;

        case "Uid":
            String[] d = data.split(allocator, "\t");

            if (try int uid = d[0].to_int()) proc.uid = uid;

        case "Gid":
            String[] d = data.split(allocator, "\t");

            if (try int gid = d[0].to_int()) proc.gid = gid;

        case "VmSize":
            String[] d = data.split(allocator, " ");

            if (try long vms = d[0].to_long()) proc.vm_size = vms;

        case "VmRSS":
            String[] d = data.split(allocator, " ");

            if (try long vmrss = d[0].to_long()) proc.vm_rss = vmrss;

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

    char[4096] buf;
    sz n = file.read(&buf)!!;
    String content = (String)buf[0:n];
    String[] lines = content.split(allocator, "\n");

    Process p;

    foreach (line: lines) {
        String[] split = line.split(allocator, ":");
        if (split.len != 2) continue;
        String key = split[0].trim();
        String data = split[1].trim();

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
    String s = "";
    PathList list = io::path::ls(allocator, p)!;
    sz count = 0;

    foreach (l: list) {
        if (try l.file_basename(allocator).to_int()) {
          count++;
      }
    }
  
    int[] proc_list = mem::alloc::alloc_array(allocator, int, count);
    int i = 0;

    foreach (l: list) {
      if (try int pid = l.file_basename(allocator).to_int()) {
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

// NOTE: Should we handle error? throught the library?
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

    return (String)buf[0:len];
}

fn EnvVar[]? proc_environ(Allocator allocator, int pid) {
    char[4096] buf;
    String path = string::tformat("/proc/%d/environ", pid);
    File f = file::open(path, "r")!;
    defer (void)f.close();
    sz size = f.read(&buf)!!;

    String[] s = ((String)buf[0:size]).split(allocator, "\0");
    EnvVar[] ev = mem::alloc::alloc_array(allocator, EnvVar, s.len);
    int i = 0;
    EnvVar entry;
    foreach (line: s) {
        String[] split = line.split(allocator, "=");
        if (split.len < 2) {
            continue;
        }
        entry.key = split[0].trim().copy(allocator);
        entry.value = split[1].trim().copy(allocator);
        ev[i++] = entry;
    }

    return ev[0:i];
}

fn String? proc_read_cmdline(int pid) {
    String path = string::tformat("/proc/%d/cmdline", pid);
    File f = file::open(path, "r")!!;
    defer (void)f.close();
    char[4096] buf;
    String cmdline;
    sz len = f.read(&buf)!!;

    if (len == 0) {
        cmdline = "";
    } else {

        for (sz i = 0; i < len; i++) {
            if (buf[i] == '\0') {
                buf[i] = ' ';
            }
        }

        cmdline = ((String)buf[0:len]).copy(mem);
    }

    return cmdline.trim_right();

}

fn String? proc_read_exe(int pid) {
    String path = string::tformat("/proc/%d/exe", pid);
    char[4096] buf;

    sz len = libc::readlink((ZString)path, &buf, buf.len - 1);
    String exe_path;

    if (len > 0){
        exe_path = ((String)buf[0:len]).copy(mem);
    }
    else{
        exe_path = "";
    }

  return exe_path;
}

fn String[]? proc_fds_path(Allocator allocator, int pid) {
    String p = string::tformat("/proc/%d/fd", pid);
    Path path = path::new(allocator, p)!;
    PathList list = io::path::ls(allocator, path)!;
    String[] fds = mem::alloc::alloc_array(allocator, String, list.len());
    char[4096] buf;
    int i = 0;

    foreach (l: list) {
        String full = string::tformat("%s/%s", p, l.file_basename(allocator)!);
        ZString zpath = full.zstr_tcopy();
        sz n = libc::readlink(zpath, &buf, buf.len - 1);
        if (n < 0) continue;
        fds[i++] = ((String)buf[0:n]).copy(allocator);
    }
    return fds[0:i];
}

fn int[]? proc_fds(Allocator allocator, int pid) {
	String p = string::tformat("/proc/%d/fd", pid);
	Path path = path::new(allocator, p)!;
	PathList list = io::path::ls(allocator, path)!;
	int[] fds = mem::alloc::alloc_array(allocator, int, list.len());
	int i = 0;

	foreach (fd: list) {
		if (try int ifd = fd.trim().to_int()) fds[i++] = ifd;
	}

	return fds[0:i];

}

// Should I even keep this function and the struct???
fn ProcStat? proc_read_stat(Allocator allocator, int pid) {
    String path = string::tformat("/proc/%d/stat", pid);
    File f = file::open(path, "r")!;
    defer (void)f.close();
    char[256] buf;
    sz n = f.read(&buf)!;
    String s = ((String)buf[0:n]).copy(allocator);

    sz close = s.rindex_of_char(')')!;
    sz open = s.index_of_char('(')!;

    ProcStat ps;
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
    File f = file::open(p, "r")!!;
    defer (void)f.close();

    char[4096] buf; // think about this
    sz n = f.read(&buf)!!;
    String[] lines = ((String)buf[0:n]).copy(allocator).split(mem, "\n");
    MemoryMap[] mm = mem::alloc::alloc_array(allocator, MemoryMap, lines.len);
    int i = 0;
    MemoryMap entry;
    foreach (line: lines) {
      if (line.len == 0) continue;
      String[] split = line.split(allocator, " ");
      if (split.len < 5) continue;
      entry.address_range = split[0];
      entry.perms = split[1];
      if (try long offset = split[2].to_long()) entry.offset = offset;
      entry.device = split[3];
      if (try long inode = split[4].to_long()) entry.inode = inode;

      if (split.len > 5) {
          entry.pathname = string::join(allocator, split[5..], " ").trim();
      }

      mm[i++] = entry;

  }

   return mm[0:i];
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
    return result.str_view();
}

fn OpenFile[]? proc_open_files(Allocator allocator, int pid) {
	int[] fds = proc_fds(allocator, pid)!!;
	String path;
	String final_path;
	String mode_path;
	String mode;
	OpenFile[] of = mem::alloc::alloc_array(allocator, OpenFile, fds.len);
	OpenFile entry;
	char[4096] buf;
	char[4096] content;
	int i = 0;
	File file;
	defer (void)file.close();

	foreach (fd: fds) {
		entry = {};
		path = string::tformat("/proc/%d/fd/%d", pid, fd);
		if (!os::native_file_or_dir_exists(path)) continue;
		ZString zpath = path.zstr_tcopy();
		sz n = libc::readlink(zpath, &buf, buf.len - 1);
		if (n < 0) continue;
		String s = ((String)buf[0:n]).copy(allocator);
		if (s.starts_with("/") && !s.ends_with(" (deleted)")) {
			entry.fd = fd;
			if (os::native_file_or_dir_exists(s)) entry.path = s.copy(allocator);
			mode_path = string::tformat("/proc/%d/fdinfo/%d", pid, fd);
			file = file::open(mode_path, "r")!!;
			sz len = file.read(&content)!!;
			String[] lines = ((String)content[0:len]).copy(allocator).split(mem, "\n");
			foreach (line: lines) {
				String[] split = line.trim().split(allocator, ":");
				if (split.len < 2) continue;
				if (split[0] == "flags") {
					if (try int flags = split[1].trim().to_int(8)) {
					    entry.mode = flags_to_mode(flags, mem);
					}
				}
			}
			of[i++] = entry;
		}
	}

	return of[0:i];
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
	char[65536] buf;
	File file = file::open(path, "r")!!;
	defer (void)file.close();
	sz n = file.read(&buf)!!;
	String[] lines = ((String)buf[0:n]).copy(allocator).split(allocator, "\n");

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

	read_connections(allocator, pid, Protocol.TCP,  &list);
	read_connections(allocator, pid, Protocol.UDP,  &list);

	return list.array_view();
}

fn ProcStatus? proc_read_status(int pid) { abort("Not Yet Implemented!"); }

fn ulong proc_read_boot_time() {
	File file = file::open("/proc/stat", "r")!!;
	ulong btime;
	char[8096] buf;
	sz n = file.read(&buf)!!;
	String[] lines = ((String)buf[:n]).split(tmem, "\n");
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

fn double? proc_create_time(int pid) {
	String p = string::tformat("/proc/%d/stat", pid);
	File file = file::open(p, "r")!!;
	char[4096] buf;
	sz n = file.read(&buf)!!;
	double start_time;
	String raw = (String)buf[:n];
	sz rp = raw.rindex_of(")")!!;
	String after = raw[(rp + 2)..];

	String[] fields = after.split(tmem, " ");
	if (fields.len < 20) return 0;

	if (try ulong val = fields[19].to_ulong()) {
	ulong btime = proc_read_boot_time();
	ulong clktck = read_clktck();
	start_time = (double)btime + ((double)val / (double)clktck);
	}
	return start_time;

}

fn CpuTimes? proc_cpu_times(int pid) {  
	CpuTimes cpu  = {};
	String p = string::tformat("/proc/%d/stat", pid);
	File file = file::open(p, "r")!!;
	char[4096] buf;
	sz n = file.read(&buf)!!;
	String raw = (String)buf[:n];
	sz rp = raw.rindex_of(")")!!;
	String after = raw[(rp + 2)..];

	String[] fields = after.split(tmem, " ");
	if (fields.len <= 14) return cpu;
	double clktck = (double)read_clktck();
	if (try double utime = fields[11].to_double() &&
		try double stime = fields[12].to_double() &&
		try double cutime = fields[13].to_double() &&
		try double cstime = fields[14].to_double())
	{
		cpu.user = utime / clktck;
		cpu.system = stime / clktck ;
		cpu.children_user = cutime / clktck;
		cpu.children_system = cstime / clktck;
	}

	return cpu;   		
}

fn double? proc_cpu_percent(int pid, double interval) {
	CpuTimes first = proc_cpu_times(pid)!!;

	double proc1 = first.user + first.system;

	File file1 = file::open("/proc/stat", "r")!!;
	char[4096] buf1;
	sz n1 = file1.read(&buf1)!!;
	String[] lines1 = ((String)buf1[:n1]).split(tmem, "\n");
	ulong total1 = 0;
	int cpu_count = 0;

	foreach (i, line : lines1) {
		if (i == 0) {
			String[] split = line.strip_prefix("cpu ").trim().split(tmem, " ");
			if (split.len < 8) return 0.0;
			total1 =
				split[0].to_ulong()! +
				split[1].to_ulong()! +
				split[2].to_ulong()! +
				split[3].to_ulong()! +
				split[4].to_ulong()! +
				split[5].to_ulong()! +
				split[6].to_ulong()! +
				split[7].to_ulong()!;
		}
		else if (line.starts_with("cpu")) {
			cpu_count += 1;
		}
	}

	thread::sleep_ms((long)(interval * 1000));
	CpuTimes second = proc_cpu_times(pid)!!;
	double proc2 = second.user + second.system;
	File file2 = file::open("/proc/stat", "r")!!;
	char[4096] buf2;
	sz n2 = file2.read(&buf2)!!;
	String[] lines2 = ((String)buf2[:n2]).split(tmem, "\n");
	ulong total2 = 0;

	foreach (i, line : lines2) {
		if (i != 0) continue;
		String[] split = line.strip_prefix("cpu ").trim().split(tmem, " ");
		if (split.len < 8) return 0.0;
		total2 =
			split[0].to_ulong()! +
			split[1].to_ulong()! +
			split[2].to_ulong()! +
			split[3].to_ulong()! +
			split[4].to_ulong()! +
			split[5].to_ulong()! +
			split[6].to_ulong()! +
			split[7].to_ulong()!;
		break;
	}

	double proc_delta = proc2 - proc1;
	double total_delta = (double)(total2 - total1);
	if (total_delta <= 0) return 0.0;
	return (proc_delta / total_delta) * cpu_count * 100.0;
}

fn double? proc_memory_percent(int pid) { abort("Not Yet Implemented!"); }
fn IoCounters? proc_io_counters(int pid) { abort("Not Yet Implemented!"); }

fn void proc_send_signal(int pid, int signal) { abort("Not Yet Implemented!"); }
fn void proc_suspend(int pid) { abort("Not Yet Implemented!"); }
fn void proc_resume(int pid) { abort("Not Yet Implemented!"); }
fn void proc_kill(int pid) { abort("Not Yet Implemented!"); }
fn void proc_terminate(int pid) { abort("Not Yet Implemented!"); }
fn int[]? proc_children(int pid, bool recursive) { abort("Not Yet Implemented!"); }
fn int? proc_parent(int pid) { abort("Not Yet Implemented!"); }
fn int? proc_nice_get(int pid) { abort("Not Yet Implemented!"); }
fn void proc_nice_set(int pid, int value) { abort("Not Yet Implemented!"); }
fn int[]? proc_cpu_affinity_get(int pid) { abort("Not Yet Implemented!"); }
fn void proc_cpu_affinity_set(int pid, int[] cpus) { abort("Not Yet Implemented!"); }
fn RLimitEntry[]? proc_rlimits(int pid) { abort("Not Yet Implemented!"); }
fn ThreadInfo[]? proc_threads(int pid) { abort("Not Yet Implemented!"); }

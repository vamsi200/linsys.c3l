import std::io;
import std::io::file;
import libc;
import std::core::string;

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
    String status;
    String protocol;
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

fn ProcessInfo? proc_get_info(Allocator mem, int pid){
String path = string::tformat("/proc/%d/status", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();

    char[4096] buf;
    usz n = file.read(&buf)!!;
    String content = (String)buf[0:n];
    String[] lines = content.split(mem, "\n");

    ProcessInfo proc;
    Process p = proc_get(mem, pid)!;

    foreach (line : lines) {
        String[] split = line.split(mem, ":");

        if (split.len != 2) continue;

        String key = split[0].trim();
        String data = split[1].trim();

        switch (key) {
        case "Threads":
            proc.threads = data.to_int()!;

        case "Uid":
            String[] d = data.split(mem, "\t");

            if (try int uid = d[0].to_int()) proc.uid = uid;

        case "Gid":
            String[] d = data.split(mem, "\t");

            if (try int gid = d[0].to_int()) proc.gid = gid;

        case "VmSize":
            String[] d = data.split(mem, " ");

            if (try long vms = d[0].to_long()) proc.vm_size = vms;

        case "VmRSS":
            String[] d = data.split(mem, " ");

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

fn Process? proc_get(Allocator mem, int pid) {
    String path = string::tformat("/proc/%d/status", pid);
    File file = file::open(path, "r")!;
    defer (void)file.close();

    char[4096] buf;
    usz n = file.read(&buf)!!;
    String content = (String)buf[0:n];
    String[] lines = content.split(mem, "\n");

    Process p;

    foreach (line: lines) {
        String[] split = line.split(mem, ":");
        if (split.len != 2) continue;
        String key = split[0].trim();
        String data = split[1].trim();

      switch (key) {
        case "Pid":
            p.pid = data.to_int()!;

        case "PPid":
            p.ppid = data.to_int()!;

        case "Name":
            p.name = data.copy(mem);

        case "State":
            p.state = data[0];

        default:
            continue;
    }
  }

  return p;
}

// NOTE: is this the correct way?
fn int[]? proc_list_pids(Allocator mem) {
    Path p = io::path::new(mem, "/proc")!;
    String s = "";
    PathList list = io::path::ls(mem, p)!;
    usz count = 0;

    foreach (l: list) {
        if (try l.path_string.to_int()) {
          count++;
      }
    }
  
    int[] proc_list = mem::alloc::alloc_array(mem, int, count);
    int i = 0;

    foreach (l: list) {
      if (try int pid = l.path_string.to_int()) {
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

    isz len = libc::readlink(
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

fn EnvVar[]? proc_environ(Allocator mem, int pid) {
    char[4096] buf;
    String path = string::tformat("/proc/%d/environ", pid);
    File f = file::open(path, "r")!;
    defer (void)f.close();
    usz size = f.read(&buf)!!;

    String[] s = ((String)buf[0:size]).split(mem, "\0");
    EnvVar[] ev = mem::alloc::alloc_array(mem, EnvVar, s.len);
    int i = 0;
    EnvVar entry;
    foreach (line: s) {
        String[] split = line.split(mem, "=");
        if (split.len < 2) {
            continue;
        }
        entry.key = split[0].trim().copy(mem);
        entry.value = split[1].trim().copy(mem);
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
    usz len = f.read(&buf)!!;

    if (len == 0) {
        cmdline = "";
    } else {

        for (usz i = 0; i < len; i++) {
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

    isz len = libc::readlink((ZString)path, &buf, buf.len - 1);
    String exe_path;

    if (len > 0){
        exe_path = ((String)buf[0:len]).copy(mem);
    }
    else{
        exe_path = "";
    }

  return exe_path;
}

fn String[]? proc_fds(Allocator mem, int pid) {
    String p = string::tformat("/proc/%d/fd", pid);
    Path path = path::new(mem, p)!;
    PathList list = io::path::ls(mem, path)!;
    String[] fds = mem::alloc::alloc_array(mem, String, list.len());
    char[4096] buf;
    int i = 0;

    foreach (l: list) {
        String full = string::tformat("%s/%s", p, l.path_string);
        ZString zpath = full.zstr_tcopy();
        isz n = libc::readlink(zpath, &buf, buf.len - 1);
        if (n < 0) continue;
        fds[i++] = ((String)buf[0:n]).copy(mem);
    }
    return fds[0:i];
}

// Should I even keep this function and the struct???
fn ProcStat? proc_read_stat(Allocator mem, int pid) {
    String path = string::tformat("/proc/%d/stat", pid);
    File f = file::open(path, "r")!;
    defer (void)f.close();
    char[256] buf;
    usz n = f.read(&buf)!;
    String s = ((String)buf[0:n]).copy(mem);

    usz close = s.rindex_of_char(')')!;
    usz open = s.index_of_char('(')!;

    ProcStat ps;
    ps.pid = pid;
    ps.comm = s[open+1..close].strip_end(")").copy(mem);

    String rest = s[close+2..];
    String[] fields = rest.split(mem, " ");
    if (fields.len < 3) return string::CONVERSION_FAILED~;

    ps.state = fields[0][0];
    if (try int ppid  = fields[1].to_int()) ps.ppid  = ppid;
    if (try int pgrp  = fields[2].to_int()) ps.pgrp  = pgrp;
    if (try int tty   = fields[4].to_int()) ps.tty_nr = tty;

    return ps;
}

fn MemoryMap[]? proc_maps(Allocator mem, int pid) {
    String p = string::tformat("/proc/%d/maps", pid);
    File f = file::open(p, "r")!!;
    defer (void)f.close();

    char[4096] buf; // think about this
    usz n = f.read(&buf)!!;
    String[] lines = ((String)buf[0:n]).copy(mem).split(mem, "\n");
    MemoryMap[] mm = mem::alloc::alloc_array(mem, MemoryMap, lines.len);
    int i = 0;
    MemoryMap entry;
    foreach (line: lines) {
      if (line.len == 0) continue;
      String[] split = line.split(mem, " ");
      if (split.len < 5) continue;
      entry.address_range = split[0];
      entry.perms = split[1];
      if (try long offset = split[2].to_long()) entry.offset = offset;
      entry.device = split[3];
      if (try long inode = split[4].to_long()) entry.inode = inode;

      if (split.len > 5) {
          entry.pathname = string::join(mem, split[5..], " ").trim();
      }

      mm[i++] = entry;

  }

   return mm;
}

fn OpenFile[]? proc_open_files(int pid) { abort("Not Yet Implemented!"); }
fn ProcStatus? proc_read_status(int pid) { abort("Not Yet Implemented!"); }
fn long? proc_create_time(int pid) { abort("Not Yet Implemented!"); }
fn CpuTimes? proc_cpu_times(int pid) { abort("Not Yet Implemented!"); }
fn double? proc_cpu_percent(int pid, double interval) { abort("Not Yet Implemented!"); }
fn double? proc_memory_percent(int pid) { abort("Not Yet Implemented!"); }
fn IoCounters? proc_io_counters(int pid) { abort("Not Yet Implemented!"); }
fn Connection[]? proc_connections(int pid) { abort("Not Yet Implemented!"); }
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

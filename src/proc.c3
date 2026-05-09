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

    path = string::tformat("/proc/%d/exe", pid);

    isz len = libc::readlink((ZString)path, &buf, buf.len - 1);

    if (len > 0){
        proc.exe_path = ((String)buf[0:len]).copy(mem);
    }
    else{
        proc.exe_path = "";
    }

    path = string::tformat("/proc/%d/cmdline", pid);
    File f = file::open(path, "r")!!;
    defer (void)f.close();
    String cmdline;
    usz clen = f.read(&buf)!!;

    if (clen == 0) {
        cmdline = "";
    } else {

        for (usz i = 0; i < clen; i++) {
            if (buf[i] == '\0') {
                buf[i] = ' ';
            }
        }

        cmdline = ((String)buf[0:clen]).copy(mem);
    }

      proc.cmdline = cmdline;
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

fn ProcStat? proc_read_stat(int pid) { abort("Not Yet Implemented!"); }
fn ProcStatus? proc_read_status(int pid) { abort("Not Yet Implemented!"); }
fn String? proc_read_cmdline(int pid) { abort("Not Yet Implemented!"); }
fn String? proc_read_exe(int pid) { abort("Not Yet Implemented!"); }


fn bool proc_is_running(int pid) { abort("Not Yet Implemented!"); }
fn long? proc_create_time(int pid) { abort("Not Yet Implemented!"); }
fn CpuTimes? proc_cpu_times(int pid) { abort("Not Yet Implemented!"); }
fn double? proc_cpu_percent(int pid, double interval) { abort("Not Yet Implemented!"); }
fn double? proc_memory_percent(int pid) { abort("Not Yet Implemented!"); }
fn IoCounters? proc_io_counters(int pid) { abort("Not Yet Implemented!"); }
fn String? proc_cwd(int pid) { abort("Not Yet Implemented!"); }
fn EnvVar[]? proc_environ(int pid) { abort("Not Yet Implemented!"); }
fn OpenFile[]? proc_open_files(int pid) { abort("Not Yet Implemented!"); }
fn String[]? proc_fds(int pid) { abort("Not Yet Implemented!"); }
fn Connection[]? proc_connections(int pid) { abort("Not Yet Implemented!"); }
fn MemoryMap[]? proc_maps(int pid) { abort("Not Yet Implemented!"); }
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

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


fn ProcStat? proc_read_stat(int pid) { abort("Not Yet Implemented!"); }
fn ProcStatus? proc_read_status(int pid) { abort("Not Yet Implemented!"); }
fn String? proc_read_cmdline(int pid) { abort("Not Yet Implemented!"); }
fn String? proc_read_exe(int pid) { abort("Not Yet Implemented!"); }
fn Process? proc_get(int pid) { abort("Not Yet Implemented!"); }
fn ProcessInfo? proc_get_info(int pid) { abort("Not Yet Implemented!"); }
fn int[]? proc_list_pids() { abort("Not Yet Implemented!"); }
fn bool proc_exists(int pid) { abort("Not Yet Implemented!"); }
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

# linsys.c3l

A simple Linux system and process introspection library for C3.

`linsys.c3l` provides APIs for querying system state, inspecting processes and monitoring resources.


# Features

- Process inspection and management
- CPU and system statistics
- Memory and swap information
- Disk usage and IO statistics
- Network interfaces and connections
- Hardware sensors and battery information

# Error Handling

Functions returning structs will often return partially populated values instead of failing entirely when individual fields cannot be retrieved due to:
- permission restrictions
- missing kernel information
- unsupported interfaces
- process state changes

Example:

```c
ProcessInfo pi = get_info(tmem, pid) ?? {};
```
Some fields inside `ProcessInfo` may be just empty if specific information could not be read, while the overall call still succeeds.

## Inspecting field level erros
If you need detailed errors, you can enable error collection like this:

```c
linsys::init_errors(&alloc);

ProcessInfo pi = process::get_info(&alloc, pid) ?? {};

foreach (e : *linsys::list_errors()) {
    io::printfn("field '%s' failed: %s", e.field, e.f); // f is here a "fault"
}

linsys::free_errors();
```
This allows the callers to know which fields failed and why. Error collection is optional and 
disabled by default.

## Operation level failures
Functions will still fail normally in cases where the primary operation itself cannot be completed, like:
- process does not exist
- `/proc/<pid>` cannot be accessed
- required files are missing

## Api's that fail directly
Some API's have a single operation rather than data collection, therefore they fail immediately when the operation cannnot be completed and should be handled explicitly by the caller.

example:
```c
process::cpu_affinity_set(...)
process::read_exe(...)
process::read_cmdline(...)
```

# Installation
Create a new C3 project ( get latest compiler - https://github.com/c3lang/c3c)

```bash
c3c init app
cd app
```

Using `c3l`:

```bash
c3l fetch https://github.com/vamsi200/linsys.c3l
```

You can get `c3l` from:

https://github.com/konimarti/c3l

# Few Examples

I have added few pollers which I thought would be useful. for example: 

```c
DiskContext ctx;
ctx.init(alloc);
defer ctx.free();

DiskIoPoller poller = disk::poller(alloc, &ctx)!!;

poller.@poll(; DiskIoCounters[] disks) {
    foreach (disk : disks) {
        io::printn(disk);
    }
}!!;
```
use `c3c docgen` for more.

### Process Information

```c
import linsys;
import std::io;

fn int main(String[] args) {
        LibcAllocator alloc;
        ProcessInfo pi = process::info(&alloc, 1) ?? {};
        defer pi.free(&alloc);
        io::printn(pi);
    return 0;
}
```
> Note: Most structers returned using an allocator own memory and provide a free() method. Arrays of these structs follow the same.


Output:

```text
{ process: { pid: 1, ppid: 0, name: systemd, state: SLEEPING }, exe_path: , cmdline: /usr/lib/systemd/systemd --switched-root --system --deserialize=50, uid: 0, gid: 0, threads: 1, vm_size: 23380, vm_rss: 14468 }
```

### Memory Statistics

```c
import linsys;
import std::io;

fn int main(String[] args) {
    @pool() {
        VirtualMemory mem = memory::virtual_memory() ?? {};
        io::printn(mem);
    };
    return 0;
}
```
Output:

```text
{ total: 16060632, available: 8165128, used: 7895504, free: 3811580, percent: 49.160606, active: 6422480, inactive: 2956032, buffers: 308116, cached: 5989504, shared: 1612580, slab: 307080, reclaimable: 148860, swap_cached: 0, dirty: 4216, writeback: 0, mapped: 1177808, page_tables: 53276, committed: 46585116, commit_limit: 16060520 }
```


### Disk Usage

```c
import linsys;
import std::io;

fn int main(String[] args) {
    @pool() {
        DiskUsage usage = disk::usage("/") ?? {};
        io::printn(usage);
    };
    return 0;
}
```

Output:
```text
{ total: 501859205120, used: 448485535744, free: 53373669376, percent: 89.364812 }
```

# API Reference (could change)
Get the api's using:

```bash
c3c docgen
```

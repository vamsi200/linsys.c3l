import std::io;
import proc;
import std::collections::list;

struct NetIoCounters {
    String name;

    ulong bytes_sent;
    ulong bytes_recv;

    ulong packets_sent;
    ulong packets_recv;

    ulong errin;
    ulong errout;

    ulong dropin;
    ulong dropout;
}

struct NetIfStats {
    String name;

    bool is_up;

    int mtu;
    int speed;

    bool duplex_full;

    ulong flags;
}

faultdef IO_ERROR;

fn NetIoCounters[]? net_io_counters(Allocator allocator) {
    @pool() {
        File file = file::open("/proc/net/dev", "r")!;
        defer (void)file.close();

        String content = proc::read_file(tmem, file)!;

        List{NetIoCounters} out;
        out.init(allocator);

        foreach (i, line : content.split(tmem, "\n")) {
            if (i < 2 || line.len == 0) {
                continue;
            }

            String[] split = line.split(tmem, ":");

            if (split.len < 2) {
                continue;
            }

            String iface = split[0].trim();

            String[] fields = split[1].trim().split(tmem, " ");

            if (fields.len < 16) {
                continue;
            }

            out.push(
                {
                    .name = iface.copy(allocator),
                    .bytes_recv = fields[0].to_ulong() ?? 0,
                    .packets_recv = fields[1].to_ulong() ?? 0,
                    .errin = fields[2].to_ulong() ?? 0,
                    .dropin = fields[3].to_ulong() ?? 0,
                    .bytes_sent = fields[8].to_ulong() ?? 0,
                    .packets_sent = fields[9].to_ulong() ?? 0,
                    .errout = fields[10].to_ulong() ?? 0,
                    .dropout = fields[11].to_ulong() ?? 0,
                }
            );
        }

        return out.to_array(allocator);
    };
}


fn Connection[]? net_connections(Allocator allocator) {
    List{Connection} list;
    list.init(allocator);

    read_system_connections(allocator, Protocol.TCP, &list)!;

    read_system_connections(allocator, Protocol.UDP, &list)!;

    return list.to_array(allocator);
}


fn void? read_system_connections(Allocator allocator, Protocol proto, List{Connection}* out) @private {
    @pool() {
        String filename;

        switch (proto) {
            case TCP:
                filename = "/proc/net/tcp";

            case UDP:
                filename = "/proc/net/udp";
        }

        File file = file::open(filename, "r")!;

        defer (void)file.close();

        String content = proc::read_file(tmem, file)!;

        foreach (i, line : content.split(tmem, "\n")) {
            if (i == 0 || line.len == 0) {
                continue;
            }

            String[] fields = line.split(tmem, " ");

            if (fields.len < 4) {
                continue;
            }

            String[] local = fields[1].split(tmem, ":");

            String[] remote = fields[2].split(tmem, ":");

            if (local.len < 2 || remote.len < 2) {
                continue;
            }

            out.push(
                {
                    .local_addr = proc::ip_to_string(allocator, proc::parse_addr(local[0])),
                    .remote_addr = proc::ip_to_string(allocator, proc::parse_addr(remote[0])),
                    .local_port = (ushort)(local[1].to_long(16) ?? 0),
                    .remote_port = (ushort)(remote[1].to_long(16) ?? 0),
                    .state = proc::tcp_state(fields[3]),
                    .protocol = proto,
                }
            );
        }
    };
}

struct IfAddrs {
    IfAddrs* next;
    ZString ifa_name;
    uint ifa_flags;
    void* ifa_addr;
    void* ifa_netmask;
    void* ifa_ifu;
    void* ifa_data;
}

struct SockAddrIn {
    ushort sin_family;
    ushort sin_port;
    uint sin_addr;
    char[8] sin_zero;
}

struct SockAddrIn6 {
    ushort sin6_family;
    ushort sin6_port;
    uint sin6_flowinfo;
    char[16] sin6_addr;
    uint sin6_scope_id;
}

struct NetIfAddr {
    String name;
    String address;
    String netmask;
    bool is_up;
    bool is_loopback;
}

const ushort AF_INET    = 2;
const ushort AF_INET6   = 10;
const uint IFF_UP       = 0x1;
const uint IFF_LOOPBACK = 0x8;

extern fn CInt getifaddrs(IfAddrs** ifap);
extern fn void freeifaddrs(IfAddrs* ifa);

fn String sockaddr_to_string(Allocator allocator, void* sa) @private {
    if (sa == null) return "";
    ushort family = *(ushort*)sa;
    switch (family) {
        case AF_INET:
            SockAddrIn* sin = (SockAddrIn*)sa;
            uint ip = sin.sin_addr;
            return string::format(
                allocator,
                "%d.%d.%d.%d",
                ip & 0xFF,
                (ip >> 8) & 0xFF,
                (ip >> 16) & 0xFF,
                (ip >> 24) & 0xFF
            );
        case AF_INET6:
            SockAddrIn6* sin6 = (SockAddrIn6*)sa;
            return string::format(
                allocator,
                "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
                sin6.sin6_addr[0],
                sin6.sin6_addr[1],
                sin6.sin6_addr[2],
                sin6.sin6_addr[3],
                sin6.sin6_addr[4],
                sin6.sin6_addr[5],
                sin6.sin6_addr[6],
                sin6.sin6_addr[7],
                sin6.sin6_addr[8],
                sin6.sin6_addr[9],
                sin6.sin6_addr[10],
                sin6.sin6_addr[11],
                sin6.sin6_addr[12],
                sin6.sin6_addr[13],
                sin6.sin6_addr[14],
                sin6.sin6_addr[15]
            );
        default:
            return "";
    }
}

fn NetIfAddr[]? net_if_addrs(Allocator allocator) {
    IfAddrs* head = null;
    if (getifaddrs(&head) != 0) return IO_ERROR~;
    defer freeifaddrs(head);

    List{NetIfAddr} list;
    list.init(allocator);

    IfAddrs* cur = head;
    while (cur != null) {
        if (cur.ifa_addr != null) {
            ushort family = *(ushort*)cur.ifa_addr;
            if (family == AF_INET || family == AF_INET6) {
                list.push(
                    {
                        .name = ((String)cur.ifa_name.str_view()).copy(allocator),
                        .address = sockaddr_to_string(allocator, cur.ifa_addr),
                        .netmask = sockaddr_to_string(allocator, cur.ifa_netmask),
                        .is_up = (cur.ifa_flags & IFF_UP) != 0,
                        .is_loopback = (cur.ifa_flags & IFF_LOOPBACK) != 0,
                    }
                );
            }
        }
        cur = cur.next;
    }

    return list.to_array(allocator);
}

fn NetIfStats[]? net_if_stats(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/class/net")!;

        PathList list = io::path::ls(tmem, path)!;

        List{NetIfStats} stats;
        stats.init(allocator);

        foreach (entry : list) {
            String iface = entry.file_tbasename()!;

            NetIfStats st = { .name = iface.copy(allocator), };

            String base = string::tformat("/sys/class/net/%s", iface);

            String oper = string::tformat("%s/operstate", base);

            if (try File f = file::open(oper, "r")) {
                defer (void)f.close();

                String state = proc::read_file(tmem, f)!.trim();

                st.is_up = state == "up";
            }

            String mtu = string::tformat("%s/mtu", base);

            if (try File f = file::open(mtu, "r")) {
                defer (void)f.close();

                st.mtu = proc::read_file(tmem, f)!.trim().to_int() ?? 0;
            }

            String speed = string::tformat("%s/speed", base);

            if (try File f = file::open(speed, "r")) {
                defer (void)f.close();

                st.speed = proc::read_file(tmem, f)!.trim().to_int() ?? 0;
            }

            String flags = string::tformat("%s/flags", base);

            if (try File f = file::open(flags, "r")) {
                defer (void)f.close();

                st.flags = proc::read_file(tmem, f)!.trim().to_ulong(16) ?? 0;
            }

            stats.push(st);
        }

        return stats.to_array(allocator);
    };
}

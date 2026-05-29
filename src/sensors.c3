module sys;
import std::io;
import std::collections::list;

struct SensorTemperature {
    String name;
    double current;
    double critical;
}

struct SensorFan {
    String name;
    int current;
}

struct SensorBattery {
    String name;
    double percent;
    BatteryStatus status;
    ulong energy_now;
    ulong energy_full;
    ulong power_now;
    long secs_left;
}

enum BatteryStatus {
    UNKNOWN,
    CHARGING,
    DISCHARGING,
    FULL,
    NOT_CHARGING,
}

struct SensorPath @private {
    String input;
    String crit;
    String name;
}

fn BatteryStatus battery_status(String s) @private {
    switch (s.trim()) {
        case "Charging":
            return BatteryStatus.CHARGING;

        case "Discharging":
            return BatteryStatus.DISCHARGING;

        case "Full":
            return BatteryStatus.FULL;

        case "Not charging":
            return BatteryStatus.NOT_CHARGING;

        default:
            return BatteryStatus.UNKNOWN;
    }
}

fn ulong? read_ulong_file(String path) @private {
    File file = file::open(path, "r")!;
    defer (void)file.close();

    return read_file(tmem, file)!.trim().to_ulong();
}

fn void? parse_sensor_temperatures(Allocator allocator, SensorPath[] paths, List{SensorTemperature}* out) @private {
    foreach (p : paths) {
        ulong? raw = read_ulong_file(p.input);
        if (catch raw) continue;
        double current  = (double)raw / 1000.0;
        double critical = 0.0;
        ulong? crit_raw = read_ulong_file(p.crit);
        if (try crit_raw) {
            critical = (double)crit_raw / 1000.0;
        }
        out.push({ .name = p.name, .current = current, .critical = critical, });
    }
}

fn SensorPath[]? get_sensor_paths(Allocator allocator) @private {
    @pool() {
        Path path     = path::new(tmem, "/sys/class/hwmon")!;
        PathList list = io::path::ls(tmem, path)!;
        List{SensorPath} paths;
        paths.init(allocator);
        foreach (entry : list) {
            String hwmon     = entry.file_tbasename()!;
            String base      = string::tformat("/sys/class/hwmon/%s", hwmon);
            String name_path = string::tformat("%s/name", base);
            String sensor_name;
            if (try File nf = file::open(name_path, "r")) {
                defer (void)nf.close();
                sensor_name = read_file(tmem, nf)!.trim().copy(allocator);
            } else {
                sensor_name = hwmon.copy(allocator);
            }
            for (int i = 1; i <= 32; i++) {
                String input = string::tformat("%s/temp%d_input", base, i);
                ulong? raw   = read_ulong_file(input);
                if (catch raw) continue;
                paths.push({ .input = input.copy(allocator), .crit = string::tformat("%s/temp%d_crit", base, i)
                    .copy(allocator), .name = string::format(allocator, "%s-temp%d", sensor_name, i), });
            }
        }
        return paths.to_array(allocator);
    };
}

fn SensorTemperature[]? sensor_temperatures(Allocator allocator) {
    @pool() {
        SensorPath[] paths = get_sensor_paths(allocator)!;
        defer {
            foreach (p : paths) {
                mem::alloc::free(allocator, p.input.ptr);
                mem::alloc::free(allocator, p.crit.ptr);
                mem::alloc::free(allocator, p.name.ptr);
            }
            mem::alloc::free(allocator, paths.ptr);
        }
        List{SensorTemperature} out;
        out.init(allocator);
        parse_sensor_temperatures(allocator, paths, &out)!;
        return out.to_array(allocator);
    };
}

struct SensorPoller {
    SensorPath[] paths;
    List{SensorTemperature} list;
    Allocator allocator;
}

fn SensorPoller? sensor_poller_new(Allocator allocator) {
    List{SensorTemperature} list;
    list.init(allocator);
    return { .paths = get_sensor_paths(allocator)!, .list = list, .allocator = allocator, };
}

fn void SensorPoller.close(&self) {
    foreach (p : self.paths) {
        mem::alloc::free(self.allocator, p.input.ptr);
        mem::alloc::free(self.allocator, p.crit.ptr);
        mem::alloc::free(self.allocator, p.name.ptr);
    }
    mem::alloc::free(self.allocator, self.paths.ptr);
    self.list.free();
}

fn SensorTemperature[]? SensorPoller.poll(&self) {
    self.list.clear();
    parse_sensor_temperatures(self.allocator, self.paths, &self.list)!;
    return self.list.array_view();
}

struct FanPath @private {
    String input;
    String name;
}

fn FanPath[]? find_fan_paths(Allocator allocator) @private {
    @pool() {
        Path path     = path::new(tmem, "/sys/class/hwmon")!;
        PathList list = io::path::ls(tmem, path)!;
        List{FanPath} paths;
        paths.init(allocator);
        foreach (entry : list) {
            String hwmon     = entry.file_tbasename()!;
            String base      = string::tformat("/sys/class/hwmon/%s", hwmon);
            String name_path = string::tformat("%s/name", base);
            String sensor_name;
            if (try File nf = file::open(name_path, "r")) {
                defer (void)nf.close();
                sensor_name = read_file(tmem, nf)!.trim().copy(allocator);
            } else {
                sensor_name = hwmon.copy(allocator);
            }
            for (int i = 1; i <= 32; i++) {
                String input = string::tformat("%s/fan%d_input", base, i);
                ulong? raw   = read_ulong_file(input);
                if (catch raw) continue;
                paths.push(
                    { .input = input.copy(allocator), .name = string::format(allocator, "%s-fan%d", sensor_name, i), }
                );
            }
        }
        return paths.to_array(allocator);
    };
}

fn void? parse_sensor_fans(Allocator allocator, FanPath[] paths, List{SensorFan}* out) @private {
    foreach (p : paths) {
        ulong? raw = read_ulong_file(p.input);
        if (catch raw) continue;
        out.push({ .name = p.name, .current = (int)raw, });
    }
}

fn SensorFan[]? sensor_fans(Allocator allocator) {
    @pool() {
        FanPath[] paths = find_fan_paths(allocator)!;
        defer {
            foreach (p : paths) {
                mem::alloc::free(allocator, p.input.ptr);
                mem::alloc::free(allocator, p.name.ptr);
            }
            mem::alloc::free(allocator, paths.ptr);
        }
        List{SensorFan} out;
        out.init(allocator);
        parse_sensor_fans(allocator, paths, &out)!;
        return out.to_array(allocator);
    };
}

struct FanPoller {
    FanPath[] paths;
    List{SensorFan} list;
    Allocator allocator;
}

fn FanPoller? fan_poller_new(Allocator allocator) {
    List{SensorFan} list;
    list.init(allocator, 8);
    return { .paths = find_fan_paths(allocator)!, .list = list, .allocator = allocator, };
}

fn void FanPoller.close(&self) {
    foreach (p : self.paths) {
        mem::alloc::free(self.allocator, p.input.ptr);
        mem::alloc::free(self.allocator, p.name.ptr);
    }
    mem::alloc::free(self.allocator, self.paths.ptr);
    self.list.free();
}

fn SensorFan[]? FanPoller.poll(&self) {
    self.list.clear();
    parse_sensor_fans(self.allocator, self.paths, &self.list)!;
    return self.list.array_view();
}

fn SensorBattery[]? sensor_battery(Allocator allocator) {
    @pool() {
        Path path     = path::new(tmem, "/sys/class/power_supply")!;
        PathList list = io::path::ls(tmem, path)!;
        List{SensorBattery} bats;
        bats.init(allocator);

        foreach (entry : list) {
            String name      = entry.file_tbasename()!;
            String base      = string::tformat("/sys/class/power_supply/%s", name);
            String type_path = string::tformat("%s/type", base);
            File? tf         = file::open(type_path, "r");
            if (catch tf) continue;
            defer (void)tf.close();

            String type = read_file(tmem, tf)!.trim();
            if (type != "Battery") continue;
            SensorBattery bat = { .name = name.copy(allocator) };
            String status     = string::tformat("%s/status", base);

            if (try File sf = file::open(status, "r")) {
                defer (void)sf.close();
                bat.status = battery_status(read_file(tmem, sf)!.trim());
            }

            bat.percent = (double)(read_ulong_file(string::tformat("%s/capacity", base)) ?? 0);
            bat.energy_now = read_ulong_file(string::tformat("%s/energy_now", base)) ?? 0;
            bat.energy_full = read_ulong_file(string::tformat("%s/energy_full", base)) ?? 0;
            bat.power_now = read_ulong_file(string::tformat("%s/power_now", base)) ?? 0;

            if (bat.power_now > 0 && bat.energy_now > 0) {
                bat.secs_left = ((long)((double)bat.energy_now / (double)bat.power_now)) * 3600;
            }
            bats.push(bat);
        }
        return bats.to_array(allocator);
    };
}

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

fn SensorTemperature[]? sensor_temperatures(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/class/hwmon")!;

        PathList list = io::path::ls(tmem, path)!;

        List{SensorTemperature} temps;
        temps.init(allocator);

        foreach (entry : list) {
            String hwmon = entry.file_tbasename()!;

            String base = string::tformat("/sys/class/hwmon/%s", hwmon);

            String name_path = string::tformat("%s/name", base);

            String sensor_name = hwmon.copy(allocator);

            if (try File nf = file::open(name_path, "r")) {
                defer (void)nf.close();

                sensor_name = read_file(tmem, nf)!.trim().copy(allocator);
            }

            for (int i = 1; i <= 32; i++) {
                String input = string::tformat("%s/temp%d_input", base, i);

                if (!os::native_file_or_dir_exists(input)) {
                    continue;
                }

                double current = ((double)(read_ulong_file(input) ?? 0)) / 1000.0;

                double critical = 0.0;

                String crit = string::tformat("%s/temp%d_crit", base, i);

                if (os::native_file_or_dir_exists(crit)) {
                    critical = ((double)(read_ulong_file(crit) ?? 0)) / 1000.0;
                }

                temps.push(
                    {
                        .name = string::format(allocator, "%s-temp%d", sensor_name, i),
                        .current = current,
                        .critical = critical,
                    }
                );
            }
        }

        return temps.to_array(allocator);
    };
}


fn SensorFan[]? sensor_fans(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/class/hwmon")!;

        PathList list = io::path::ls(tmem, path)!;

        List{SensorFan} fans;
        fans.init(allocator);

        foreach (entry : list) {
            String hwmon = entry.file_tbasename()!;

            String base = string::tformat("/sys/class/hwmon/%s", hwmon);

            String name_path = string::tformat("%s/name", base);

            String sensor_name = hwmon.copy(allocator);

            if (try File nf = file::open(name_path, "r")) {
                defer (void)nf.close();

                sensor_name = read_file(tmem, nf)!.trim().copy(allocator);
            }

            for (int i = 1; i <= 32; i++) {
                String input = string::tformat("%s/fan%d_input", base, i);

                if (!os::native_file_or_dir_exists(input)) {
                    continue;
                }

                fans.push(
                    {
                        .name = string::format(allocator, "%s-fan%d", sensor_name, i),
                        .current = (int)(read_ulong_file(input) ?? 0),
                    }
                );
            }
        }

        return fans.to_array(allocator);
    };
}


fn SensorBattery[]? sensor_battery(Allocator allocator) {
    @pool() {
        Path path = path::new(tmem, "/sys/class/power_supply")!;

        PathList list = io::path::ls(tmem, path)!;

        List{SensorBattery} bats;
        bats.init(allocator);

        foreach (entry : list) {
            String name = entry.file_tbasename()!;

            String base = string::tformat("/sys/class/power_supply/%s", name);

            String type_path = string::tformat("%s/type", base);

            File? tf = file::open(type_path, "r");

            if (catch tf) {
                continue;
            }

            defer (void)tf.close();

            String type = read_file(tmem, tf)!.trim();

            if (type != "Battery") {
                continue;
            }

            SensorBattery bat = { .name = name.copy(allocator), };

            String status = string::tformat("%s/status", base);

            if (try File sf = file::open(status, "r")) {
                defer (void)sf.close();

                bat.status = battery_status(read_file(tmem, sf)!.trim());
            }

            String cap = string::tformat("%s/capacity", base);

            if (try File cf = file::open(cap, "r")) {
                defer (void)cf.close();

                bat.percent = read_file(tmem, cf)!.trim().to_double() ?? 0;
            }

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

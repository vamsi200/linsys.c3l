module c3sys;
import std::io;
import proc;
import std::thread;

fn int main(String[] args) {
    // ProcessInfo? pi = proc::get_info(tmem, 1);
    bool exists = proc::exists(123423);
    io::printn(exists);
    return 0;
}

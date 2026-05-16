module c3sys;
import std::io;
import proc;
import std::thread;

fn int main(String[] args) {
        ThreadInfo[] ti = proc::threads(tmem, 3022)!!;
        foreach (t: ti) io::printn(t);
    return 0;
}

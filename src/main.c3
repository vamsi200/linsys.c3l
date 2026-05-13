module c3sys;
import std::io;
import proc;

fn int main(String[] args)
{
  // ProcessInfo p = proc::proc_get_info(tmem, 1)!!;
  // io::printn(p);
  // int[] pid_list = proc::proc_list_pids(tmem)!!;
  // io::printn(pid_list);

  // bool s = proc::proc_exists(1);
  // String s = proc::proc_cwd(1);
  // EnvVar[] evs = proc::proc_environ(tmem, 1)!!;
  // foreach (ev: evs) {
  //   io::printn(ev);
  // }

//   String[] fds = proc::proc_fds(tmem, 1)!!;
// io::printn(fds);

  // ProcStat p = proc::proc_read_stat(tmem, 1)!!;
  // io::printn(p);
	Connection[] connections = proc::proc_connections(tmem, 2723)!!;
	foreach(conn: connections) {
		io::printn(conn);
	}
	return 0;
}

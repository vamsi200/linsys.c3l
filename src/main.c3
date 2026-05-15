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

	// double mem_p = proc::proc_memory_percent(81291)!!;
	// IoCounters ioc = proc::proc_io_counters(81291)!!;
	// bool val = proc::proc_kill(216645);
	// if (val) io::printf("target eliminated boss\n");

	// int[] children = proc::proc_children(tmem, 27189, true)!!;	
	// io::printn(children);
	// int parent = proc::proc_parent(26134)!!;
	// int ng = proc::proc_nice_get(26134)!!;
	// int[] af = proc::proc_cpu_affinity_get(tmem, 26134)!!;
	// RLimitEntry[] rl = proc::proc_rlimits_get(tmem, 24720)!!;
	ThreadInfo[] ti = proc::proc_threads(tmem, 24720)!!;
	foreach (l:ti) {
		io::printn(l);
	}
	return 0;
}

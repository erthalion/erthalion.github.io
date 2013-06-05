---
layout: post
title:  "PostgreSQL at low level: stay curious!"
date:   2019-12-06 13:21:54
comments: true
tags: [PostgreSQL, perf, bpf]
overview: "It's not a secret that databases are damn complicated systems. And
they tend to run on top of even more complicated stacks of software. Nowadays
you will not surprise anyone (or at least not that much) by running your
database on a Kubernetes cluster or inside a virtual machine. It's probably
still questionable whether it's good and appropriate, but this approach is
something we have to face — sometimes it's at least convenient, sometimes it
allows to be more resource efficient and sometimes it's the only available
infrastructure in a company. And one of the problems in this situation is that
reasoning about the performance is not that easy any more. Well, it's not like
it was much easier before, but still. Let's see what can we do about it and how
strace, perf and BPF can change the game."
---

## 0. How to read me?

Yes, I know, it's a long text, and it was my conscious decision to write it in
this way. But fear not! Imagine that you read a book, take a look at the
introduction and first few interesting sections, think about it and then find
time to read further. I hope I've left enough references, so if you don't get
some ideas you'll be able to read more information about interesting parts. Or
you can even skip some sections, since they are relatively independent. This
table of contents will guide you:

<ul style="width:100%">
  <li>
    <a href="#1-introduction">Introduction</a>
  </li>
  <li>
    <a href="#2-shared-memory">Interesting stuff</a>
    <ul>
    <li>
        <a href="#2-shared-memory">Strace</a>
        <ul>
            <li>
                <a href="#2-shared-memory">Shared memory</a>
            </li>
            <li>
                <a href="#3-vdso">vDSO</a>
            </li>
        </ul>
    </li> 
    <li>
        <a href="#4-cpu-migrations">Perf</a>
        <ul>
            <li>
                <a href="#4-cpu-migrations">CPU migrations</a>
            </li>
            <li>
                <a href="#5-mds">MDS</a>
            </li>
            <li>
                <a href="#6-lock-holderwaiter-preemption">Lock holder/waiter preemption</a>
            </li>
            <li>
                <a href="#7-huge-pages">Huge pages</a>
            </li>
        </ul>
    </li>
    <li>
        <a href="#8-bpf">BPF</a>
        <ul>
            <li>
                <a href="#8-bpf">Overview</a>
            </li>
            <li>
                <a href="#9-llc">LLC</a>
            </li>
            <li>
                <a href="#10-writeback">Writeback</a>
            </li>
            <li>
                <a href="#11-memory-reclaim">Memory reclaim</a>
            </li>
            <li>
                <a href="#12-io-scheduler">IO scheduler</a>
            </li>
            <li>
                <a href="#13-butbut-isnt-it-slow">But...but isn't it slow?</a>
            </li>
            <li>
                <a href="#14-im-going-to-use-it-in-production-immediately">I'm going to use it in production immediately!</a>
            </li>
        </ul>
    </li>
    </ul>
  </li>
  <li>
      <a href="#15-conclusions">Conclusions</a>
  </li>
</ul>

## 1. Introduction

> In mathematics it is too easy to concentrate very hard on one specific
> problem. If your methods are not good enough to handle the problem, you will
> eventually grind to a halt, baffled and defeated. Often the key to further
> progress is to stand back, forget about the special problem, and see if you
> can spot any general features of the surrounding area which might be of use.
>
> Ian Stewart, Concepts of Modern Mathematics.

It's not a secret that databases are damn complicated systems. And they tend to
run on top of even more complicated stacks of software. Nowadays you will not
surprise anyone (or at least not that much) by running your database on a
Kubernetes cluster or inside a virtual machine. It's probably still
questionable whether it's good and appropriate, but this approach is
something we have to face — sometimes it's at least convenient, sometimes it
allows to be more resource efficient and sometimes it's the only available
infrastructure in a company.

<!--break-->

<img src="/public/img/layers.png" border="0" width="100%" style="margin: auto">

And one of the problems in this situation is that reasoning about the
performance is not that easy any more. Well, it's not like it was much easier
before, but still. An issue, that could be in a database and sometimes in OS
configuration, now has much more places to hide. At the same time every piece
of software we have in our layers provide different and rather not unified ways
to analyze its performance. In this kind of situations what usually happens if
we've been hit by a strange and transient performance bug, hidden so well in
between? Most of the time people tend to use a "time efficient" solution, like
scaling up or restarting the whole thing, just to make this problem go away.
Not only it usually returns, but people also loosing an important knowledge for
themselves and for a community of whatever software they use.

All of this make me think that quite often it would be very beneficial to stand
back, forget about one particular layer of the system and apply more holistic
approach to the problem. Ironically this holistic approach would mean an
investigation of what's going on a low level, since everything would be
presented there relatively unified and without that much of borders between
different layers. For example, let's remember what happens when a database
specialist is after a slow query? Well, most of the time there is a long stare
at the query plan in attempt to understand how the database will execute it,
and then change of the query, or dataset, or rarely the database parameters.
But no matter how long we will stare at it, in this way it's impossible to
figure out that the query became slower e.g. due to the database, that runs on
a K8S node, got few noisy neighbours scheduled on the same node.

But so far it sounds too fuzzy. What if you want to apply this approach, how
would you do this? Just randomly and without any plan using utilities you've
found on the internet?

> So this is how a performance analysis looks like, people with expensive
tools running around. Not how I pictured it.
>
> Elliot Alderson could have said that

Fortunately no, there is a nice [guideline][methodology] from Brendan Gregg,
that also includes frequent anti-patterns. One of the mentioned methods I find
especially practical is [USE][use_method], that could be summarized as:

> For every resource, check utilization, saturation, and errors.

If you're interested more in computational performance, I can also suggest
[Top-Down performance analysis][top-down]. Taking this into account will help
you to solve a lot of complicated performance issues.

Having said all of that, now I want to show few examples for situations that I
find interesting or useful, when one can use tools from the outside of the
Postgres itself to figure out what's going on.

## 2. Shared memory

What if you want to execute some analytical query against your relatively fresh
Postgres installation, and suddenly see this:

```
ERROR:  could not resize shared memory segment
"/PostgreSQL.699663942" to 50438144 bytes:
    No space left on device
```

Seems pretty strange, and it's actually not that easy to get more insight from
the logs. But if you're curious enough, spin up `strace`, attach it to your
Postgres backend, and see what system calls your database is doing. There is
even not that well known option [-k][strace-k], that allow us to see the
stack trace between each syscall! There is an [information][franck-pachot]
that this options is not available everywhere, so maybe you need to compile
`strace` yourself for that, but I would even advise you to do so, since it's
relatively trivial and allow you to transform it more for your needs (e.g.
statically compiled `strace` can be pretty useful). Anyway, what can we see
using this tool?

```
# strace -k -p PID
openat(AT_FDCWD, "/dev/shm/PostgreSQL.62223175"
ftruncate(176, 50438144)                = 0
fallocate(176, 0, 0, 50438144)          = -1 ENOSPC
 > libc-2.27.so(posix_fallocate+0x16) [0x114f76]
 > postgres(dsm_create+0x67) [0x377067]
   ...
 > postgres(ExecInitParallelPlan+0x360) [0x254a80]
 > postgres(ExecGather+0x495) [0x269115]
 > postgres(standard_ExecutorRun+0xfd) [0x25099d]
   ...
 > postgres(exec_simple_query+0x19f) [0x39afdf]
```

Now things are getting clear. We know that starting from PostgreSQL 10 query
parallelism was improved significantly, and it seems like out backend indeed
was doing something with parallel workers here. Each parallel worker require
some amount of dynamic shared memory, which in case of POSIX implementation
allocates something under `/dev/shm`. And now we do something, what software
engineers usually don't do — read the documentation, from which we learn that
default value for `/dev/shm` size in Docker is [64Mb][docker-default-shm-size].
Sometimes it could be not enough, and we're in troubles.

## 3. vDSO

One can say that the previous example is a cheat, since obviously it's rather
complicated to analyze an issue in some software from the software itself, so
here is another one. There is a nice Linux kernel mechanism called vDSO
(virtual dynamic shared object). It allows us to call some kernel space
routines in-process, without incurring the performance penalty of a mode switch
from user to kernel mode. Some of those routines are quite important for
databases, e.g. `gettimeofday`. But unfortunately this mechanism is not always
available on VMs, it depends on a hypervisor (see more details in this nice
[blogpost][system-calls-aws]). And now imagine you have a situation, when your
K8S cluster consists of mixture of nodes from different AWS generations, how to
figure out on which of them your databases are doing extra work? Attach
`strace`, and see if there are any real system calls done:

```
# strace -k -p PID on XEN
gettimeofday({tv_sec=1550586520, tv_usec=313499}, NULL) = 0
```

## 4. CPU migrations

Here I have few naive experiments with pgbench on my laptop. Not exactly
reliable benchmarking setup, but good enough to show some interesting stuff.
The first experiment was running some heavy stuff, sorting a lot of data. In
the second experiment I've utilized cool pgbench option
[--file=filename[@weight]][pgbench-weight] to use different scripts in
specified proportions, and the second script was doing something short, just
select one record by index:

```
# Experiment 1
SQL script: pg_long.sql
- latency average = 1312.903 ms

# Experiment 2
SQL script 1: pg_long.sql
- weight: 1 (targets 50.0% of total)
- latency average = 1426.928 ms

SQL script 2: pg_short.sql
- weight: 1 (targets 50.0% of total)
- latency average = 303.092 ms
```

I was a bit confused, when I saw the results. Why when we replace half of the
heavy workload with something more lightweight, it's getting worse? It's one of
those situations, when no matter how silly is the combination of parameters,
it's always interesting to check why. Most likely our bottleneck is not some
syscall, so `strace` will not help and probably we need to deploy `perf` to
record hardware performance events:

```
# perf record -e cache-misses,cpu-migrations

# Experiment 1
12,396,382,649      cache-misses # 28.562%
%2,750              cpu-migrations

# Experiment 2
20,665,817,234      cache-misses # 28.533%
10,460              cpu-migrations
```

Now we see something interesting. My original idea that it has something to do
with cache misses is wrong, in both cases this metrics is almost the same. But
`cpu-migrations` is three times bigger for the second experiment, due to
different type of workload introducing disbalance in CPU consumption and not
big enough value for [sched_migration_cost_ns][sched_migration_cost] make
kernel think that it makes sense to migrate backends between CPUs. Most likely
that's the reason for our higher latency.

## 5. MDS

I know, everyone tired of hardware vulnerabilities. But they are good
opportunity to practice your profiling skills, so I just can't resist to write
this section. MDS (Microarchitectural Data Sampling) is another of those issues
similar to Meltdown and Spectre. Every such public vulnerability has an extra
mitigation mechanism in the Linux kernel and it means an overhead of some kind.
Actually, there is a nice [overview][andres-mds] of what does it mean for
Postgres, but let's imagine for a minute that we live in a fantasy world where
there is no Andres Freund. How would you evaluate an influence of this
mitigation for your database? Well, let's start to profile:

```
# Children      Self  Symbol                                        
# ........  ........  ...................................
    71.06%     0.00%  [.] __libc_start_main
    71.06%     0.00%  [.] PostmasterMain
    56.82%     0.14%  [.] exec_simple_query
    25.19%     0.06%  [k] entry_SYSCALL_64_after_hwframe
    25.14%     0.29%  [k] do_syscall_64
    23.60%     0.14%  [.] standard_ExecutorRun
```

If we would compare this profile, taken from a system with mitigation in place,
with another one without it, we will notice that `do_syscall_64` is suddenly
quite at the top. What does it mean? No idea, let's zoom in:

```
# Percent     Disassembly of kcore for cycles
# ........    ................................
    0.01% :   nopl   0x0(%rax,%rax,1)
   28.94% :   verw   0xffe9e1(%rip)
    0.55% :   pop    %rbx
    3.24% :   pop    %rbp
```

Oh, here we are. We know via our strange habit of reading the documentation,
that the mitigation [mechanism for MDS][kernel-verw] implies overloading `verw`
instruction to flush CPU buffers, which kernel does via
`mds_clear_cpu_buffers()`. And exactly that we can see in our profile! But
please be aware of [skid][skid], since sometimes collected samples could be
corresponding to the wrong instruction.

## 6. Lock holder/waiter preemption

Have you heard about such thing? It turns out it's quite a problem, even worth
few white papers, e.g. from [Usenix][lock-problems-usenix] or
[WAMOS][lock-problems-wamos]. Let's try to understand where is this issue
coming from. Imagine we have a Postgres running inside a VM and taking two
vCPU (vC1, vC2):

<img src="/public/img/lock_holder_start.png" border="0" width="70%" style="margin: auto">

In this scenario at some point the backend on vC2 is waiting on a spin lock for
something owned by another backend on vC1. Normally it's not a problem, but what
happens if hypervisor will suddenly decide to preempt vC1?

<img src="/public/img/lock_holder_end.png" border="0" width="70%" style="margin: auto">

Now we're in troubles, because what supposed to be a short waiting time for the
first backend now takes who knows how long. Fortunately for us there are such
technologies as Intel [PAUSE-Loop Exiting][intel-ple] that are able to prevent
useless spinning via sending `VM exit` to a corresponding VM. Or not
fortunately, since of course it introduces an overhead of switching between VM
and hypervisor, and if a pause was triggered incorrectly then this overhead was
for nothing.

And now the question, how to measure it? Well, probably we can take a look at
what kind of VM related tracepoints `perf` can offer to us. For KVM there is
actually a `kvm:kvm_exit` event, which also contains a reason code for an exit.
Let's try to run Postgres inside a KVM (with number of vCPU more that real
cores) and see:

```
# experiment 1: pgbench, read write
# latency average = 17.782 ms

$ modprobe kvm-intel ple_gap=128
$ perf record -e kvm:kvm_exit

# reason PAUSE_INSTRUCTION 306795
```

```
# experiment 2: pgbench, read write
# latency average = 16.858 ms

$ modprobe kvm-intel ple_gap=0
$ perf record -e kvm:kvm_exit

# reason PAUSE_INSTRUCTION 0
```

In the first experiment we keep the default configuration for PLE and see that
we've recorded quite a number of pause instructions. In the second experiment
we disable PLE completely, and not surprisingly got 0 pause instructions. And
you know what? In the second experiment our average latency was visibly lower!
Most likely it means that our CPUs were too much oversubscribed, and PLE was
falsely identifying real waiting for useless and pausing them.

## 7. Huge pages

Somehow it happened that in databases world people not always understand what
huge pages are and when they are useful. Let's apply our secret weapon to fight
this off. First, do not mix up classical huge pages with transparent huge
pages. The last one is a daemon that tries to merge regular memory pages into a
huge pages in background and usually it's advised to disable it due to
unpredictable resource consumption. Now let's check the
[documentation][huge-pages-docs]:

> Usage of huge pages significantly reduces pressure on TLB, improves TLB
> hit-rate and thus improves overall system performance.

Interesting, but how can we check what does it mean for our databases? No
surprise, there are TLB related tracepoints we can record via `perf`:

```
# Experiment 1, pgbench read/write, huge_pages off
# perf record -e dTLB-loads,dTLB-stores -p PID

Samples: 894K of event 'dTLB-load-misses'
Event count (approx.): 784439650
Samples: 822K of event 'dTLB-store-misses'
Event count (approx.): 101471557

# Experiment 2, pgbench read/write, huge_pages on
# perf record -e dTLB-loads,dTLB-stores -p PID

Samples: 832K of event 'dTLB-load-misses'
Event count (approx.): 640614445
Samples: 736K of event 'dTLB-store-misses'
Event count (approx.): 72447300
```

Again, two experiments with pgbench TPC-B workload, the first one was done
without huge pages, the second one with `huge_pages=on`. Indeed, in the second
case we have about 20% less TLD load misses, which correlates good with what we
have read in the documentation. No latencies here, just to make a point that we
measure just one particular thing, not the whole system, when we can get some
noise from other components.

## 8. BPF

Oh, this famous Buddhist Peace Fellowship! Or was it Berkeley Packet Filter
Compiler Collection? What about classic British Pacific Fleet? Sounds like an
extended Badminton Players Federation. No idea, decide for
[yourself][cilium-cbpf]. The point is that BPF is conquering the world!

On the serious note, I think it's important to talk about BPF in this blog
post, since it changes rules of our game a bit. What we had before could be
described as "stateless tracing/profing". We've got some event, processed it
and went for the next one, no state in between. And BPF allows us to do an
efficient "statefull tracing/profiling", which is honestly just mind-blowing.

<img src="/public/img/bpf.png" border="0" width="70%" style="margin: auto">

It's a bit cumbersome to write plain BPF bytecode, but fortunately there are
better ways to do it. Yes, I'm talking about [BCC][bcc], which is not only an
amazing tool to generate BPF programs, but also a set of already existing
useful scripts. While [working with it][bcc-pr] I've got an idea to extend this
set by something more Postgres specific and ended up creating an experimental
[postgres-bcc][postgres-bcc]. So what can we do with that?

## 9. LLC

You can be surprised how important could be last level cache sometimes. But
before I was thinking about measuring LLC numbers only globally, e.g. per node.
And it was totally mind-blowing for me to realize, that it's possible to
extract LLC numbers and connect them with a backend information. In simplest
situations it can give us something like cache misses per query:

```
# llcache_per_query.py bin/postgres

PID  QUERY                      CPU REFERENCE MISS   HIT%
9720 UPDATE pgbench_tellers ... 0        2000 1000 50.00%
9720 SELECT abalance FROM   ... 2        2000  100 95.00%
...

Total References: 3303100 Total Misses: 599100 Hit Rate: 81.86%
```

## 10. Writeback

Since Postgres is doing buffered IO, it's quite important to understand
writeback behaviour under your database. Imagine a situation, when your IO
monitoring went crazy without any activity from the Postgres side. At this
point we already know, that most likely there are some tracepoints for us.

As an important side note, I need to mention that you actually don't need to
have `perf` to explore all those tracepoints. There is such an amazing tool as
[ftrace][ftrace] that allow us to do a lot without installing anything at all.
To try it out mount `tracefs` (usually it's already mounted on
`/sys/kernel/debug/tracing`), pick up an event from `events` directory and
enable it.

```
# cd /sys/kernel/debug/tracing
# echo 1 > events/writeback/writeback_written/enable
# tail trace

kworker/u8:1 reason=periodic   nr_pages=101429
kworker/u8:1 reason=background nr_pages=MAX_ULONG
kworker/u8:3 reason=periodic   nr_pages=101457
```

What you see above is a shortened version of the output. `MAX_ULONG` is a short
replacement for maximum unsigned long.

<img src="/public/img/max_ulong.png" border="0" width="70%" style="margin: auto">

We can see that indeed, Linux kernel starts doing writeback in background
trying to flush as much as possible from the filesystem cache. But of course
it's not the whole story, sometimes kernel will make backends
[wait][schedule_io_timeout] if it's not keeping up with the amount of generated
dirty pages. This information we can extract via another script from
`postgres-bcc`:

```
# pgbench insert workload
# io_timeouts.py bin/postgres

[18335] END: MAX_SCHEDULE_TIMEOUT
[18333] END: MAX_SCHEDULE_TIMEOUT
[18331] END: MAX_SCHEDULE_TIMEOUT
[18318] truncate pgbench_history: MAX_SCHEDULE_TIMEOUT
```

It's worth noting that one can control writeback behaviour via different
[parameters][dirty-controls], like `dirty_background_bytes`. Another
[possibility][bgwriter-checkpointer-flush] would be to configure `bgwriter` or
`checkpointer` via `bgwriter_flush_after` / `checkpointer_flush_after`.

## 11. Memory reclaim

This part requires some context. If you ever faced with Kubernetes, you
probably have seen this black magic incantations:

```yaml
resources:
  requests:
    memory: "64Mi"
    cpu: "250m"
  limits:
    memory: "128Mi"
    cpu: "500m"
```

In this way one can specify an amount of resources an application needs. And
now remember that Kubernetes utilize cgroups v1 and we have there:

```
memory.limit_in_bytes
memory.soft_limit_in_bytes
```

What would be the first reaction looking at those two examples? Right, they're
not correlated. Well, only partially, since resources memory limit is indeed
mapped to `memory.limit_in_bytes`. But memory request is actually used only
internally e.g. to calculate `oom_adj` and QoS.

When I discovered this, my idea was that it means there would be no memory
reclaim problems, since when an application inside a cgroup goes over a soft
memory limit, it starts to reclaim pages. How to prove or disprove this idea?
Try it out!

```
# only under the memory pressure
# page_reclaim.py --container 89c33bb3133f

[7382] postgres: 928K
[7138] postgres: 152K
[7136] postgres: 180K
[7468] postgres: 72M
[7464] postgres: 57M
[5451] postgres: 1M
```

Of course there are a lot of memory reclaims anyway if we come close enough to
the memory limit. And indeed we've seen such examples when a database inside a
K8S pod due to misconfiguration was doing page reclaims too often incurring
more overhead. Things are getting more interesting, when we remember that
Postgres is using shared memory to keep the data available between different
backends. The way how shared memory is implemented is via COW (copy on write)
mechanism, and essentially every shared memory page can be duplicated and
accounted against cgroup limits. This whole situation introduce more chaos,
since Postgres and Linux kernel use and evict those pages using different
strategy, so it makes sense to at least check this stuff out from time to time.

By the way, it's not that straightforward even to run `BCC` on Kubernetes,
since most of the time you need to specify an exact Linux kernel version via
`BCC_LINUX_VERSION_CODE` (e.g. for the kernels 4.14.96 it should be in the
format `4 * 65536 + 14 * 256 + 96`) and Linux headers via `BCC_KERNEL_SOURCE`
(which you probably need to fake via symlink, in case if headers available in
your pod are not matching to the kernel version of the node). Another catch
could be if you run on a relatively old kernel versions, since before `v4.18`
overlayfs does not [support uprobes][overlayfs-uprobes]

## 12. IO scheduler

Some time ago it was a common wisdom, that on modern storage devices one need
no IO scheduler. Is it still true? Why do I have then so many options here?

```
# cat /sys/block/nvme0n1/queue/scheduler
[mq-deadline] kyber bfq none
```

Well, the situation is more interesting that I thought originally. Here is a
diagram, inspired by [Werner Fischer][blk-mq] of something called `blk-mq`
(Multi-Queue Block IO Queueing Mechanism), which allow us to utilize multi
queue storage devices more efficiently:

<img src="/public/img/sched.png" border="0" width="100%" style="margin: auto">

Such IO schedulers as `none`, `kyber`, `mq-deadline` are actually implemented
via this mechanism and not for nothing. For example [kyber][kyber] will try to
throttle IO requests by reducing software queues depth in order to meet some
predefined target latency. This could be cool e.g. for those cases when there
are no mechanisms of IO isolation (hello K8S), and some too greedy applications
can skew latencies a lot. But this is just a theory, is there any way to get
some practical and measurable knowledge from it? Let's create a BPF program
that will be executed when a new request is inserted into a software queue and
completed. Then at the completion event we can check if a completed request was
not issued from a cgroup of our interest and there are other requests in the
same queue from our cgroup - in this situation we can consider this just
completed request a noise for our application, a latency that some other
application requests had to wait before they can be successfully executed.

```
# blk_mq.py --container 89c33bb3133f

 latency (us)   : count  distribution
    16 -> 31    : 0     |                                        |
    32 -> 63    : 19    |***                                     |
    64 -> 127   : 27    |****                                    |
   128 -> 255   : 6     |*                                       |
   256 -> 511   : 8     |*                                       |
   512 -> 1023  : 17    |***                                     |
  1024 -> 2047  : 40    |*******                                 |
  2048 -> 4095  : 126   |**********************                  |
  4096 -> 8191  : 144   |*************************               |
  8192 -> 16383 : 222   |****************************************|
 16384 -> 32767 : 120   |*********************                   |
 32768 -> 65535 : 44    |*******                                 |
```

The example above is pretty artificial, because it was measured only on one
software queue (I had to enable `blk-mq` via adding `scsi_mod.use_blk_mq=1`
into the Linux boot cmdline), but nevertheless interesting.

## 13. But...but isn't it slow?

All this `BCC` stuff is pretty amazing and convenient, but requires to execute
some python and compile some generated C code into BPF program via LLVM
backend. Sometimes it's fine, but sometimes an object of your investigation is
so overloaded it's impossible even start python interpreter there. There are
some interesting initiatives to overcome this issue, e.g. [CORE][bpf-core], but
as an interesting experiment I've decided to do something similar without
having `BCC` in place. What do we need to reproduce the same functionality and
write a small BPF program to measure latency of a query execution?

Well we need to create an uprobe for whatever event we want to attach to. Sounds
straightforward:

```
# perf probe -x bin/postgres exec_simple_query
# perf probe -x bin/postgres exec_simple_query%return

# cat /sys/kernel/debug/tracing/uprobe_events

p:probe_postgres/exec_simple_query /bin/postgres:0x000000000044aa7c
r:probe_postgres/exec_simple_query__return /bin/postgres:0x000000000044aa7c
```

Next step is to write our BPF program in C. For that one can draw some
inspiration in `linux/samples/bpf/` that contains interesting examples and how
to compile them, taking into account you have LLVM and kernel headers
installed (`make headers_install`). In this program we will define a BPF map:

```c
struct bpf_map_def SEC("maps") latencies = {
	.type = BPF_MAP_TYPE_HASH,
	.key_size = sizeof(u32),
	.value_size = sizeof(u64),
	.max_entries = MAX_ENTRIES,
};
```

and one function for each uprobe:

```c
SEC("tracepoint/probe_postgres/exec_simple_query")
int trace_enter_open(struct syscalls_enter_open_args *ctx)
{
	u32 key = bpf_get_current_pid_tgid();
	u64 init_val = bpf_ktime_get_ns();
	bpf_map_update_elem(&latencies, &key, &init_val, BPF_ANY);

	return 0;
}

SEC("tracepoint/probe_postgres/exec_simple_query__return")
int trace_enter_exit(struct syscalls_enter_open_args *ctx)
{
	u32 key = bpf_get_current_pid_tgid();
	u64 *value = bpf_map_lookup_elem(&latencies, &key);
	if (value)
		*value = bpf_ktime_get_ns() - *value;

	return 0;
}
```

There was only one catch, somehow it wasn't working for me for tracepoints, I
had to tell that my BPF program is of `BPF_PROG_TYPE_KPROBE` type. If you know
why it could be, let me know too :)

The last step would be to actually run and inspect our compiled stuff. To make
it more convenient, we can pin our BPF map, so that we can read it from another
process:

```
# mount -t bpf none /sys/fs/bpf
# mkdir -p /sys/fs/bpf/maps/
# pg_latencies
...
```

And now when it was started successfully, let's inspect it! For that we can use
an amazing tool called [bpftool][bpftool]. Here is our BPF program loaded:

```
# bpftool prog list
42: kprobe  tag 9ce97a0a428052f3  gpl
        loaded_at 2019-11-22T17:39:51+0100  uid 0
        xlated 224B  not jited  memlock 4096B  map_ids 54
```

And here is our pinned BPF map:

```
# bpftool map list
54: hash  name latencies  flags 0x0
        key 4B  value 8B  max_entries 1000  memlock 81920B
```

But we still have to do something about Linux kernel versions, since we've
compiled it only for one particular. In fact at this moment our BPF program has
something like:

```c
// in hex format value of this section is "2c130400"
// which can be decoded as 8-bit unsigned integer
// 44 19 4 0 (the version was 4 19 44)
u32 _version SEC("version") = 267052;
```

At this point I've got tired and just replaced the corresponding section in the
binary with `xxd`:

```bash
# new version
FORMAT="{0:02x}{1:02x}{2:02x}{3:02x}"
VERSION_HEX=$(python -c 'print(r"'$FORMAT'".format(46, 19, 4, 0))')

# original version
ORIG_HEX="2c130400"

xxd -p pg_latency_kern.o |\
    sed 's/'$ORIG_HEX'/'$VERSION_HEX'/' |\
    xxd -p -r > pg_latency_kern_new.o
```

And looks like this even works!

## 14. I'm going to use it in production immediately!

Great, but please do this carefully. With a great power comes great
responsibility, and before you'll jump into it, there are few concerns you need
to be aware.

The first one is how much overhead would it mean for your system? E.g. `strace`
is a great tool, but due to how it is implemented it can be [quite
slow][strace-overhead]. `perf` normally is faster, but be careful with the disk
space consumption, since in some cases (let's say if you want to trace some
scheduler events) it can easily generate gigabytes of data in seconds. BPF by
itself is also [pretty fast][bpf-at-facebook], but of course if a custom BPF
program is doing something too computation expensive, it will slow down your
target. As an example, `lwlock.py` script from `postgres-bcc`, that tracks
Postgres LWLocks, under a heavy lock contended workload could slow down my
experimental database to about 30%.

The second concern are potential bugs in a tracing tool itself. It's not what
we see so often to worry too much about it, but from time to time it could
happen. I had already such an experience, when due to some strange location of
stars on the night sky an old version of `perf` crashed Postgres backend it was
attached to, or stuck waiting on `uprobe_events` in a non interruptible mode
without any chances to stop or kill it. BPF in this sense it a bit more safe,
since the verifier will reject any incorrect BPF programs. So before trying
this on production, make sure you're using a reasonably new version and first
experiment on staging (do I even need to say that?).

## 15. Conclusions

That was the last example I have for today. I hope it was enough to make you at
least a bit interested in tracing and profiling your databases, and look deeper
into what happens inside and outside. Don't get me wrong, it's not like when
you run `perf` or something BPF based any issues will disappear automagically,
but you will definitely get more interesting information in your hands.

The magic of the more holistic approach is that it's useful not only in
situations, when your database is wrapped in multiple layers. When you profile
a database, most of the time you can trace down precisely what activity or even
function have caused this or that problem. E.g. when Postgres is doing
unexpectedly too much of IO, one can see in profiles let's say a lot of full
page writes happening at this moment. Looking at this from higher perspective I
find it good having a habit to spin up `perf` from time to time. Not only it
gives you a deeper insight of what happens in your system, but also makes
benchmarking more transparent. You need to understand an influence of huge
pages on your database? No need to read outdated blog posts, just go and
measure it! Why is it important to make benchmarking more transparent? One of
the reasons is presented here:

<iframe src="//www.slideshare.net/slideshow/embed_code/key/zk910sGUHqKQ6b?startSlide=36" width="595" height="485" frameborder="0" marginwidth="0" marginheight="0" scrolling="no" style="border:1px solid #CCC; border-width:1px; margin-bottom:5px; max-width: 100%;" allowfullscreen> </iframe> <div style="margin-bottom:5px"> <strong> <a href="//www.slideshare.net/brendangregg/lisa2019-linux-systems-performance" title="LISA2019 Linux Systems Performance" target="_blank">LISA2019 Linux Systems Performance</a> </strong> from <strong><a href="//www.slideshare.net/brendangregg" target="_blank">Brendan Gregg</a></strong> </div>

One can reasonably notice that 90% of time, when a database does not deliver
expected performance, it's due to an inefficiently written query or badly
designed schema, and this kind of problems we can easily troubleshoot from
within Postgres itself without involving any other tools. And this is perfectly
correct, but no one said that those two approaches could not work hand by hand.
At the end of the day I'm advocating just for an extension of our arsenal, so
that when one technique doesn't help, other will solve a mystery.

And actually I didn't mention the last reason why one may want to try out this
approach - it's just a lot of fun! When was the last time you had fun hacking
something?

## Acknowlegements

Thanks a lot to
Peter Eisentraut (<a href="https://twitter.com/petereisentraut">@petereisentraut</a>),
Lorenzo Fontana (<a href="https://twitter.com/fntlnz">@fntlnz</a>)
and Franck Pachot (<a href="https://twitter.com/FranckPachot">@FranckPachot</a>)
for helping me with proof reading of this text and suggesting various
improvements, you rock!

[methodology]: http://www.brendangregg.com/methodology.html
[use_method]: http://www.brendangregg.com/usemethod.html
[top-down]: https://easyperf.net/blog/2019/02/09/Top-Down-performance-analysis-methodology
[strace-k]: https://github.com/strace/strace/blob/master/strace.c#L265
[franck-pachot]: https://medium.com/@FranckPachot/strace-k-build-with-libunwind-f949d4802322
[docker-default-shm-size]: https://github.com/moby/moby/blob/master/daemon/config/config.go#L42
[system-calls-aws]: https://blog.packagecloud.io/eng/2017/03/08/system-calls-are-much-slower-on-ec2/
[pgbench-weight]: https://www.postgresql.org/docs/12/pgbench.html#PGBENCH-RUN-OPTIONS
[sched_migration_cost]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/kernel/sched/fair.c#n87
[andres-mds]: https://www.postgresql.org/message-id/flat/20190514223052.2iufhkjmgod2h7ic%40alap3.anarazel.de
[kernel-verw]: https://www.kernel.org/doc/html/latest/x86/mds.html#mitigation-strategy
[skid]: https://easyperf.net/blog/2018/08/29/Understanding-performance-events-skid
[lock-problems-usenix]: https://www.usenix.org/system/files/conference/atc14/atc14-paper-ding.pdf 
[lock-problems-wamos]: https://www.cs.hs-rm.de/~kaiser/events/wamos2017/wamos17-proceedings.pdf#page=27
[intel-ple]: https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-3c-part-3-manual.pdf#page=37
[huge-pages-docs]: https://www.kernel.org/doc/html/latest/admin-guide/mm/concepts.html#huge-pages
[cilium-cbpf]: https://cilium.readthedocs.io/en/latest/bpf/
[bcc]: https://github.com/iovisor/bcc/
[bcc-pr]: https://github.com/iovisor/bcc/pull/1940
[postgres-bcc]: https://github.com/erthalion/postgres-bcc
[schedule_io_timeout]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/mm/page-writeback.c#n1782
[linux-cow]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/mm/memory.c#n3500
[blk-mq]: https://www.thomas-krenn.com/en/wiki/Linux_Storage_Stack_Diagram
[kyber]: https://www.kernel.org/doc/Documentation/block/kyber-iosched.rst
[bpf-core]: http://vger.kernel.org/bpfconf2019_talks/bpf-core.pdf#page=2
[overlayfs-uprobes]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=f0a2aa5a2a406d0a57aa9b320ffaa5538672b6c5
[bpftool]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/bpf/bpftool
[ftrace]: https://www.kernel.org/doc/Documentation/trace/ftrace.txt
[dirty-controls]: https://www.kernel.org/doc/Documentation/admin-guide/sysctl/vm.rst
[bgwriter-checkpointer-flush]: https://www.postgresql.org/message-id/20190618164849.l6b6o4kc4kguzquo%40alap3.anarazel.de
[bpf-at-facebook]: https://www.slideshare.net/ennael/kernel-recipes-2019-bpf-at-facebook#11
[strace-overhead]: http://www.brendangregg.com/blog/2014-05-11/strace-wow-much-syscall.html

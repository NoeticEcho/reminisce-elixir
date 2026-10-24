# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.NetworkTraceTest do
  # The allowlist that network_test.exs applies to the release's system calls,
  # on lines in strace's own format: what it lets through and what it catches.
  # Runs everywhere, without strace or TypeDB.
  use ExUnit.Case, async: true

  alias Reminisce.NetworkTrace

  @ip "172.18.0.2"
  @port 8000

  # The calls a run of the release makes on Linux, from a real trace.
  @server """
  8102  socketpair(AF_UNIX, SOCK_STREAM, 0, [16, 17]) = 0
  8135  socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP) = 17
  8135  bind(17, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("0.0.0.0")}, 16) = 0
  8135  getsockname(17, {sa_family=AF_INET, sin_port=htons(38531), sin_addr=inet_addr("0.0.0.0")}, [112 => 16]) = 0
  8135  sendmsg(16, {msg_name=NULL, msg_namelen=0, msg_iov=[{iov_base="\\0\\0", iov_len=2}], msg_iovlen=1, msg_controllen=32, msg_flags=0}, 0) = 32
  8135  socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 18
  8135  setsockopt(18, SOL_TCP, TCP_NODELAY, [1], 4) = 0
  8135  connect(18, {sa_family=AF_INET, sin_port=htons(8000), sin_addr=inet_addr("172.18.0.2")}, 16 <unfinished ...>
  8134  recvmsg(3, {msg_name=NULL, msg_namelen=0, msg_iov=[{iov_base="", iov_len=32}], msg_iovlen=1, msg_controllen=0, msg_flags=0}, MSG_DONTWAIT) = 0
  8135  <... connect resumed>) = -1 EINPROGRESS (Operation now in progress)
  8135  sendto(18, "POST /v1/signin HTTP/1.1\\r\\n"..., 245, 0, NULL, 0) = 245
  8135  recvfrom(18, "HTTP/1.1 200 OK\\r\\ncontent-type: a"..., 3939840, 0, NULL, NULL) = 411
  8135  --- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED, si_pid=7598, si_uid=0, si_status=0} ---
  8135  +++ exited with 0 +++
  """

  test "the release's own calls pass, and include the connection to TypeDB" do
    assert NetworkTrace.stray(@server, @ip, @port) == []
    assert NetworkTrace.connects?(@server, @ip, @port)
    refute NetworkTrace.connects?(@server, @ip, 8001)
    refute NetworkTrace.connects?(@server, "172.18.0.3", @port)
  end

  for {name, line} <- [
        "a UDP datagram to a DNS server":
          ~S|9  sendto(17, "\\x12\\x34\\x01\\x00", 30, 0, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("8.8.8.8")}, 16) = 30|,
        "a UDP datagram to TypeDB's address on another port":
          ~S|9  sendto(17, "x", 1, 0, {sa_family=AF_INET, sin_port=htons(9999), sin_addr=inet_addr("172.18.0.2")}, 16) = 1|,
        "a sendmsg that names an address":
          ~S|9  sendmsg(17, {msg_name={sa_family=AF_INET, sin_port=htons(5353), sin_addr=inet_addr("224.0.0.251")}, msg_namelen=16, msg_iov=[], msg_iovlen=0, msg_controllen=0, msg_flags=0}, 0) = 0|,
        "a sendmmsg that names an address":
          ~S|9  sendmmsg(17, [{msg_hdr={msg_name={sa_family=AF_INET6, sin6_port=htons(53), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "2001:4860:4860::8888", &sin6_addr), sin6_scope_id=0}, msg_namelen=28}, msg_len=30}], 1, 0) = 1|,
        "a UDP socket connected to a resolver":
          ~S|9  connect(17, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0|,
        "a connection to TypeDB's port on another address":
          ~S|9  connect(18, {sa_family=AF_INET, sin_port=htons(8000), sin_addr=inet_addr("10.0.0.1")}, 16) = 0|,
        "nscd, through its socket, where it runs":
          ~S|9  connect(3, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = 0|,
        "a connect to nscd that strace split, whatever it returned":
          ~S|9  connect(3, {sa_family=AF_UNIX, sun_path="/run/nscd/socket"}, 110 <unfinished ...>|,
        "another AF_UNIX socket, even refused":
          ~S|9  connect(3, {sa_family=AF_UNIX, sun_path="/run/systemd/resolve/io.systemd.Resolve"}, 110) = -1 ENOENT (No such file or directory)|,
        "a bind to the port mapper's port":
          ~S|9  bind(3, {sa_family=AF_INET, sin_port=htons(4369), sin_addr=inet_addr("0.0.0.0")}, 16) = 0|,
        "a bind to port 0 on a real address":
          ~S|9  bind(3, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("192.168.1.5")}, 16) = 0|,
        "a bind to an IPv6 port":
          ~S|9  bind(3, {sa_family=AF_INET6, sin6_port=htons(4369), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "::", &sin6_addr), sin6_scope_id=0}, 28) = 0|,
        "a listen": ~S|9  listen(3, 5) = 0|,
        "an accept": ~S|9  accept4(3, NULL, NULL, SOCK_CLOEXEC) = -1 EAGAIN|,
        "a raw socket": ~S|9  socket(AF_INET, SOCK_RAW, IPPROTO_ICMP) = 5|,
        "a packet socket": ~S|9  socket(AF_PACKET, SOCK_DGRAM, 768) = 5|,
        "a datagram received from elsewhere":
          ~S|9  recvfrom(17, "x", 1500, 0, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("8.8.8.8")}, [16]) = 1|
      ] do
    test "catches #{name}" do
      line = unquote(line)
      assert NetworkTrace.stray(@server <> line <> "\n", @ip, @port) == [line]
    end
  end

  test "a refused connect to nscd, which sends nothing, passes" do
    trace = """
    9  connect(3, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = -1 ENOENT (No such file or directory)
    9  connect(4, {sa_family=AF_UNIX, sun_path="/run/nscd/socket"}, 110) = -1 ECONNREFUSED (Connection refused)
    """

    assert NetworkTrace.stray(trace, @ip, @port) == []
    assert length(NetworkTrace.nscd_refused(trace)) == 2
  end

  test "names the program each call was made by, through clone and exec" do
    trace = """
    7  execve("/bin/sh", ["sh", "-c", "x"], 0x7ffc /* 3 vars */) = 0
    7  clone(child_stack=NULL, flags=CLONE_CHILD_CLEARTID|SIGCHLD, child_tidptr=0x7f) = 8
    8  connect(3, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = -1 ENOENT (No such file or directory)
    8  execve("/srv/erts/bin/beam.smp", ["beam.smp"], 0x7ffc /* 9 vars */) = 0
    8  connect(4, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = -1 ENOENT (No such file or directory)
    """

    assert [
             {"?", _},
             {"/bin/sh", _},
             {"/bin/sh", "8  connect(3" <> _},
             {"/bin/sh", _},
             {"/srv/erts/bin/beam.smp", "8  connect(4" <> _}
           ] = NetworkTrace.programs(trace)

    assert NetworkTrace.stray(trace, @ip, @port) == []
  end

  test "a bind to [::]:0 and an IPv6 TypeDB pass" do
    trace = """
    9  bind(3, {sa_family=AF_INET6, sin6_port=htons(0), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "::", &sin6_addr), sin6_scope_id=0}, 28) = 0
    9  connect(4, {sa_family=AF_INET6, sin6_port=htons(8000), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "::1", &sin6_addr), sin6_scope_id=0}, 28) = 0
    """

    assert NetworkTrace.stray(trace, "::1", @port) == []
    assert NetworkTrace.connects?(trace, {0, 0, 0, 0, 0, 0, 0, 1}, @port)
    assert [_] = NetworkTrace.stray(trace, "::2", @port)
  end
end

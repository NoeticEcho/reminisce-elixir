# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.NetworkTrace do
  @moduledoc false
  # Reads `strace -f -v -e trace=network` and says which calls are not the
  # server's one connection, to TypeDB (test/mcp/network_test.exs). An
  # allowlist: a call is stray unless it is one of
  #
  #   * a connect to TypeDB's address and port;
  #   * a bind to the unspecified address and port 0 (0.0.0.0:0 or [::]:0),
  #     which talks to no one: the VM reads its host name through such a socket;
  #   * a getsockname or getpeername, which report and send nothing;
  #   * a connect to nscd's socket that fails (no nscd runs): glibc tries it
  #     before it reads /etc/passwd or /etc/hosts itself, and a shell does
  #     that when it starts; nothing is sent. One that succeeds is stray;
  #   * any other call that names no address (socket, socketpair, setsockopt,
  #     a send on a connected socket, ...), unless it is a listen or an accept
  #     or makes a raw or packet socket.
  #
  # So a connect anywhere else (DNS, a working nscd, a beacon) is stray, and
  # so is any call that names another address: a UDP sendto, sendmsg or
  # sendmmsg must name where it goes, or be on a socket connected somewhere,
  # whose connect is stray already. A lookup that glibc answers from
  # /etc/hosts or /etc/passwd makes no network call and is not seen here.

  @address ~r/sin_addr=|sin6_addr|sun_path=|nl_pid=|sll_ifindex=/

  @doc "The calls in `trace` (strace's output) that are not allowed."
  def stray(trace, ip, port) when is_binary(trace) do
    typedb = typedb(ip, port)

    trace
    |> String.split("\n", trim: true)
    |> Enum.reject(&allowed?(&1, typedb))
  end

  @doc """
  Each line of `trace` with the program its process was running when it made
  the call, for a trace of `process` calls too: a process runs what its
  parent ran until it executes something else, and a shell script that
  `exec`s the next one keeps its pid.
  """
  def programs(trace) do
    {lines, _} =
      trace
      |> String.split("\n", trim: true)
      |> Enum.map_reduce(%{}, fn line, running ->
        pid = line |> String.split(~r/\s+/, parts: 2) |> hd()
        program = Map.get(running, pid, "?")

        running =
          cond do
            match = Regex.run(~r/^\d+\s+execve\("([^"]*)".*= 0$/, line) ->
              Map.put(running, pid, Enum.at(match, 1))

            match = Regex.run(~r/(?:clone3?|v?fork)\b.*\)\s+= (\d+)$/, line) ->
              Map.put(running, Enum.at(match, 1), program)

            true ->
              running
          end

        {{program, line}, running}
      end)

    lines
  end

  @doc "The lines of `trace` that are refused connects to nscd's socket."
  def nscd_refused(trace) do
    trace |> String.split("\n", trim: true) |> Enum.filter(&nscd_refused?/1)
  end

  @doc "Whether `trace` holds a connect to TypeDB."
  def connects?(trace, ip, port) do
    typedb = typedb(ip, port)

    trace
    |> String.split("\n", trim: true)
    |> Enum.any?(&(call(&1) == "connect" and typedb?(&1, typedb)))
  end

  defp allowed?(line, typedb) do
    case call(line) do
      # The end of a call strace printed the start of earlier, where the
      # arguments are: only the results are here.
      {:resumed, _} -> not (line =~ @address) or typedb?(line, typedb)
      # Signals and exits, which -e signal=none and -qq mostly leave out.
      nil -> true
      "execve" -> true
      call when call in ~w(listen accept accept4) -> false
      "socket" -> not (line =~ ~r/SOCK_RAW|SOCK_PACKET|AF_PACKET/)
      "connect" -> typedb?(line, typedb) or nscd_refused?(line)
      "bind" -> unspecified_port_0?(line)
      call when call in ~w(getsockname getpeername) -> true
      _ -> not (line =~ @address) or typedb?(line, typedb)
    end
  end

  # The call a line is about: "1234  connect(...", or {:resumed, "connect"}
  # for "1234  <... connect resumed>...".
  defp call(line) do
    case Regex.run(~r/^(?:\[pid\s+)?\d+\]?\s+(<\.\.\.\s+)?([a-z_0-9]+)[\( ]/, line) do
      [_, "", call] -> call
      [_, _, call] -> {:resumed, call}
      nil -> nil
    end
  end

  defp typedb(ip, port) when is_tuple(ip), do: typedb(ip |> :inet.ntoa() |> to_string(), port)

  defp typedb(ip, port) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _}} ->
        [~s{sin_port=htons(#{port}), sin_addr=inet_addr("#{ip}")}]

      {:ok, _} ->
        [~s{sin6_port=htons(#{port}),}, ~s{inet_pton(AF_INET6, "#{ip}", &sin6_addr)}]
    end
  end

  # A whole connect line (not one strace split) to nscd's socket that failed.
  defp nscd_refused?(line) do
    call(line) == "connect" and
      line =~ ~r|sun_path="(/var)?/run/nscd/socket"}.*\) = -1 E[A-Z]+ | and
      not String.contains?(line, "<unfinished")
  end

  defp typedb?(line, typedb), do: Enum.all?(typedb, &String.contains?(line, &1))

  defp unspecified_port_0?(line) do
    String.contains?(line, ~s{sin_port=htons(0), sin_addr=inet_addr("0.0.0.0")}) or
      (String.contains?(line, "sin6_port=htons(0),") and
         String.contains?(line, ~s{inet_pton(AF_INET6, "::", &sin6_addr)}))
  end
end

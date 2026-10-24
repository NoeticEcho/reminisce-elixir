# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.FdOutput do
  @moduledoc false
  # An io device that writes to one file descriptor, for the release's MCP
  # stream (docs/server-artifact.md). bin/reminisce-mcp hands the server the
  # client's stdout as descriptor 3 and points descriptor 1 at stderr: what the
  # VM itself prints on descriptor 1 (a report from before the logger is set
  # up, an error at boot) then reaches stderr, and the stream holds nothing but
  # what the server writes here.
  #
  # It takes the io protocol's put_chars, setopts and getopts: what
  # Reminisce.MCP.Server asks of its output. A write waits while the
  # descriptor's queue is full (a client that does not read), as a write to
  # standard output does.

  @doc """
  Starts the device on descriptor `fd`, linked to the caller, if the process
  has that descriptor open: a port on a closed one would take writes and never
  make them.
  """
  @spec open(non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def open(fd) when is_integer(fd) and fd >= 0 do
    # /dev/fd/N is the process's own descriptor N, on Linux and on macOS.
    with {:ok, _} <- File.stat("/dev/fd/#{fd}"), do: start(fd)
  end

  defp start(fd) do
    caller = self()

    pid =
      spawn_link(fn ->
        try do
          Port.open({:fd, fd, fd}, [:binary, :out])
        rescue
          error -> send(caller, {self(), {:error, Exception.message(error)}})
        else
          port ->
            send(caller, {self(), :ok})
            loop(port)
        end
      end)

    receive do
      {^pid, :ok} -> {:ok, pid}
      {^pid, {:error, _} = error} -> error
    end
  end

  defp loop(port) do
    receive do
      {:io_request, from, reply_as, request} ->
        send(from, {:io_reply, reply_as, request(port, request)})
        loop(port)
    end
  end

  defp request(port, {:put_chars, _encoding, chars}) do
    Port.command(port, chars)
    :ok
  end

  defp request(port, {:put_chars, encoding, module, function, args}),
    do: request(port, {:put_chars, encoding, apply(module, function, args)})

  defp request(_port, {:setopts, _opts}), do: :ok
  defp request(_port, :getopts), do: [binary: true, encoding: :latin1]

  defp request(port, {:requests, requests}) do
    Enum.reduce_while(requests, :ok, fn request, :ok ->
      case request(port, request) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp request(_port, _request), do: {:error, :request}
end

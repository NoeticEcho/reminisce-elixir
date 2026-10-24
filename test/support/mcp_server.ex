# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCPServer do
  @moduledoc false
  # The command the OS-process tests start the MCP server with: `mix
  # reminisce.mcp`, or the release's `bin/reminisce-mcp` when
  # REMINISCE_MCP_SERVER names it, so that the same cases hold the built
  # artifact (docs/server-artifact.md). The tests pass it to `sh -c` as
  # $MCP_SERVER, unquoted: a path in it must not contain a space.

  def command, do: System.get_env("REMINISCE_MCP_SERVER", "mix reminisce.mcp")
end

# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

import Config

# stdout is the MCP server's protocol (docs/server-artifact.md). The release
# boots with the default log handler on stderr (rel/vm.args.eex), and Elixir's
# Logger keeps it there when it takes the handler over. A library's own
# configuration does not reach the applications that depend on it.
config :logger, :default_handler, config: [type: :standard_error]

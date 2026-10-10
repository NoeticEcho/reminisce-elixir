# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Analyser do
  @moduledoc """
  Turns text into the terms lexical recall compares: splitting, folding and
  stop words.

  The default is `Reminisce.Analyser.Default`, which folds English and Russian.
  A store takes another with `Reminisce.Store.new(conn, db, analyser: MyAnalyser)`.
  It must be deterministic: the same text always gives the same terms.
  """

  @callback terms(String.t()) :: [String.t()]
end

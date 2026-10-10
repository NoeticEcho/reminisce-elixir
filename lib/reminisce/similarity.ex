# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Similarity do
  @moduledoc """
  A port to a similarity index, such as a vector store.

  Recall asks it about its lexical candidates only, never the whole store, and
  a recall never fails because the index did: an error is reported as
  `similarity: {:unavailable, reason}` beside the lexical answer.

  It has no default implementation, and this release ships none. Pass keys to it, never
  words that are not already in your index: the library writes text nowhere but
  its store.
  """

  @callback scores(Reminisce.owner(), query :: String.t(), keys :: [String.t()]) ::
              {:ok, %{String.t() => float()}} | {:error, term()}
end

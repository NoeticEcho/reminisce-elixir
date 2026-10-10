# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.StoreTest do
  # Building a store talks to no server; what it is given is checked there.
  use ExUnit.Case, async: true

  alias Reminisce.Store

  describe ":aspects" do
    test "takes a non-empty list of lower-case names as atoms" do
      assert %Store{aspects: [:episodic, :work_log, :v2]} =
               Store.new(TypeDB, "x", aspects: [:episodic, :work_log, :v2])

      assert %Store{aspects: [:episodic | _]} = Store.new(TypeDB, "x")
    end

    test "refuses anything else when the store is built" do
      for bad <- [
            [],
            nil,
            :episodic,
            "episodic",
            ["episodic"],
            [:Episodic],
            [:"two words"],
            [:"a\"b"],
            [:"x}; match"],
            # `$` would let a trailing newline through.
            [:"abc\n"],
            [:_x],
            [:"1st"],
            [nil],
            [true],
            [:episodic, 1]
          ] do
        assert_raise ArgumentError, fn -> Store.new(TypeDB, "x", aspects: bad) end
      end
    end
  end
end

# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.DecayTest do
  use ExUnit.Case, async: true

  alias Reminisce.Memory

  @t0 ~U[2026-01-01 00:00:00Z]

  defp memory(aspects, salience \\ 0.5),
    do: %Memory{aspects: aspects, salience: salience, recorded_at: @t0}

  test "an episodic memory halves its distance to the floor in τ·ln2 days" do
    at = DateTime.add(@t0, round(30 * :math.log(2) * 86_400), :second)
    s = Reminisce.decay(memory([:episodic]), at: at)
    assert_in_delta s, 0.05 + 0.45 / 2, 1.0e-4
  end

  test "the longest-lived aspect sets the pace" do
    at = DateTime.add(@t0, 60, :day)

    assert Reminisce.decay(memory([:episodic, :semantic]), at: at) >
             Reminisce.decay(memory([:episodic]), at: at)
  end

  test "it never goes below the floor, and a recall resets the clock" do
    far = DateTime.add(@t0, 10_000, :day)
    assert_in_delta Reminisce.decay(memory([:episodic]), at: far), 0.05, 1.0e-9
    recalled = %{memory([:episodic]) | last_recalled_at: far}
    assert Reminisce.decay(recalled, at: far) == 0.5
  end
end

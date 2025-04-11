defmodule RvrbTest do
  use ExUnit.Case
  doctest Rvrb

  test "greets the world" do
    assert Rvrb.hello() == :world
  end
end

defmodule ExPyshpTest do
  use ExUnit.Case
  doctest ExPyshp

  test "greets the world" do
    assert ExPyshp.hello() == :world
  end
end

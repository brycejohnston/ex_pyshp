defmodule ExPyshp.FilesTest do
  use ExUnit.Case, async: true
  import ExPyshp.TestHelpers, only: [temporary_directory: 0]

  test "a file conflict removes new output and preserves existing files" do
    root = temporary_directory()
    source = Path.join(root, "prepared")
    destination = Path.join(root, "delivered")
    File.mkdir_p!(source)
    File.mkdir_p!(destination)

    for extension <- ~w(shp shx dbf),
        do: File.write!(Path.join(source, "shape.#{extension}"), "prepared #{extension}")

    existing = Path.join(destination, "output.dbf")
    File.write!(existing, "previous output")
    assert {:error, message} = ExPyshp.Files.publish(source, destination, "output")
    assert message =~ "Cannot publish"
    assert File.ls!(destination) == ["output.dbf"]
    assert File.read!(existing) == "previous output"
    assert Enum.sort(File.ls!(source)) == ~w(shape.dbf shape.shp shape.shx)
  end
end

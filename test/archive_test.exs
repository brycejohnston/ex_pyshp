defmodule ExPyshp.ArchiveTest do
  use ExUnit.Case, async: true
  import ExPyshp.TestHelpers, only: [temporary_directory: 0]

  setup do
    %{directory: temporary_directory()}
  end

  test "archiving creates a ZIP on disk and keeps the original files", %{directory: dir} do
    names = ~w(shape.shp shape.shx shape.dbf shape.prj shape.cpg)
    for name <- names, do: File.write!(Path.join(dir, name), name)
    assert {:ok, zip} = ExPyshp.archive(dir, "package", names)
    assert File.regular?(zip)
    assert {:ok, entries} = :zip.extract(String.to_charlist(zip), [:memory])
    assert Enum.sort(Enum.map(entries, fn {name, _} -> to_string(name) end)) == Enum.sort(names)
    assert Enum.all?(names, &(File.read!(Path.join(dir, &1)) == &1))
    before = File.read!(zip)
    assert {:error, _} = ExPyshp.archive(dir, "package", names)
    assert File.read!(zip) == before
  end

  test "archiving a directory skips ZIPs and subdirectories", %{directory: dir} do
    File.write!(Path.join(dir, "file.dbf"), "record")
    File.write!(Path.join(dir, "old.ZIP"), "old")
    File.mkdir!(Path.join(dir, "nested"))
    assert {:ok, zip} = ExPyshp.archive(dir, "selected")
    assert {:ok, [{~c"file.dbf", "record"}]} = :zip.extract(String.to_charlist(zip), [:memory])
  end

  test "archiving accepts absolute paths and rejects duplicate filenames", %{directory: dir} do
    first = Path.join(dir, "file.dbf")
    second = Path.join(dir, "nested/file.dbf")
    File.mkdir_p!(Path.dirname(second))
    File.write!(first, "first")
    File.write!(second, "second")
    assert {:ok, _} = ExPyshp.archive(dir, "absolute", [first])
    assert {:error, message} = ExPyshp.archive(dir, "duplicates", [first, second])
    assert message =~ "unique"
    assert {:error, _} = ExPyshp.archive(dir, "missing", ["absent.dbf"])
    assert {:error, _} = ExPyshp.archive(dir, "empty", [])
    assert {:error, _} = ExPyshp.archive(dir, "../escape", [first])
  end

  test "extraction groups companion files by folder and ignores Mac metadata",
       %{directory: dir} do
    entries =
      components("one/Shape", ~w(SHP SHX DBF PRJ CPG)) ++
        components("two/shape", ~w(shp shx dbf)) ++
        components("__MACOSX/._shape", ~w(shp shx dbf))

    zip = create_zip(dir, entries)
    assert {:ok, [one, two]} = ExPyshp.extract(zip, temporary_directory: dir)
    assert Path.basename(one.shp) == "Shape.SHP"
    assert Path.basename(one.prj) == "Shape.PRJ"
    assert Path.basename(one.cpg) == "Shape.CPG"
    assert Path.dirname(one.shp) != Path.dirname(two.shp)
    assert one.extraction_dir == two.extraction_dir
    assert two.prj == nil
    assert two.cpg == nil
    File.rm_rf!(one.extraction_dir)
  end

  test "repeated extractions use separate temporary directories", %{directory: dir} do
    zip = create_zip(dir, components("shape", ~w(shp shx dbf)))
    assert {:ok, [first]} = ExPyshp.extract(zip, temporary_directory: dir)
    assert {:ok, [second]} = ExPyshp.extract(zip, temporary_directory: dir)
    refute first.extraction_dir == second.extraction_dir
    File.rm_rf!(first.extraction_dir)
    assert File.exists?(second.shp)
    File.rm_rf!(second.extraction_dir)
  end

  test "incomplete or duplicate shapefile groups fail without leaving temporary files", %{
    directory: dir
  } do
    for {entries, message} <- [
          {components("shape", ~w(shp dbf)), "Incomplete"},
          {components("shape", ~w(shp shx dbf)) ++ [{"shape.SHP", "duplicate"}], "duplicate"},
          {[{"notes.txt", "no shapes"}], "No shapefile"}
        ] do
      zip = create_zip(dir, entries)
      assert {:error, error} = ExPyshp.extract(zip, temporary_directory: dir)
      assert error =~ message
      assert owned_directories(dir) == []
    end

    zip = create_zip(dir, [])
    assert {:error, message} = ExPyshp.extract(zip, temporary_directory: dir)
    assert message =~ "empty"
  end

  test "unsafe ZIP paths are rejected before any files are extracted", %{directory: dir} do
    for entry <- [
          "../escape.shp",
          "/absolute.shp",
          "C:/escape.shp",
          "folder\\escape.shp",
          "folder/../escape.shp"
        ] do
      zip = create_unsafe_zip(dir, entry)
      assert {:error, message} = ExPyshp.extract(zip, temporary_directory: dir)
      assert message =~ "unsafe"
      assert owned_directories(dir) == []
    end
  end

  test "ZIP file counts and sizes are checked before extraction", %{directory: dir} do
    zip = create_zip(dir, components("shape", ~w(shp shx dbf)))

    for {option, value} <- [max_entries: 2, max_file_size: 1, max_uncompressed_size: 4] do
      assert {:error, message} =
               ExPyshp.extract(zip, [{:temporary_directory, dir}, {option, value}])

      assert message =~ Atom.to_string(option)
      assert owned_directories(dir) == []
    end

    assert {:error, _} = ExPyshp.extract(zip, max_entries: 0)
    assert {:error, _} = ExPyshp.extract(zip, unknown: true)
  end

  test "with_extract returns the callback result and preserves unrelated files", %{directory: dir} do
    zip = create_zip(dir, components("shape", ~w(shp shx dbf)))
    outside = Path.join(dir, "preserved")
    File.write!(outside, "keep")

    assert :done =
             ExPyshp.with_extract(zip, [temporary_directory: dir], fn [group] ->
               assert File.exists?(group.shp)
               :done
             end)

    assert owned_directories(dir) == []
    assert File.read!(outside) == "keep"
    assert File.exists?(zip)
  end

  test "with_extract removes temporary files before raising a callback error", %{directory: dir} do
    zip = create_zip(dir, components("shape", ~w(shp shx dbf)))

    assert_raise RuntimeError, "callback failed", fn ->
      ExPyshp.with_extract(zip, [temporary_directory: dir], fn _ -> raise "callback failed" end)
    end

    assert owned_directories(dir) == []
  end

  test "stopping the caller removes its temporary extraction directory", %{directory: dir} do
    parent = self()
    zip = create_zip(dir, components("shape", ~w(shp shx dbf)))

    owner =
      spawn(fn ->
        ExPyshp.with_extract(zip, [temporary_directory: dir], fn [group] ->
          send(parent, {:extracted, group.extraction_dir})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:extracted, temporary}
    assert File.dir?(temporary)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    await_cleanup(temporary, 50)
    refute File.exists?(temporary)
    assert File.exists?(zip)
  end

  test "missing or damaged ZIPs return an error and leave no temporary files", %{
    directory: dir
  } do
    assert {:error, message} = ExPyshp.extract(Path.join(dir, "missing.zip"))
    assert message =~ "Cannot read ZIP"
    invalid = Path.join(dir, "invalid.zip")
    File.write!(invalid, "not a zip")
    assert {:error, message} = ExPyshp.extract(invalid)
    assert message =~ "Cannot read ZIP"
    zip = create_zip(dir, components("shape", ~w(shp shx dbf)))
    bytes = File.read!(zip)
    File.write!(zip, :binary.replace(bytes, "component", "corrupted", [:global]))
    assert {:error, message} = ExPyshp.extract(zip, temporary_directory: dir)
    assert is_binary(message)
    assert owned_directories(dir) == []
  end

  defp create_zip(directory, entries) do
    path = Path.join(directory, "fixture.zip")

    {:ok, _} =
      :zip.create(
        String.to_charlist(path),
        Enum.map(entries, fn {name, contents} -> {String.to_charlist(name), contents} end),
        compress: []
      )

    path
  end

  defp create_unsafe_zip(directory, entry) do
    # Erlang's ZIP writer removes leading slashes. Replace both filename copies
    # with same-length names to test unsafe archives made by other writers.
    safe_name = String.duplicate("x", byte_size(entry))
    path = create_zip(directory, [{safe_name, "unsafe"}])
    File.write!(path, :binary.replace(File.read!(path), safe_name, entry, [:global]))
    path
  end

  defp components(stem, extensions), do: Enum.map(extensions, &{"#{stem}.#{&1}", "component"})

  defp owned_directories(directory),
    do: Path.wildcard(Path.join(directory, ".ex_pyshp-*"), match_dot: true)

  defp await_cleanup(_, 0), do: :ok

  defp await_cleanup(path, remaining) do
    if File.exists?(path) do
      Process.sleep(10)
      await_cleanup(path, remaining - 1)
    end
  end
end

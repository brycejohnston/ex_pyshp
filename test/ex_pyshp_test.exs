defmodule ExPyshpTest do
  use ExUnit.Case
  import ExPyshp.TestHelpers

  setup do
    %{directory: temporary_directory()}
  end

  test "runtime_info reports the Python and package versions in use" do
    assert {:ok, versions} = ExPyshp.runtime_info()
    for name <- ~w(python pyshp shapely pyproj), do: assert(is_binary(versions[name]))
  end

  test "writing and reading keep IDs, zeros and missing values with the right points", %{
    directory: dir
  } do
    rows = [
      row(%Geo.Point{coordinates: {1.0, 2.0}}, %{
        "ID" => "0001",
        "RATE" => nil,
        "ACTIVE" => nil,
        "DATE" => "2026-09-28"
      }),
      row(%Geo.Point{coordinates: {3.0, 4.0}}, %{"RATE" => 0.0, "ID" => "0", "ACTIVE" => false}),
      row(%Geo.Point{coordinates: {5.0, 6.0}}, %{
        "ACTIVE" => true,
        "RATE" => 123.4567,
        "ID" => "0003"
      })
    ]

    assert {:ok, files} =
             ExPyshp.write(dir, "typed", rows,
               projection_srid: 4326,
               numeric_precision: 4,
               field_types: %{"DATE" => :date}
             )

    [first, second, third] = read_rows(files)

    assert first["record"] == %{
             "ID" => "0001",
             "RATE" => nil,
             "ACTIVE" => nil,
             "DATE" => "2026-09-28"
           }

    assert second["record"]["RATE"] == 0.0
    assert second["record"]["ID"] == "0"
    assert second["record"]["ACTIVE"] == false
    assert third["record"]["RATE"] == 123.4567
    assert third["geometry"].coordinates == {5.0, 6.0}
    assert third["geometry"].srid == 4326
    assert File.exists?(files.prj)
    assert File.read!(files.cpg) == "utf-8"
  end

  test "points, multipoints, lines and polygons can be written and read", %{directory: dir} do
    polygon = polygon()

    shifted =
      Enum.map(polygon.coordinates, fn ring -> Enum.map(ring, fn {x, y} -> {x + 20, y} end) end)

    geometries = [
      %Geo.Point{coordinates: {1.0, 2.0}},
      %Geo.MultiPoint{coordinates: [{1.0, 2.0}, {3.0, 4.0}]},
      %Geo.LineString{coordinates: [{1.0, 2.0}, {3.0, 4.0}]},
      %Geo.MultiLineString{coordinates: [[{1.0, 2.0}, {3.0, 4.0}], [{5.0, 6.0}, {7.0, 8.0}]]},
      polygon,
      %Geo.MultiPolygon{coordinates: [polygon.coordinates, shifted]}
    ]

    for {geometry, index} <- Enum.with_index(geometries) do
      assert {:ok, files} =
               ExPyshp.write(dir, "family#{index}", [row(geometry)], projection_srid: 4326)

      [saved] = read_rows(files)
      assert saved["geometry"].__struct__ == geometry.__struct__
      assert is_binary(saved["wkt"])
    end
  end

  test "writing sets polygon and hole directions without moving vertices", %{directory: dir} do
    geometry = polygon()
    assert {:ok, files} = ExPyshp.write(dir, "holes", [row(geometry)])
    [shell, hole] = saved_rings(files.shp)
    assert exact_area_sign(shell) == :clockwise
    assert exact_area_sign(hole) == :counterclockwise
    assert MapSet.new(shell) == MapSet.new(hd(geometry.coordinates))
    assert MapSet.new(hole) == MapSet.new(List.last(geometry.coordinates))
  end

  test "very thin polygons and tiny holes survive writing and reading", %{directory: dir} do
    for fixture <- ~w(nearly_collinear tiny_holes) do
      geometry =
        File.read!("test/fixtures/#{fixture}.json") |> Jason.decode!() |> Geo.JSON.decode!()

      assert {:ok, files} =
               ExPyshp.write(dir, fixture, [row(geometry, %{"RATE" => 90.1234})],
                 numeric_precision: 4
               )

      [saved] = read_rows(files)
      assert saved["record"]["RATE"] == 90.1234
      assert length(saved["geometry"].coordinates) == length(geometry.coordinates)

      for {ring, index} <- Enum.with_index(saved_rings(files.shp)) do
        assert exact_area_sign(ring) == if(index == 0, do: :clockwise, else: :counterclockwise)
        assert MapSet.new(ring) == MapSet.new(Enum.at(geometry.coordinates, index))
      end
    end
  end

  test "multipart polygons keep holes with their original polygon", %{directory: dir} do
    geometry =
      File.read!("test/fixtures/tiny_holes.json") |> Jason.decode!() |> Geo.JSON.decode!()

    multipart = %Geo.MultiPolygon{coordinates: [polygon().coordinates, geometry.coordinates]}
    assert {:ok, files} = ExPyshp.write(dir, "multipart", [row(multipart)])
    [saved] = read_rows(files)
    assert %Geo.MultiPolygon{coordinates: parts} = saved["geometry"]
    assert Enum.map(parts, &length/1) == [2, 3]
  end

  test "writing preserves large and negative numbers at the requested precision", %{
    directory: dir
  } do
    rows =
      for rate <- [12_138.68, 123_456_789.1234, -0.0001, 0.0],
          do: row(%Geo.Point{coordinates: {1.0, 2.0}}, %{"RATE" => rate})

    assert {:ok, files} = ExPyshp.write(dir, "rates", rows, numeric_precision: 4)

    assert Enum.map(read_rows(files), & &1["record"]["RATE"]) == [
             12_138.68,
             123_456_789.1234,
             -0.0001,
             0.0
           ]
  end

  test "writing uses the requested field widths and decimal places", %{directory: dir} do
    assert {:ok, files} =
             ExPyshp.write(
               dir,
               "widths",
               [row(%Geo.Point{coordinates: {1.0, 2.0}}, %{"RATE" => 12.3456, "ID" => "001"})],
               field_types: %{
                 "RATE" => %{type: :number, width: 12, decimals: 4},
                 "ID" => %{type: :string, width: 4}
               }
             )

    fields =
      python(
        "import shapefile\nwith shapefile.Reader(base) as r:\n    result = [list(f) for f in r.fields[1:]]\nresult",
        %{"base" => Path.rootname(files.shp)}
      )

    assert fields == [["ID", "C", 4, 0], ["RATE", "N", 12, 4]]
  end

  test "reading uses the CPG encoding to preserve accented text", %{directory: dir} do
    for encoding <- ["utf-8", "cp1252"] do
      assert {:ok, files} =
               ExPyshp.write(
                 dir,
                 encoding,
                 [row(%Geo.Point{coordinates: {1.0, 2.0}}, %{"NAME" => "Café"})],
                 encoding: encoding
               )

      [saved] = read_rows(files)
      assert saved["record"]["NAME"] == "Café"
      assert saved["encoding"] == encoding
    end
  end

  test "reading converts coordinates to WGS84 and keeps the source projection", %{directory: dir} do
    geometry = %Geo.Point{coordinates: {1_113_194.9079327357, 2_273_030.9269876895}, srid: 3857}
    assert {:ok, files} = ExPyshp.write(dir, "projected", [row(geometry)], projection_srid: 3857)
    [saved] = read_rows(files)
    {longitude, latitude} = saved["geometry"].coordinates
    assert_in_delta longitude, 10.0, 1.0e-8
    assert_in_delta latitude, 20.0, 1.0e-8
    assert saved["projection_srid"] == 3857
    assert saved["geometry_srid"] == 4326
    [original] = read_rows(files, reproject: false)
    assert original["geometry"].coordinates == geometry.coordinates
    assert original["geometry_srid"] == 3857
  end

  test "reading leaves an unknown projection unset unless a source is provided", %{directory: dir} do
    assert {:ok, files} =
             ExPyshp.write(dir, "unknown", [row(%Geo.Point{coordinates: {1.0, 2.0}, srid: nil})])

    assert files.prj == nil
    [saved] = read_rows(files)
    assert saved["geometry_srid"] == nil
    assert saved["projection_srid"] == nil

    assert {:error, "unknown", message} =
             ExPyshp.read(files.shp, files.dbf, files.shx, require_projection: true)

    assert message =~ "unknown"
    [explicit] = read_rows(files, source_crs: 4326)
    assert explicit["geometry_srid"] == 4326
  end

  test "reading finds uppercase PRJ files and rejects invalid or conflicting projections", %{
    directory: dir
  } do
    assert {:ok, files} = ExPyshp.write(dir, "projection", [row()], projection_srid: 4326)
    File.rename!(files.prj, Path.rootname(files.prj) <> ".PRJ")
    File.rename!(files.cpg, Path.rootname(files.cpg) <> ".CPG")
    assert [_] = read_rows(files)
    assert {:error, _, conflict} = ExPyshp.read(files.shp, files.dbf, files.shx, source_crs: 3857)
    assert conflict =~ "conflicts"
    File.write!(Path.rootname(files.prj) <> ".PRJ", "not a projection")
    assert {:error, _, invalid} = ExPyshp.read(files.shp, files.dbf, files.shx)
    assert invalid =~ "projection file"
  end

  test "writing rejects a projection that differs from the geometry", %{directory: dir} do
    assert {:error, message} = ExPyshp.write(dir, "wrong", [row()], projection_srid: 3857)
    assert message =~ "SRID differs"
    assert File.ls!(dir) == []
  end

  test "invalid, three-dimensional or mixed geometry leaves no output files", %{directory: dir} do
    invalid = %Geo.Polygon{
      coordinates: [[{0.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}, {1.0, 0.0}, {0.0, 0.0}]]
    }

    for {name, data} <- [
          {"invalid", [row(invalid)]},
          {"z", [row(%Geo.PointZ{coordinates: {1.0, 2.0, 3.0}})]},
          {"mixed", [row(), row(polygon())]}
        ] do
      assert {:error, _} = ExPyshp.write(dir, name, data)
      assert File.ls!(dir) == []
    end
  end

  test "writing rejects invalid field names and values that would lose data", %{directory: dir} do
    for {name, record, options} <- [
          {"numeric", %{"RATE" => 12_345.67}, [numeric_width: 6, numeric_precision: 2]},
          {"text", %{"NAME" => "ééé"}, [field_types: %{"NAME" => %{type: :string, width: 5}}]},
          {"case", %{"ID" => "a", "id" => "b"}, []},
          {"long", %{"LONG_COLUMN" => 1}, []},
          {"integer", %{"RATE" => 1.25}, [field_types: %{"RATE" => :integer}]},
          {"trailing", %{"NAME" => "A "}, []}
        ] do
      assert {:error, _} =
               ExPyshp.write(
                 dir,
                 name,
                 [row(%Geo.Point{coordinates: {1.0, 2.0}}, record)],
                 options
               )

      assert File.ls!(dir) == []
    end
  end

  test "size limits and invalid arguments leave no output files", %{directory: dir} do
    assert {:error, _} = ExPyshp.write(dir, "tiny", [row()], max_file_size: 1)
    assert {:error, _} = ExPyshp.write(dir, "bad", [], unused: true)
    assert {:error, _} = ExPyshp.write(dir, "empty", [])
    assert {:error, _} = ExPyshp.write(dir, "../escape", [row()])
    assert File.ls!(dir) == []
    assert {:error, _, message} = ExPyshp.read("missing.shp", "missing.dbf", "missing.shx")
    assert message =~ "not found"
  end

  test "existing files are unchanged when another write uses the same name", %{directory: dir} do
    assert {:ok, files} = ExPyshp.write(dir, "existing", [row()])

    originals =
      Map.new(Enum.reject(files, fn {_, path} -> is_nil(path) end), fn {key, path} ->
        {key, File.read!(path)}
      end)

    assert {:error, _} = ExPyshp.write(dir, "existing", [row(polygon())])
    for {key, bytes} <- originals, do: assert(File.read!(files[key]) == bytes)
    refute Enum.any?(File.ls!(dir), &String.starts_with?(&1, ".ex_pyshp-"))
  end

  test "simultaneous writes to one name produce one complete result", %{directory: dir} do
    results =
      1..4
      |> Task.async_stream(
        fn value ->
          ExPyshp.write(dir, "same", [
            row(%Geo.Point{coordinates: {value * 1.0, 2.0}}, %{"RATE" => value})
          ])
        end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, files}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert length(Enum.filter(results, &match?({:error, _}, &1))) == 3
    [saved] = read_rows(files)
    assert {saved["record"]["RATE"] * 1.0, 2.0} == saved["geometry"].coordinates
  end

  test "reading keeps NULL shapes and the original Z/M values", %{directory: dir} do
    nulls =
      fixture(dir, "nulls", """
      with shapefile.Writer(base, shapeType=shapefile.POINT) as w:
          w.field('ID', 'C', 10)
          w.null()
          w.record('null')
          w.point(1, 2)
          w.record('point')
      """)

    [null, point] = read_rows(nulls)
    assert null["geometry"] == nil
    assert null["record"]["ID"] == "null"
    assert point["geometry"].coordinates == {1.0, 2.0}

    z =
      fixture(dir, "pointz", """
      with shapefile.Writer(base, shapeType=shapefile.POINTZ) as w:
          w.field('ID', 'C', 10)
          w.pointz(1, 2, 3, 4)
          w.record('z')
      """)

    [point] = read_rows(z)
    assert point["geometry"].coordinates == {1.0, 2.0}
    assert point["z_values"] == [3.0]
    assert point["m_values"] == [4.0]
  end

  test "temporary exports produce a readable ZIP and clean up after failures", %{
    directory: dir
  } do
    destination = Path.join(dir, "delivered.zip")

    assert :delivered =
             ExPyshp.with_archive(
               "delivery",
               [row(polygon(), %{"RATE" => 12.3456})],
               [numeric_precision: 4, temporary_directory: dir],
               fn zip ->
                 assert :verified =
                          ExPyshp.with_extract(zip, fn [group] ->
                            [saved] = read_rows(group)
                            assert saved["record"]["RATE"] == 12.3456
                            assert length(saved["geometry"].coordinates) == 2
                            :verified
                          end)

                 File.cp!(zip, destination)
                 :delivered
               end
             )

    assert File.ls!(dir) == ["delivered.zip"]
    assert File.regular?(destination)

    assert {:error, _} =
             ExPyshp.with_archive("empty", [], [temporary_directory: dir], fn _ ->
               flunk("The callback should not run when there are no rows to export")
             end)

    assert File.ls!(dir) == ["delivered.zip"]

    assert_raise RuntimeError, "upload failed", fn ->
      ExPyshp.with_archive("failed", [row()], [temporary_directory: dir], fn _ ->
        raise "upload failed"
      end)
    end

    assert File.ls!(dir) == ["delivered.zip"]
  end

  test "writing infers a projection only when the geometry SRIDs agree", %{directory: dir} do
    assert {:ok, files} = ExPyshp.write(dir, "inferred", [row()])
    assert files.prj
    assert [%{"projection_srid" => 4326}] = read_rows(files)

    for geometry <- [
          %Geo.Point{coordinates: {1.0, 2.0}, srid: 3857},
          %Geo.Point{coordinates: {1.0, 2.0}, srid: nil}
        ] do
      assert {:error, message} = ExPyshp.write(dir, "conflict", [row(), row(geometry)])
      assert message =~ "SRID"
    end
  end

  test "reading uses the requested projection and text encoding", %{directory: dir} do
    assert {:ok, files} =
             ExPyshp.write(
               dir,
               "selected",
               [row(%Geo.Point{coordinates: {10.0, 20.0}, srid: 4326}, %{"NAME" => "Café"})],
               encoding: "cp1252"
             )

    [projected] = read_rows(files, target_crs: 3857)
    assert projected["geometry_srid"] == 3857
    {x, y} = projected["geometry"].coordinates
    assert_in_delta x, 1_113_194.9079327357, 1.0e-8
    assert_in_delta y, 2_273_030.9269876895, 1.0e-8
    File.write!(files.cpg, "invalid-encoding")
    assert {:error, _, _} = ExPyshp.read(files.shp, files.dbf, files.shx)
    [saved] = read_rows(files, encoding: "cp1252")
    assert saved["record"]["NAME"] == "Café"
    [saved] = read_rows(files, discover: false, encoding: "cp1252", source_crs: 4326)
    assert saved["geometry_srid"] == 4326
  end

  test "CPG code-page numbers can include a UTF-8 byte-order mark", %{directory: dir} do
    assert {:ok, files} =
             ExPyshp.write(
               dir,
               "bom",
               [row(%Geo.Point{coordinates: {1.0, 2.0}}, %{"NAME" => "Café"})],
               encoding: "cp1252"
             )

    File.write!(files.cpg, <<239, 187, 191>> <> "1252\n")
    assert [%{"record" => %{"NAME" => "Café"}}] = read_rows(files)
  end

  test "text fields use only the width needed for their values", %{directory: dir} do
    record = Map.new(1..30, fn index -> {"COL#{index}", "id"} end)

    assert {:ok, files} =
             ExPyshp.write(dir, "text_columns", [row(%Geo.Point{coordinates: {1.0, 2.0}}, record)])

    assert [%{"record" => ^record}] = read_rows(files)
    excessive = Map.new(1..20, fn index -> {"COL#{index}", String.duplicate("a", 254)} end)

    assert {:error, error} =
             ExPyshp.write(dir, "excessive", [row(%Geo.Point{coordinates: {1.0, 2.0}}, excessive)])

    assert error =~ "4000-byte"
  end

  test "reading rejects mismatched shape and attribute counts", %{directory: dir} do
    assert {:ok, files} = ExPyshp.write(dir, "counts", [row()])
    <<prefix::binary-size(4), _count::little-32, rest::binary>> = File.read!(files.dbf)
    File.write!(files.dbf, <<prefix::binary, 2::little-32, rest::binary>>)
    assert {:error, "counts", error} = ExPyshp.read(files.shp, files.dbf, files.shx)
    assert error =~ "count differs"
  end

  test "invalid options and filesystem failures return clear errors", %{directory: dir} do
    blocked = Path.join(dir, "file")
    File.write!(blocked, "keep")
    assert {:error, message} = ExPyshp.write(Path.join(blocked, "output"), "error", [row()])
    assert is_binary(message)

    assert {:error, message} =
             ExPyshp.with_archive("error", [row()], [temporary_directory: blocked], fn _ ->
               flunk("The callback should not run when its temporary directory cannot be created")
             end)

    assert is_binary(message)
    assert {:error, _} = ExPyshp.write(dir, "not_rows", :invalid)

    assert {:error, _} =
             ExPyshp.write(dir, "not_geometry", [%{"record" => %{}, "geometry" => nil}])

    assert {:error, _} =
             ExPyshp.write(dir, "atom_key", [row(%Geo.Point{coordinates: {1.0, 2.0}}, %{id: "a"})])

    assert {:error, _} = ExPyshp.write(dir, "bad_limit", [row()], max_file_size: 0)

    assert {:error, _} =
             ExPyshp.write(
               dir,
               "bad_precision",
               [row(%Geo.Point{coordinates: {1.0, 2.0}}, %{"RATE" => 1.0})],
               numeric_precision: 16
             )

    assert {:error, _} =
             ExPyshp.write(dir, "bad_override", [row()], field_types: %{"OTHER" => :number})

    assert {:error, _} =
             ExPyshp.write(dir, "disagreement", [row()],
               projection_srid: 4326,
               projection_wkt: "EPSG:3857"
             )

    assert File.read!(blocked) == "keep"
    assert File.ls!(dir) == ["file"]
  end

  test "GDAL reads exported holes, IDs, zeros and four-decimal values", %{directory: dir} do
    assert executable = System.find_executable("ogr2ogr"),
           "Install GDAL (gdal-bin on Linux or brew install gdal on macOS) to run this test"

    rows = [
      row(polygon(), %{"ID" => "0001", "RATE" => 123.4567}),
      row(polygon(), %{"ID" => "0", "RATE" => 0.0})
    ]

    assert {:ok, files} = ExPyshp.write(dir, "gdal", rows, numeric_precision: 4)
    target = Path.join(dir, "independent.json")

    assert {_, 0} =
             System.cmd(executable, ["-f", "GeoJSON", target, files.shp], stderr_to_stdout: true)

    features = File.read!(target) |> Jason.decode!() |> Map.fetch!("features")
    assert Enum.map(features, & &1["properties"]["ID"]) == ["0001", "0"]
    assert Enum.map(features, & &1["properties"]["RATE"]) == [123.4567, 0.0]
    assert Enum.all?(features, &(length(&1["geometry"]["coordinates"]) == 2))
  end
end

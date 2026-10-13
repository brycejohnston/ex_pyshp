defmodule ExPyshp.TestHelpers do
  @moduledoc false

  def temporary_directory do
    directory = ExPyshp.Files.temporary_directory(System.tmp_dir!())
    File.mkdir_p!(directory)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(directory) end)
    directory
  end

  def row(
        geometry \\ %Geo.Point{coordinates: {-101.5, 38.0}, srid: 4326},
        record \\ %{"ID" => "0001"}
      ) do
    %{"geometry" => geometry, "record" => record}
  end

  def read_rows(files, options \\ []) do
    {:ok, _, rows} = ExPyshp.read(files.shp, files.dbf, files.shx, options)
    rows
  end

  def python(code, bindings \\ %{}) do
    :global.trans({{ExPyshp.Runtime, :interpreter}, self()}, fn ->
      {result, _} =
        Pythonx.eval(
          "import json\nbindings = json.loads(bindings_json)\nglobals().update(bindings)\n" <>
            code,
          %{"bindings_json" => Jason.encode!(bindings)}
        )

      if result, do: Pythonx.decode(result), else: nil
    end)
  end

  def fixture(directory, name, code) do
    base = Path.join(directory, name)
    python("import shapefile\nfrom pathlib import Path\n" <> code, %{"base" => base})
    %{shp: base <> ".shp", shx: base <> ".shx", dbf: base <> ".dbf", prj: nil, cpg: nil}
  end

  def polygon do
    %Geo.Polygon{
      srid: 4326,
      coordinates: [
        [{0.0, 0.0}, {10.0, 0.0}, {10.0, 10.0}, {0.0, 10.0}, {0.0, 0.0}],
        [{2.0, 2.0}, {4.0, 2.0}, {4.0, 4.0}, {2.0, 4.0}, {2.0, 2.0}]
      ]
    }
  end

  def saved_rings(path) do
    <<_header::binary-size(100), _number::32, _size::32, 5::little-32, _bbox::binary-size(32),
      parts::little-32, count::little-32, rest::binary>> = File.read!(path)

    <<indices::binary-size(^parts * 4), coordinates::binary>> = rest
    indices = for <<start::little-32 <- indices>>, do: start
    points = for <<x::little-float-64, y::little-float-64 <- coordinates>>, do: {x, y}

    for {start, stop} <- Enum.zip(indices, tl(indices) ++ [count]),
        do: Enum.slice(points, start, stop - start)
  end

  # Scale stored floats to integers without rounding. This checks ring direction
  # separately from the writer's floating-point calculation.
  def exact_area_sign(ring) do
    numbers = Enum.map(ring, fn {x, y} -> {binary_float(x), binary_float(y)} end)
    exponent = numbers |> Enum.flat_map(fn {{_, ex}, {_, ey}} -> [ex, ey] end) |> Enum.min()

    scaled =
      Enum.map(numbers, fn {{x, ex}, {y, ey}} ->
        {Integer.pow(2, ex - exponent) * x, Integer.pow(2, ey - exponent) * y}
      end)

    area =
      Enum.reduce(Enum.zip(scaled, tl(scaled)), 0, fn {{x, y}, {nx, ny}}, sum ->
        sum + x * ny - nx * y
      end)

    cond do
      area < 0 -> :clockwise
      area > 0 -> :counterclockwise
      true -> :zero
    end
  end

  defp binary_float(value) do
    <<sign::1, exponent::11, mantissa::52>> = <<value::float-64>>
    coefficient = if exponent == 0, do: mantissa, else: mantissa + Integer.pow(2, 52)
    coefficient = if sign == 1, do: -coefficient, else: coefficient
    {coefficient, if(exponent == 0, do: 1, else: exponent) - 1075}
  end
end

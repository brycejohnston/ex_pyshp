defmodule ExPyshp do
  @doc """
  Reads the shapefile from the given SHP, DBF, and SHX file paths, and returns a list of maps where each map has:
    - "record": a map where each key is a DBF column header and the value is the corresponding record value
    - "geometry": the corresponding Geo struct (converted using the Geo library from the __geo_interface__)

  Returns either:
    - {:ok, base_name, result_list} on success
    - {:error, base_name, reason} if any file is missing or an error occurs.
  """
  def read(shp_path, dbf_path, shx_path) do
    # Compute the base filename (without extension) from the SHP file path for error reporting and output.
    base_name = Path.basename(shp_path, Path.extname(shp_path))

    with true <- File.exists?(shp_path) || {:error, "SHP file not found: #{shp_path}"},
         true <- File.exists?(dbf_path) || {:error, "DBF file not found: #{dbf_path}"},
         true <- File.exists?(shx_path) || {:error, "SHX file not found: #{shx_path}"},
         safe_shp = String.replace(shp_path, "\\", "\\\\"),
         safe_dbf = String.replace(dbf_path, "\\", "\\\\"),
         safe_shx = String.replace(shx_path, "\\", "\\\\"),
         bindings = %{
           "safe_shp" => safe_shp,
           "safe_dbf" => safe_dbf,
           "safe_shx" => safe_shx
         },
         {result, _globals} <-
           Pythonx.eval(
             """
             import shapefile
             import json
             with open(safe_shp, 'rb') as shp_f, open(safe_dbf, 'rb') as dbf_f, open(safe_shx, 'rb') as shx_f:
                 reader = shapefile.Reader(shp=shp_f, dbf=dbf_f, shx=shx_f)
                 # Skip the deletion flag field from the DBF fields
                 fields = reader.fields[1:]
                 field_names = [f[0] for f in fields]
                 shape_records = reader.shapeRecords()
                 result_list = []
                 for sr in shape_records:
                     # Build a record map from headers and record values
                     record_map = dict(zip(field_names, sr.record))
                     geom = sr.shape.__geo_interface__
                     result_list.append({'record': record_map, 'geometry': geom})
             json.dumps(result_list)
             """,
             bindings,
             []
           ),
         result_json = Pythonx.decode(result),
         parsed_result = Jason.decode!(result_json),
         result_final =
           Enum.map(parsed_result, fn item ->
             geometry = Geo.JSON.decode!(item["geometry"])
             wkt = Geo.WKT.encode!(geometry)

             item
             |> Map.put("geometry", geometry)
             |> Map.put("wkt", wkt)
           end) do
      {:ok, base_name, result_final}
    else
      {:error, reason} -> {:error, base_name, reason}
      other -> {:error, base_name, inspect(other)}
    end
  end

  @doc """
  Writes a shapefile to `path` using the provided data.

  - `data` should be a list of maps in the format:
    [
      %{
        "record" => %{"field1" => value1, "field2" => value2, ...},
        "geometry" => %Geo.Geometry{...}
      },
      ...
    ]

  The function extracts the fields and records from the data and writes them to the shapefile.
  """
  def write(path, name, data) do
    # Extract fields from the first record's keys
    fields =
      data
      |> Enum.at(0)
      |> Map.get("record")
      |> Map.keys()
      # Default to character fields with max length 255
      |> Enum.map(&[&1, "C", 255])

    # Extract records and geometries
    records = Enum.map(data, &Map.get(&1, "record"))
    geometries = Enum.map(data, &Map.get(&1, "geometry"))

    # Convert fields and records to JSON for Python
    fields_json = Jason.encode!(fields)
    records_json = Jason.encode!(records)

    # Convert geometries to GeoJSON for Python
    geometries_json =
      geometries
      |> Enum.map(&Geo.JSON.encode!/1)
      |> Jason.encode!()

    full_path = Path.join(path, name)
    safe_path = String.replace(full_path, "\\", "\\\\")

    bindings = %{
      "safe_path" => safe_path,
      "fields_json" => fields_json,
      "records_json" => records_json,
      "geometries_json" => geometries_json
    }

    Pythonx.eval(
      """
      import shapefile
      import json
      from shapely.geometry import shape

      writer = shapefile.Writer(safe_path)

      # Add fields
      for f in json.loads(fields_json):
          writer.field(*f)

      # Add records and geometries
      records = json.loads(records_json)
      geometries = json.loads(geometries_json)

      for rec, geom in zip(records, geometries):
          writer.record(*rec.values())
          shapely_geom = shape(geom)
          writer.shape(shapely_geom)

      writer.close()
      """,
      bindings
    )
  end

  @doc """
  Extracts the given ZIP file to a temporary directory, scans the extracted files,
  groups together files that have the same base name (before the extension) for SHP, DBF, and SHX,
  and returns a list of maps containing the paths for matching SHP, DBF, and SHX pairs.

  Returns either:
    - {:ok, [%{shp: shp_path, dbf: dbf_path, shx: shx_path}, ...]} on success
    - {:error, reason} if extraction fails or no valid groups are found.
  """
  def extract(zip_path) do
    with true <- File.exists?(zip_path) || {:error, "ZIP file not found: #{zip_path}"},
         tmp_dir = Path.join(System.tmp_dir!(), "ex_pyshp_#{:os.system_time(:millisecond)}"),
         :ok <- File.mkdir_p(tmp_dir),
         {:ok, _files} <-
           :zip.unzip(String.to_charlist(zip_path), cwd: String.to_charlist(tmp_dir)) do
      all_files = Path.wildcard(Path.join(tmp_dir, "**/*"))

      files =
        all_files
        |> Enum.filter(&File.regular?/1)
        |> Enum.filter(fn file ->
          ext = Path.extname(file) |> String.downcase()
          ext in [".shp", ".dbf", ".shx"]
        end)

      grouped =
        files
        |> Enum.group_by(fn file ->
          file |> Path.basename() |> Path.rootname()
        end)

      pairs =
        grouped
        |> Enum.filter(fn {_base, files} ->
          exts = files |> Enum.map(&(Path.extname(&1) |> String.downcase())) |> MapSet.new()
          MapSet.subset?(MapSet.new([".shp", ".dbf", ".shx"]), exts)
        end)

      case pairs do
        [] ->
          {:error, "No valid shapefile groups found in extracted contents."}

        _ ->
          {:ok,
           for {_base, files} <- pairs do
             shp = Enum.find(files, fn file -> String.downcase(Path.extname(file)) == ".shp" end)
             dbf = Enum.find(files, fn file -> String.downcase(Path.extname(file)) == ".dbf" end)
             shx = Enum.find(files, fn file -> String.downcase(Path.extname(file)) == ".shx" end)
             %{shp: shp, dbf: dbf, shx: shx}
           end}
      end
    else
      error -> error
    end
  end
end

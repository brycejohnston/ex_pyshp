defmodule ExPyshp do
  @doc """
  Reads the shapefile from the given SHP, DBF, and SHX file paths, and returns a list of maps where each map has:
    - "record": a map where each key is a DBF column header and the value is the corresponding record value
    - "geometry": the corresponding Geo struct (converted using the Geo library from the __geo_interface__)
    - "filename": the base filename (without extension) from which the data came

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
             Map.update!(item, "geometry", fn geom -> Geo.JSON.decode!(geom) end)
           end) do
      {:ok, base_name, result_final}
    else
      {:error, reason} -> {:error, base_name, reason}
      other -> {:error, base_name, inspect(other)}
    end
  end

  @doc """
  Writes a shapefile to `path` using provided `fields` and `records`.

  - `fields` should be a list like: `[["name", "C", 40], ["value", "N", 10, 2]]`
  - `records` should be a list of record values corresponding to the fields.
  """
  def write(path, fields, records) do
    fields_json = Jason.encode!(fields)
    records_json = Jason.encode!(records)
    safe_path = String.replace(path, "\\", "\\\\")

    bindings = %{
      "safe_path" => safe_path,
      "fields_json" => fields_json,
      "records_json" => records_json
    }

    Pythonx.eval(
      """
      import shapefile
      import json
      writer = shapefile.Writer(safe_path)
      for f in json.loads(fields_json):
          writer.field(*f)
      for rec in json.loads(records_json):
          writer.record(*rec)
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

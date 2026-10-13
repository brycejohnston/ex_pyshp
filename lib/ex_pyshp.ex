defmodule ExPyshp do
  @moduledoc """
  Read, write and package shapefiles from Elixir.

  Rows contain a `"record"` map and a `"geometry"` Geo struct. Reading also returns
  WKT, source projection metadata, encoding and the original geometry. Null shapes
  are retained as `nil`, not silently removed.

  Writing supports valid XY points, multipoints, lines and polygons, including
  multipart polygons and holes. Written geometry and DBF attributes are verified
  before files are published. Existing output is never overwritten.

  Configure Pythonx in the consuming application with pyshp, Shapely and pyproj.
  The library does not replace the application's Python environment. See the
  README for configuration. ZIP helpers do not require Python.
  """

  alias ExPyshp.{Archive, Files, Runtime}

  @typedoc """
  A row with `"record"` attributes and a `"geometry"` Geo struct.
  Reading a NULL shape returns nil geometry.
  """
  @type row :: %{required(String.t()) => term()}
  @typedoc "Paths returned by `write/4`; `:prj` is nil when the output projection is unknown."
  @type files :: %{
          shp: Path.t(),
          shx: Path.t(),
          dbf: Path.t(),
          prj: Path.t() | nil,
          cpg: Path.t()
        }
  @typedoc """
  Paths for one shapefile extracted from a ZIP.

  Optional PRJ and CPG paths are nil when absent. Every group from the same ZIP
  shares `:extraction_dir`, which owns all files created by that extraction.
  """
  @type extracted_files :: %{
          shp: Path.t(),
          shx: Path.t(),
          dbf: Path.t(),
          prj: Path.t() | nil,
          cpg: Path.t() | nil,
          extraction_dir: Path.t()
        }
  @read_options ~w(source_crs target_crs reproject require_projection discover cpg encoding)a
  @write_options ~w(numeric_precision numeric_width field_types projection_srid projection_wkt encoding verify max_file_size)a

  @doc """
  Read a shapefile from its SHP, DBF and SHX paths.

  Returns `{:ok, name, rows}` or `{:error, name, message}`, where `name` is the
  SHP filename without its extension. Each row includes a `"record"` map, a
  `"geometry"` Geo struct and `"wkt"`. NULL shapes have nil geometry and WKT.

  Matching PRJ and CPG files are found automatically, including uppercase
  extensions. Known source projections are converted to WGS84 by default.
  An unknown source keeps its coordinates and has nil projection/SRID metadata.
  Missing files, invalid projection declarations and failed transforms return
  an error rather than labeling unchanged coordinates with a different SRID.

  ## Options

  Pass options as the fourth argument, or supply a PRJ path and options through
  `read/5`:

  * `:source_crs` — an explicit source, such as `5070` or `"EPSG:5070"`.
    Must agree with a supplied or discovered PRJ.
  * `:target_crs` — the output coordinate system; defaults to WGS84 (`4326`).
    Requires a known source. Ignored when `:reproject` is false.
  * `:reproject` — set to false to retain source coordinates. Defaults to true.
  * `:require_projection` — reject unknown source projections. Defaults to false.
  * `:discover` — discover matching PRJ/CPG files. Defaults to true.
  * `:cpg` — the path to an explicit encoding file.
  * `:encoding` — the DBF encoding; overrides CPG, otherwise defaults to UTF-8.

  ## Returned metadata

  `"projection_srid"` and `"projection_wkt"` describe the source. `"geometry_srid"`
  and `"geometry_crs"` describe the returned XY coordinates. A known projection
  without an EPSG code retains its WKT even when its numeric SRID is nil.
  `"original_geometry"` contains the source XY geometry as a GeoJSON map.
  `"encoding"` and `"shape_type"` identify the input encoding and shapefile type.

  Source Z/M observations remain in `"z_values"` and `"m_values"` when available;
  they are not transformed with XY coordinates. Date attributes become ISO date
  strings. Reading does not repair source geometry.

  ## Examples

  ```elixir
  {:ok, name, rows} = ExPyshp.read("features.shp", "features.dbf", "features.shx")

  ExPyshp.read("features.shp", "features.dbf", "features.shx",
    source_crs: 3857,
    target_crs: 4326
  )
  ```
  """
  @doc group: "Shapefiles"
  @spec read(Path.t(), Path.t(), Path.t(), Path.t() | keyword() | nil) ::
          {:ok, String.t(), [row()]} | {:error, String.t(), String.t()}
  def read(shp, dbf, shx, projection_or_options \\ nil)

  def read(shp, dbf, shx, options) when is_list(options),
    do: read(shp, dbf, shx, nil, options)

  def read(shp, dbf, shx, projection), do: read(shp, dbf, shx, projection, [])

  @doc """
  Read a shapefile with an explicit PRJ path and options.

  Uses the options and return values documented in `read/4`. A nil PRJ path
  allows automatic discovery unless `:discover` is false.

  ## Examples

  ```elixir
  {:ok, name, rows} =
    ExPyshp.read("features.shp", "features.dbf", "features.shx", "features.prj",
      reproject: false
    )
  ```
  """
  @doc group: "Shapefiles"
  @spec read(Path.t(), Path.t(), Path.t(), Path.t() | nil, keyword()) ::
          {:ok, String.t(), [row()]} | {:error, String.t(), String.t()}
  def read(shp, dbf, shx, projection, opts) do
    name = Path.basename(shp, Path.extname(shp))

    with {:ok, opts} <- options(opts, @read_options),
         {:ok, rows} <-
           Runtime.call(:read, Map.merge(opts, %{shp: shp, dbf: dbf, shx: shx, prj: projection})) do
      {:ok, name, Enum.map(rows, &decode_row/1)}
    else
      {:error, message} -> {:error, name, message}
    end
  rescue
    error -> {:error, Path.basename(shp), Exception.message(error)}
  end

  @doc """
  Write shapefile components from rows of attributes and Geo geometry.

  Returns `{:ok, files}` with `:shp`, `:shx`, `:dbf` and `:cpg` paths, plus `:prj`
  when the output projection is known. Failures return `{:error, message}`.
  Wait for this result before opening the file set. Existing output requires a
  new name; a failed attempt preserves earlier files.

  Each row needs a `"record"` map with string field names and a `"geometry"`
  Geo struct. Geometry must be valid, nonempty and two-dimensional. A shapefile
  contains one family: points, multipoints, lines or polygons. Single and
  multipart lines/polygons may share a file. Polygon borders and holes retain
  their coordinates and are written in the directions required by shapefiles.

  ## Options

  * `:numeric_precision` — decimals for inferred numeric fields; defaults to 3.
  * `:numeric_width` — total width for inferred numeric fields; defaults to 18.
    The sign and decimal point use part of this width.
  * `:field_types` — field names mapped to `:string`, `:number`, `:integer`,
    `:boolean` or `:date`, or maps with `:type`, `:width` and `:decimals`.
    Inference checks all nonnil values. Text width fits the longest encoded
    value; numeric-looking strings stay text. Use an explicit type for all-nil
    columns or numeric values supplied as strings.
  * `:projection_srid` / `:projection_wkt` — output projection declarations.
    Must agree with known geometry SRIDs and with each other. Without an explicit
    declaration, a shared known SRID supplies the PRJ. Fully unknown geometry
    has no PRJ; mixing known and unknown SRIDs needs an explicit declaration.
    Writing does not transform coordinates.
  * `:encoding` — defaults to UTF-8. A CPG is always written.
  * `:verify` — reopen completed files to check geometry, field definitions,
    projection, encoding and attributes. Defaults to true. Setting false skips
    readback while retaining input validation.
  * `:max_file_size` — a per-component limit from 1 byte through 2 GiB.
    Defaults to 2 GiB.

  ## Format limits

  Output names are single filename segments of at most 251 bytes. The destination
  filesystem must support hard links. Prepared files remain temporary until
  validation succeeds; failures clean only this attempt's working files.

  DBF names must be unique without case and contain at most 10 visible ASCII
  bytes, without leading or trailing spaces. A file supports at most 255 fields
  and a 4,000-byte record width. Text widths are 1–254 bytes; numeric widths are
  1–32 bytes with 0–15 decimals. Overflow and text truncation return errors.
  Nil numeric values and zero remain distinct in library readback; external
  readers may treat DBF nulls differently.

  ## Examples

  ```elixir
  rows = [
    %{
      "record" => %{"ID" => "1", "VALUE" => 12.3456},
      "geometry" => %Geo.Point{coordinates: {1.0, 2.0}, srid: 4326}
    }
  ]

  {:ok, files} = ExPyshp.write("output", "features", rows, numeric_precision: 4)

  ExPyshp.write("output", "typed_features", rows,
    field_types: %{
      "ID" => :string,
      "VALUE" => %{type: :number, width: 20, decimals: 4}
    }
  )
  ```
  """
  @doc group: "Shapefiles"
  @spec write(Path.t(), String.t(), [row()], keyword()) :: {:ok, files()} | {:error, String.t()}
  def write(directory, name, data, opts \\ []) do
    with :ok <- Files.validate_name(name),
         {:ok, opts} <- options(opts, @write_options),
         {:ok, rows} <- encode_rows(data),
         :ok <- Files.mkdir(directory) do
      destination = Path.expand(directory)

      :global.trans({{__MODULE__, destination, name}, self()}, fn ->
        Files.with_temp_dir(destination, &write_prepared(&1, destination, name, rows, opts))
      end)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Extract complete shapefile groups into a new temporary directory.

  Returns `{:ok, groups}` or `{:error, message}`. Each group contains SHP, SHX and
  DBF paths, optional PRJ/CPG paths, and `:extraction_dir`. Missing optional paths
  are nil. Groups match by directory and filename, so equal names in different
  ZIP folders stay separate.

  The caller owns successful output and must remove `:extraction_dir` after use.
  All groups share that directory. `with_extract/2` handles cleanup automatically.
  Incomplete groups, ambiguous companions, unsafe ZIP paths, checksum failures
  and exceeded size limits return errors and remove failed extraction files.

  ## Options

  * `:max_entries` — ZIP entry count; defaults to 10,000.
  * `:max_file_size` — uncompressed bytes per file; defaults to 128 MiB.
  * `:max_uncompressed_size` — total uncompressed bytes; defaults to 512 MiB.
  * `:temporary_directory` — parent for the working directory; defaults to the
    system temporary directory.

  Size/count limits must be positive integers. Extraction does not read or
  validate shapefile contents; pass the returned paths to `read/5` for that.

  ## Examples

  ```elixir
  {:ok, [group | _]} = ExPyshp.extract("features.zip")
  result = ExPyshp.read(group.shp, group.dbf, group.shx, group.prj)
  File.rm_rf!(group.extraction_dir)
  ```
  """
  @doc group: "ZIP files"
  @spec extract(Path.t(), keyword()) :: {:ok, [extracted_files()]} | {:error, String.t()}
  defdelegate extract(path, opts \\ []), to: Archive

  @doc """
  Extract a ZIP, pass its shapefile groups to a callback, then clean up.

  Returns the callback result unchanged. Extraction failures return
  `{:error, message}` without calling the callback. Callback exceptions propagate
  after cleanup. The extracted paths cannot be used after the callback returns.
  Cleanup also runs if the caller exits during the callback.

  Uses the default options from `extract/2`. See `with_extract/3` to change them.

  ## Examples

  ```elixir
  ExPyshp.with_extract("features.zip", fn groups ->
    Enum.map(groups, fn group ->
      ExPyshp.read(group.shp, group.dbf, group.shx, group.prj)
    end)
  end)
  ```
  """
  @doc group: "ZIP files"
  @spec with_extract(Path.t(), ([extracted_files()] -> result)) :: result | {:error, String.t()}
        when result: term()
  def with_extract(path, fun) when is_function(fun, 1), do: Archive.with_extract(path, [], fun)

  @doc """
  Extract a ZIP with options and clean up after the callback.

  Accepts the options from `extract/2`. Returns and exception handling are the
  same as `with_extract/2`.

  ## Examples

  ```elixir
  ExPyshp.with_extract("features.zip", [max_file_size: 64 * 1024 * 1024], fn groups ->
    Enum.map(groups, &ExPyshp.read(&1.shp, &1.dbf, &1.shx, &1.prj))
  end)
  ```
  """
  @doc group: "ZIP files"
  @spec with_extract(Path.t(), keyword(), ([extracted_files()] -> result)) ::
          result | {:error, String.t()}
        when result: term()
  defdelegate with_extract(path, opts, fun), to: Archive

  @doc """
  ZIP the regular non-ZIP files directly inside a directory.

  Returns `{:ok, zip_path}` or `{:error, message}`. The ZIP is saved in the same
  directory as `name.zip`; input files remain in place. Existing archives are
  not replaced. Use `archive/3` to select particular files.

  ## Examples

  ```elixir
  {:ok, zip_path} = ExPyshp.archive("output", "features")
  ```
  """
  @doc group: "ZIP files"
  @spec archive(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  defdelegate archive(directory, name), to: Archive

  @doc """
  ZIP selected files using their basenames as ZIP entry names.

  Paths may be absolute or relative to `directory`. At least one file is
  required, and basenames must be unique without case. The archive is saved as
  `name.zip` in `directory`. Returns `{:ok, zip_path}` or `{:error, message}`;
  inputs and existing archives are preserved.

  ## Examples

  ```elixir
  paths = ["features.shp", "features.shx", "features.dbf", "features.prj", "features.cpg"]
  {:ok, zip_path} = ExPyshp.archive("output", "features", paths)
  ```
  """
  @doc group: "ZIP files"
  @spec archive(Path.t(), String.t(), [Path.t()]) :: {:ok, Path.t()} | {:error, String.t()}
  defdelegate archive(directory, name, files), to: Archive

  @doc """
  Write a shapefile ZIP, pass its path to a callback, then remove temporary files.

  Uses the default options from `write/4`. Returns the callback result unchanged,
  or `{:error, message}` if writing or archiving fails. Copy or upload the ZIP
  inside the callback if it needs to survive this call. Callback exceptions
  propagate after cleanup; caller exit also removes this attempt's directory.

  See `with_archive/4` to choose write options or a temporary parent directory.

  ## Examples

  ```elixir
  ExPyshp.with_archive("features", rows, fn zip_path ->
    File.cp(zip_path, "/delivery/features.zip")
  end)
  ```
  """
  @doc group: "ZIP files"
  @spec with_archive(String.t(), [row()], (Path.t() -> result)) :: result | {:error, String.t()}
        when result: term()
  def with_archive(name, data, fun) when is_function(fun, 1),
    do: with_archive(name, data, [], fun)

  @doc """
  Build a temporary shapefile ZIP with options and callback cleanup.

  Accepts the options from `write/4` plus `:temporary_directory`, which defaults
  to the system temporary directory. Returns and exception handling are the
  same as `with_archive/3`. Writing and archiving errors skip the callback.

  ## Examples

  ```elixir
  ExPyshp.with_archive("features", rows, [numeric_precision: 4], fn zip_path ->
    File.cp(zip_path, "/delivery/features.zip")
  end)
  ```
  """
  @doc group: "ZIP files"
  @spec with_archive(String.t(), [row()], keyword(), (Path.t() -> result)) ::
          result | {:error, String.t()}
        when result: term()
  def with_archive(name, data, opts, fun) when is_function(fun, 1) do
    {parent, opts} = Keyword.pop(opts, :temporary_directory, System.tmp_dir!())
    Files.with_temp_dir(parent, &consume_archive(&1, name, data, opts, fun))
  end

  defp consume_archive(directory, name, data, opts, fun) do
    with {:ok, files} <- write(directory, name, data, opts),
         {:ok, zip} <- archive(directory, name, files |> Map.values() |> Enum.reject(&is_nil/1)) do
      fun.(zip)
    end
  end

  @doc """
  Return the versions used by the configured Python interpreter.

  Returns `{:ok, versions}` with string keys `"python"`, `"pyshp"`, `"shapely"`
  and `"pyproj"`, or `{:error, message}` if the interpreter cannot run the query.
  These are the loaded versions, not versions from a separate shell Python.

  ## Examples

      iex> {:ok, versions} = ExPyshp.runtime_info()
      iex> Enum.all?(~w(python pyshp shapely pyproj), &is_binary(versions[&1]))
      true
  """
  @doc group: "Runtime"
  @spec runtime_info() :: {:ok, map()} | {:error, String.t()}
  def runtime_info, do: Runtime.call(:info, %{})

  defp write_prepared(temporary, destination, name, rows, opts) do
    base = Path.join(temporary, "shape")

    with :ok <- Files.ensure_unused(destination, name),
         {:ok, true} <- Runtime.call(:write, %{path: base, data: rows, options: opts}),
         :ok <- Files.check_sizes(temporary, Map.get(opts, :max_file_size, 2_147_483_648)) do
      Files.publish(temporary, destination, name)
    end
  end

  defp decode_row(%{"geometry" => nil} = row), do: Map.put(row, "wkt", nil)

  defp decode_row(row) do
    geometry = Geo.JSON.decode!(row["geometry"])
    geometry = %{geometry | srid: row["geometry_srid"]}
    row |> Map.put("geometry", geometry) |> Map.put("wkt", Geo.WKT.encode!(geometry))
  end

  defp encode_rows([]), do: {:error, "A shapefile needs at least one complete record"}

  defp encode_rows(rows) when is_list(rows) do
    {:ok,
     Enum.map(rows, fn
       %{"record" => record, "geometry" => geometry}
       when is_map(record) and is_struct(geometry) ->
         if not Enum.all?(Map.keys(record), &is_binary/1),
           do: raise(ArgumentError, "Record field names must be strings")

         %{record: record, geometry: Geo.JSON.encode!(geometry), srid: Map.get(geometry, :srid)}

       _ ->
         raise ArgumentError, "Each row needs a record map and a Geo geometry struct"
     end)}
  end

  defp encode_rows(_), do: {:error, "Data must be a list of shapefile rows"}

  defp options(opts, allowed) do
    case Keyword.validate(opts, allowed) do
      {:ok, opts} -> {:ok, Map.new(opts)}
      {:error, names} -> {:error, "Unknown options: #{Enum.map_join(names, ", ", &to_string/1)}"}
    end
  end
end

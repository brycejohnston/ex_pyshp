defmodule ExPyshp.Archive do
  @moduledoc """
  ZIP creation and extraction for `ExPyshp`.

  Shapefile companions are grouped by directory and filename. Extraction checks
  entry paths, file counts and uncompressed sizes before creating output. ZIP
  creation copies chosen files into a separate working directory and preserves
  the originals.

  Applications can use `ExPyshp.archive/3` and `ExPyshp.with_extract/3` directly.
  """
  alias ExPyshp.Files
  @extensions ~w(.shp .shx .dbf .prj .cpg)
  @required ~w(shp shx dbf)
  @defaults [max_entries: 10_000, max_file_size: 134_217_728, max_uncompressed_size: 536_870_912]

  @doc """
  Extract complete shapefile groups into a separate temporary directory.

  Returns `{:ok, groups}` or `{:error, message}`. Groups include SHP/SHX/DBF,
  optional PRJ/CPG paths and the shared extraction directory. The caller owns
  successful output; failed extraction removes this attempt's files.
  See `ExPyshp.extract/2` for size limits and options.
  """
  @spec extract(Path.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def extract(path, opts) do
    with {:ok, limits, parent} <- options(opts),
         {:ok, entries} <- inspect_zip(path, limits),
         directory = Files.temporary_directory(parent),
         :ok <- Files.mkdir(directory) do
      extract_owned(path, entries, directory, limits)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp extract_owned(path, entries, directory, limits) do
    case extract_into(path, entries, directory, limits) do
      {:ok, _} = result ->
        result

      {:error, _} = error ->
        File.rm_rf(directory)
        error
    end
  rescue
    error ->
      File.rm_rf(directory)
      {:error, Exception.message(error)}
  end

  @doc """
  Extract an archive, pass its groups to `fun`, then remove the extracted files.

  Returns the callback result or an extraction error. Callback exceptions are
  reraised after cleanup. Uses the options described by `ExPyshp.extract/2`.
  """
  @spec with_extract(Path.t(), keyword(), ([map()] -> result)) ::
          result | {:error, String.t()}
        when result: term()
  def with_extract(path, opts, fun) do
    with {:ok, limits, parent} <- options(opts),
         {:ok, entries} <- inspect_zip(path, limits) do
      Files.with_temp_dir(parent, fn directory ->
        apply_extracted(path, entries, directory, limits, fun)
      end)
    end
  end

  @doc """
  ZIP the regular non-ZIP files directly inside `directory`.

  Returns `{:ok, zip_path}` or `{:error, message}`. Inputs remain in place and
  existing archives are preserved. Use `archive/3` to choose specific files.
  """
  @spec archive(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def archive(directory, name) do
    case File.ls(directory) do
      {:ok, names} ->
        files = Enum.filter(names, &archive_input?(directory, &1))
        archive(directory, name, files)

      {:error, reason} ->
        {:error, "Cannot read archive directory: #{:file.format_error(reason)}"}
    end
  end

  defp archive_input?(directory, name),
    do:
      File.regular?(Path.join(directory, name)) and String.downcase(Path.extname(name)) != ".zip"

  @doc """
  ZIP selected paths using their basenames as entry names.

  Relative paths are resolved against `directory`; absolute paths are accepted.
  Basenames must be unique without case. Returns `{:ok, zip_path}` or
  `{:error, message}` without removing inputs or replacing an existing archive.
  """
  @spec archive(Path.t(), String.t(), [Path.t()]) :: {:ok, Path.t()} | {:error, String.t()}
  def archive(directory, name, paths) do
    with :ok <- Files.validate_name(name),
         {:ok, sources} <- archive_sources(directory, paths),
         :ok <- Files.mkdir(directory) do
      destination = Path.join(Path.expand(directory), "#{name}.zip")

      Files.with_temp_dir(Path.expand(directory), &create_archive(&1, sources, destination))
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp create_archive(temporary, sources, destination) do
    archive = Path.join(temporary, "package.zip")

    with :ok <- copy_sources(sources, temporary),
         {:ok, _} <-
           :zip.create(
             String.to_charlist(archive),
             Enum.map(sources, &String.to_charlist(Path.basename(&1))),
             cwd: String.to_charlist(temporary)
           ),
         {:ok, entries} <- :zip.table(String.to_charlist(archive)),
         true <- length(entries) == length(sources) + 1,
         :ok <- File.ln(archive, destination) do
      {:ok, destination}
    else
      false -> {:error, "ZIP verification found a different file count"}
      {:error, reason} -> {:error, "Cannot create archive: #{zip_error(reason)}"}
    end
  end

  defp options(opts) do
    case Keyword.validate(opts, Keyword.keys(@defaults) ++ [:temporary_directory]) do
      {:ok, opts} -> extraction_limits(opts)
      {:error, keys} -> {:error, "Unknown extraction options: #{inspect(keys)}"}
    end
  end

  defp extraction_limits(opts) do
    limits = Keyword.merge(@defaults, opts) |> Keyword.delete(:temporary_directory)

    if Enum.all?(limits, fn {_, value} -> is_integer(value) and value > 0 end),
      do: {:ok, limits, Keyword.get(opts, :temporary_directory, System.tmp_dir!())},
      else: {:error, "ZIP size/count limits must be positive integers"}
  end

  defp apply_extracted(path, entries, directory, limits, fun) do
    with {:ok, groups} <- extract_into(path, entries, directory, limits), do: fun.(groups)
  end

  defp inspect_zip(path, limits) do
    case :zip.table(String.to_charlist(path)) do
      {:ok, rows} ->
        entries =
          for {:zip_file, name, info, _, _, _} <- rows,
              do: {to_string(name), File.Stat.from_record(info)}

        validate_entries(entries, limits)

      {:error, reason} ->
        {:error, "Cannot read ZIP: #{zip_error(reason)}"}
    end
  end

  defp zip_error(reason) when is_atom(reason), do: to_string(:file.format_error(reason))
  defp zip_error(_), do: "invalid or unsupported archive"

  defp validate_entries(entries, limits) do
    names =
      Enum.map(entries, fn {name, _} -> String.downcase(String.trim_trailing(name, "/")) end)

    cond do
      entries == [] ->
        {:error, "ZIP archive is empty"}

      length(entries) > limits[:max_entries] ->
        {:error, "ZIP exceeds max_entries (#{limits[:max_entries]})"}

      Enum.any?(entries, fn {name, info} ->
        not safe_entry?(name) or info.type not in [:regular, :directory]
      end) ->
        {:error, "ZIP contains an unsafe path or unsupported file type"}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "ZIP contains duplicate entry paths"}

      Enum.any?(entries, fn {_, info} -> info.size > limits[:max_file_size] end) ->
        {:error, "ZIP entry exceeds max_file_size (#{limits[:max_file_size]} bytes)"}

      Enum.sum(Enum.map(entries, fn {_, info} -> info.size end)) > limits[:max_uncompressed_size] ->
        {:error, "ZIP exceeds max_uncompressed_size (#{limits[:max_uncompressed_size]} bytes)"}

      true ->
        {:ok, entries}
    end
  end

  defp safe_entry?(name) do
    name != "" and Path.type(name) == :relative and
      not String.contains?(name, ["\\", "\0"]) and
      not Regex.match?(~r/^[A-Za-z]:/, name) and
      Enum.all?(String.split(name, "/", trim: true), &(&1 not in [".", ".."]))
  end

  defp extract_into(path, entries, directory, limits) do
    case :zip.extract(String.to_charlist(path), cwd: String.to_charlist(directory)) do
      {:ok, _} ->
        validate_extracted(entries, directory, limits)

      {:error, {entry, :bad_crc}} ->
        {:error, "ZIP checksum failed for #{to_string(entry)}; recreate the archive"}

      {:error, reason} ->
        {:error, "Cannot extract ZIP: #{zip_error(reason)}"}
    end
  end

  defp validate_extracted(entries, directory, limits) do
    with :ok <- check_extracted(entries, directory, limits), do: groups(directory)
  end

  defp check_extracted(entries, directory, limits) do
    if Enum.all?(entries, &extracted_entry?(&1, directory, limits[:max_file_size])),
      do: :ok,
      else: {:error, "Extracted files do not match the ZIP directory or size limits"}
  end

  defp extracted_entry?({name, expected}, directory, limit) do
    case File.lstat(Path.join(directory, name)) do
      {:ok, actual} ->
        actual.type == expected.type and
          (actual.type == :directory or (actual.size <= limit and actual.size == expected.size))

      {:error, _} ->
        false
    end
  end

  defp groups(directory) do
    paths = Path.wildcard(Path.join(directory, "**/*"), match_dot: true)

    grouped =
      paths
      |> Enum.filter(&(File.regular?(&1) and String.downcase(Path.extname(&1)) in @extensions))
      |> Enum.reject(
        &("__MACOSX" in Path.split(&1) or String.starts_with?(Path.basename(&1), "._"))
      )
      |> Enum.group_by(&{Path.dirname(&1), String.downcase(Path.rootname(Path.basename(&1)))})
      |> Enum.sort_by(&elem(&1, 0))

    Enum.reduce_while(grouped, {:ok, []}, fn {{_, name}, paths}, {:ok, collected} ->
      extensions = Enum.map(paths, &String.downcase(Path.extname(&1)))

      cond do
        length(extensions) != length(Enum.uniq(extensions)) ->
          {:halt, {:error, "Duplicate shapefile companions for #{name}"}}

        not Enum.all?(@required, &(".#{&1}" in extensions)) ->
          {:halt, {:error, "Incomplete shapefile group #{name}; SHP, SHX and DBF are required"}}

        true ->
          group = Map.new(paths, &{extension_key(&1), &1})
          group = Map.merge(%{prj: nil, cpg: nil, extraction_dir: directory}, group)
          {:cont, {:ok, [group | collected]}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "No shapefile groups found in ZIP"}
      {:ok, groups} -> {:ok, Enum.reverse(groups)}
      error -> error
    end
  end

  defp extension_key(path) do
    case String.downcase(Path.extname(path)) do
      ".shp" -> :shp
      ".shx" -> :shx
      ".dbf" -> :dbf
      ".prj" -> :prj
      ".cpg" -> :cpg
    end
  end

  defp archive_sources(directory, paths) when is_list(paths) and paths != [] do
    sources = Enum.map(paths, &Path.expand(&1, directory))
    names = Enum.map(sources, &(Path.basename(&1) |> String.downcase()))

    cond do
      not Enum.all?(sources, &File.regular?/1) ->
        {:error, "An archive input file is missing or not a regular file"}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "Archive file basenames must be unique"}

      true ->
        {:ok, sources}
    end
  end

  defp archive_sources(_, _), do: {:error, "Choose at least one file to archive"}

  defp copy_sources(sources, directory) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      case File.cp(source, Path.join(directory, Path.basename(source))) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end

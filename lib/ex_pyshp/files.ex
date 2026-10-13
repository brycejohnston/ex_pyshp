defmodule ExPyshp.Files do
  @moduledoc """
  File preparation and temporary-directory cleanup for `ExPyshp`.

  Each write attempt uses its own working directory. Completed components are
  linked into the destination without replacing existing files. If a later link
  fails, links created by that attempt are removed.

  `with_temp_dir/2` provides cleanup on return, exception or caller exit. A
  whole-VM or host crash still needs ordinary temporary-file maintenance.
  """
  @extensions ~w(shp shx dbf prj cpg)

  @doc """
  Check that an output name is a single filename segment of at most 251 bytes.

  Returns `:ok` or `{:error, message}`. Empty names, directory paths, null bytes
  and line breaks are rejected. The limit leaves room for a four-byte extension.
  """
  @spec validate_name(term()) :: :ok | {:error, String.t()}
  def validate_name(name) when is_binary(name) do
    if name != "" and name not in [".", ".."] and byte_size(name) <= 251 and
         not String.contains?(name, ["/", "\\", "\0", "\n", "\r"]),
       do: :ok,
       else: {:error, "Name must be a filename without a directory, at most 251 bytes"}
  end

  def validate_name(_), do: {:error, "Name must be a string"}

  @doc """
  Create a directory and any missing parents.

  Returns `:ok` or `{:error, message}` with a readable filesystem error.
  """
  @spec mkdir(Path.t()) :: :ok | {:error, String.t()}
  def mkdir(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot create directory: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Generate a temporary directory path beneath `parent`.

  The directory is not created. A random suffix keeps separate attempts apart.
  """
  @spec temporary_directory(Path.t()) :: Path.t()
  def temporary_directory(parent) do
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Path.join(parent, ".ex_pyshp-#{token}")
  end

  @doc """
  Create a temporary directory, call `fun` with its path, then remove it.

  Returns the callback result, or `{:error, message}` if the directory cannot be
  created. Callback exceptions propagate after cleanup. A monitor also removes
  this directory if the caller exits before the cleanup block runs.
  """
  @spec with_temp_dir(Path.t(), (Path.t() -> result)) :: result | {:error, String.t()}
        when result: term()
  def with_temp_dir(parent, fun) do
    directory = temporary_directory(parent)

    with :ok <- mkdir(directory) do
      guard = monitor_cleanup(self(), directory)

      try do
        fun.(directory)
      after
        File.rm_rf(directory)
        send(guard, :released)
      end
    end
  end

  defp monitor_cleanup(owner, directory) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :released -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^owner, _} -> File.rm_rf(directory)
      end
    end)
  end

  @doc """
  Check that no shapefile component already uses `name` in `directory`.

  Checks SHP, SHX, DBF, PRJ and CPG paths. Returns `:ok` or `{:error, message}`.
  This is an early check; `publish/3` also refuses to replace existing files.
  """
  @spec ensure_unused(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def ensure_unused(directory, name) do
    if Enum.any?(@extensions, &File.exists?(Path.join(directory, "#{name}.#{&1}"))),
      do: {:error, "Output files already exist for #{name}; choose another name"},
      else: :ok
  end

  @doc """
  Check prepared output files against a per-file byte limit.

  Returns `:ok` or `{:error, message}` for an oversized file or an invalid limit.
  Limits must be between 1 and 2 GiB. Directory and file-stat failures raise
  `File.Error` so the calling write operation can report the filesystem problem.
  """
  @spec check_sizes(Path.t(), term()) :: :ok | {:error, String.t()}
  def check_sizes(directory, limit)
      when is_integer(limit) and limit > 0 and limit <= 2_147_483_648 do
    if Enum.all?(File.ls!(directory), &(File.stat!(Path.join(directory, &1)).size <= limit)),
      do: :ok,
      else: {:error, "A shapefile component exceeds max_file_size (#{limit} bytes)"}
  end

  def check_sizes(_, _), do: {:error, "max_file_size must be between 1 and 2147483648 bytes"}

  # Hard links refuse to replace existing files. The file set is ready only
  # after every component is linked; a later failure removes links created here.
  @doc """
  Link prepared `shape.*` components into `destination` under `name`.

  The destination directory must exist. Returns `{:ok, paths}` with component
  keys and nil for missing components, or `{:error, message}`. Existing files
  are never replaced. If a later link fails, only links created by this call are
  removed; prepared source files remain available to the caller.
  """
  @spec publish(Path.t(), Path.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def publish(source, destination, name) do
    entries =
      for extension <- @extensions,
          file = Path.join(source, "shape.#{extension}"),
          File.exists?(file),
          do: {extension, file, Path.join(destination, "#{name}.#{extension}")}

    result =
      Enum.reduce_while(entries, {:ok, []}, fn {extension, source, target}, {:ok, created} ->
        case File.ln(source, target) do
          :ok -> {:cont, {:ok, [{extension, target} | created]}}
          {:error, reason} -> {:halt, {:error, reason, created}}
        end
      end)

    case result do
      {:ok, created} ->
        defaults = Map.new(@extensions, &{String.to_existing_atom(&1), nil})

        paths =
          Map.new(created, fn {extension, path} -> {String.to_existing_atom(extension), path} end)

        {:ok, Map.merge(defaults, paths)}

      {:error, reason, created} ->
        Enum.each(created, fn {_, file} -> File.rm(file) end)
        {:error, "Cannot publish shapefile files: #{:file.format_error(reason)}"}
    end
  end
end

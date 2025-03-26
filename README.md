# ExPyshp

Read and write shapefiles using [pyshp](https://github.com/GeospatialPython/pyshp) from Elixir with [pythonx](https://github.com/livebook-dev/pythonx).

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ex_pyshp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_pyshp, "~> 0.1.0"}
  ]
end
```

Example read from zip
```elixir
# Capture the extraction result from the ZIP file
extraction_result = ExPyshp.extract("shp.zip")

# Process the extraction result and read each shapefile group
shapefile_results =
  case extraction_result do
    {:ok, shapefile_pairs} ->
      # For each shapefile group, call read and capture the result in a list
      Enum.map(shapefile_pairs, fn %{shp: shp_path, dbf: dbf_path, shx: shx_path} ->
        case ExPyshp.read(shp_path, dbf_path, shx_path) do
          {:ok, base_name, data} -> {:ok, base_name, data}
          {:error, base_name, reason} -> {:error, base_name, reason}
        end
      end)

    {:error, reason} ->
      IO.puts("Error extracting shapefiles: #{reason}")
      []
  end

# Process and inspect each result:
Enum.each(shapefile_results, fn
  {:ok, base_name, shapefile_data} ->
    IO.inspect(shapefile_data, label: "Shapefile data from #{base_name}")
  {:error, base_name, reason} ->
    IO.puts("Error reading shapefile for #{base_name}: #{reason}")
end)

# You can further filter for successful results if needed:
successful_results =
  shapefile_results
  |> Enum.filter(fn
    {:ok, _, _} -> true
    _ -> false
  end)

IO.inspect(successful_results, label: "Successful shapefile results")
```
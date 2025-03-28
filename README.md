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

## Usage

### Reading

```elixir
# Extract from the ZIP file and get list of files
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
```

### Writing

```elixir
data = [
  %{
    "record" => %{"name" => "Feature1", "value" => 123},
    "geometry" => %Geo.Point{coordinates: {1.0, 2.0}}
  },
  %{
    "record" => %{"name" => "Feature2", "value" => 456},
    "geometry" => %Geo.Point{coordinates: {3.0, 4.0}}
  }
]

ExPyshp.write("output_path", "name", data)
```
# ExPyshp

[![Hex.pm version](https://img.shields.io/hexpm/v/ex_pyshp.svg)](https://hex.pm/packages/ex_pyshp)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ex_pyshp/)
[![Hex.pm downloads](https://img.shields.io/hexpm/dt/ex_pyshp.svg)](https://hex.pm/packages/ex_pyshp)
[![License](https://img.shields.io/hexpm/l/ex_pyshp.svg)](https://hex.pm/packages/ex_pyshp)

Read, write and ZIP shapefiles from Elixir or Phoenix applications using [pyshp](https://github.com/GeospatialPython/pyshp).

## Installation

Requires Elixir 1.20 or later. Add ExPyshp to your dependencies in `mix.exs`:

```elixir
{:ex_pyshp, "~> 0.2.0"}
```

Configure [Pythonx](https://github.com/livebook-dev/pythonx) in your application's `config/config.exs`, then run `mix deps.get`:

```elixir
import Config

config :pythonx, :uv_init,
  uv_version: "0.13.0",
  pyproject_toml: """
  [project]
  name = "my-app"
  version = "0.1.0"
  requires-python = "==3.13.*"
  dependencies = [
    "pyshp==3.1.6",
    "shapely==2.2.0",
    "pyproj==3.8.0",
  ]
  """
```

If your application already configures Pythonx, add these Python packages to its existing configuration.

## Reading

```elixir
{:ok, name, rows} = ExPyshp.read("features.shp", "features.dbf", "features.shx")
```

Each row contains its attributes in `"record"` and a [Geo](https://hexdocs.pm/geo) struct in `"geometry"`.

If a matching `.prj` file exists, it is used automatically. You can also pass its path:

```elixir
{:ok, name, rows} =
  ExPyshp.read("features.shp", "features.dbf", "features.shx", "features.prj")
```

Coordinates from a known projection are converted to WGS84. To keep the original coordinates:

```elixir
ExPyshp.read("features.shp", "features.dbf", "features.shx", "features.prj",
  reproject: false)
```

Reading returns `{:error, name, message}` if it fails.

## Writing

```elixir
rows = [
  %{
    "record" => %{"ID" => "1", "NAME" => "Feature1", "VALUE" => 123.4567},
    "geometry" => %Geo.Point{coordinates: {1.0, 2.0}, srid: 4326}
  }
]

{:ok, files} = ExPyshp.write("output", "features", rows, numeric_precision: 4)
```

The returned paths are `files.shp`, `files.shx`, `files.dbf`, `files.prj` and `files.cpg`. The geometry's SRID supplies the `.prj` file; you can also set `projection_srid: 4326` explicitly.

Field names are limited to 10 ASCII characters. Writing returns `{:error, message}` if it fails, and existing files are not overwritten.

## ZIP files

Create a ZIP from the generated files:

```elixir
paths = files |> Map.values() |> Enum.reject(&is_nil/1)
{:ok, zip_path} = ExPyshp.archive("output", "features", paths)
```

Read shapefiles from a ZIP. Extracted files are removed after the callback finishes:

```elixir
ExPyshp.with_extract("features.zip", fn groups ->
  Enum.map(groups, fn group ->
    ExPyshp.read(group.shp, group.dbf, group.shx, group.prj)
  end)
end)
```

For a Phoenix `%Plug.Upload{}`, use `upload.path` in place of `"features.zip"`.

See the [API reference](https://hexdocs.pm/ex_pyshp/ExPyshp.html) for other options and [CHANGELOG.md](CHANGELOG.md) for upgrade notes.

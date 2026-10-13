import Config

config :pythonx, :uv_init,
  uv_version: "0.13.0",
  pyproject_toml: """
  [project]
  name = "ex-pyshp"
  version = "0.2.0"
  requires-python = "==3.13.*"
  dependencies = [
    "pyshp==3.1.6",
    "shapely==2.2.0",
    "pyproj==3.8.0",
  ]
  """

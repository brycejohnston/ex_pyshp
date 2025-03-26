import Config

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "ex_pyshp"
  version = "0.1.0"
  requires-python = "==3.12.*"
  dependencies = [
    "pyshp==2.3.0"
  ]
  """

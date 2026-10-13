defmodule ExPyshp.Python.Dispatch do
  @moduledoc """
  Embedded Python command dispatch for `ExPyshp.Runtime`.

  Routes read, write and version queries to the matching helper and returns a
  JSON result or error message. `code/0` supplies the source for the shared
  runtime; it does not execute a command.
  """

  @code ~S'''
  import json
  import platform

  import pyproj
  import shapefile
  import shapely


  def runtime_info():
      """Return dependency versions from the interpreter currently running these helpers."""
      return {"python": platform.python_version(), "pyshp": shapefile.__version__,
              "shapely": shapely.__version__, "pyproj": pyproj.__version__}


  def ex_pyshp_call(command, payload_json):
      """Run one requested operation and encode its result or error for Elixir."""
      if isinstance(command, bytes):
          command = command.decode()
      try:
          payload = json.loads(payload_json)
          handlers = {"read": read_shapes, "write": write_shapes, "info": lambda _: runtime_info()}
          return json.dumps({"ok": handlers[command](payload)}, default=json_value, allow_nan=False)
      except Exception as error:
          return json.dumps({"error": str(error) or type(error).__name__})
  '''

  @doc """
  Return the embedded Python command dispatcher and dependency-version query.

  `ExPyshp.Runtime` combines this source with the other Python helpers at compile
  time. Calling this function returns a string; it does not execute Python.
  """
  @spec code() :: String.t()
  def code, do: @code
end

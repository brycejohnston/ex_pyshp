defmodule ExPyshp.Runtime do
  @moduledoc """
  Run the Python helpers used by `ExPyshp`.

  `call/2` combines command inputs and results through JSON and serializes these
  calls within each node. It uses the consuming application's configured
  `Pythonx` interpreter. Applications normally call `ExPyshp.read/4` or
  `ExPyshp.write/4` instead.
  """

  @source Enum.join(
            [
              ExPyshp.Python.Geometry.code(),
              ExPyshp.Python.Reader.code(),
              ExPyshp.Python.Writer.code(),
              ExPyshp.Python.Dispatch.code()
            ],
            "\n"
          )

  @doc """
  Run a shapefile read, write or version query in the configured Pythonx interpreter.

  Accepts `:read`, `:write` or `:info` and a JSON-encodable payload map. Returns
  `{:ok, result}` or `{:error, message}`. Calls made through this module are
  serialized per node, including result decoding. The caller's application
  supplies the Python environment.
  """
  @spec call(:read | :write | :info, map()) :: {:ok, term()} | {:error, String.t()}
  def call(command, payload) do
    if Process.whereis(Pythonx.Supervisor) do
      evaluate(command, Jason.encode!(payload))
    else
      {:error,
       "Pythonx is not started. Start its application and configure the Python environment."}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Use each caller's PID as the lock requester. A shared requester ID would let
  # different callers hold this per-node interpreter lock at the same time.
  defp evaluate(command, payload) do
    :global.trans(
      {{__MODULE__, :interpreter}, self()},
      fn ->
        {result, _globals} =
          Pythonx.eval(@source <> "\nex_pyshp_call(command, payload_json)", %{
            "command" => to_string(command),
            "payload_json" => payload
          })

        case result |> Pythonx.decode() |> Jason.decode!() do
          %{"ok" => value} -> {:ok, value}
          %{"error" => message} -> {:error, message}
        end
      end,
      [node()]
    )
  end
end

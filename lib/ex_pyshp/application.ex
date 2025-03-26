defmodule ExPyshp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Additional workers or supervisors can be added here.
    ]

    opts = [strategy: :one_for_one, name: ExPyshp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

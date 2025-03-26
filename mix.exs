defmodule ExPyshp.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pyshp,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ExPyshp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:pythonx, "~> 0.4.4"},
      {:jason, "~> 1.4"},
      {:geo, "~> 4.0"}
    ]
  end
end

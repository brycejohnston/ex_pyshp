defmodule ExPyshp.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pyshp,
      name: "ExPyshp",
      version: "0.2.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Read, write, verify and package shapefiles from Elixir using pyshp.",
      source_url: "https://github.com/brycejohnston/ex_pyshp",
      homepage_url: "https://hexdocs.pm/ex_pyshp",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/brycejohnston/ex_pyshp"},
        files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
      ],
      docs: [
        main: "readme",
        source_ref: "master",
        groups_for_modules: [
          API: [ExPyshp],
          "Internal helpers": ~r/^ExPyshp\./
        ],
        extras: ["README.md", "CHANGELOG.md", {"LICENSE", [title: "License"]}]
      ],
      test_coverage: [ignore_modules: [ExPyshp.TestHelpers]],
      aliases: [
        check: [
          "format --check-formatted",
          "compile --force --warnings-as-errors",
          "credo --strict",
          "test --warnings-as-errors"
        ]
      ],
      deps: deps()
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:pythonx, "~> 0.4.10"},
      {:jason, "~> 1.4.5"},
      {:geo, "~> 4.1"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false, warn_if_outdated: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end

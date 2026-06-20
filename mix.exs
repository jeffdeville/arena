defmodule Arena.MixProject do
  use Mix.Project

  def project do
    [
      app: :arena,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  defp description do
    """
    Process isolation for async Elixir testing. Arena provides each test with its own
    isolated infrastructure (PubSub, Registry, DB connections) enabling true async testing
    for process-heavy applications.
    """
  end

  defp package do
    [
      files: ~w(lib docs .formatter.exs mix.exs README.md AGENTS.md llms.txt CHANGELOG.md),
      licenses: ["MIT"],
      links: %{}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # All optional: Arena's core stays dependency-free. Each integration guards
      # its dep with `Code.ensure_loaded?/1` (runtime) or `if Code.ensure_loaded?`
      # (compile-time, for the Credo checks), so a consumer only needs the dep for
      # the integration they actually use; production builds without them are fine.
      {:mox, "~> 1.0", optional: true},
      {:telemetry, "~> 1.0", optional: true},
      {:phoenix_pubsub, "~> 2.0", optional: true},
      {:credo, "~> 1.7", optional: true, runtime: false}
    ]
  end
end

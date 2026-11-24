defmodule OmniBuf.MixProject do
  use Mix.Project

  @version "0.1.4"
  @source_url "https://github.com/omnibuf/omnibuf-elixir"

  def project do
    [
      app: :omnibuf,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:omnibuf_nif],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "conformance", "test/support"]

  defp elixirc_paths(:dev) do
    ["lib", "conformance"]
  end

  defp elixirc_paths(:prod) do
    case System.get_env("OMNIBUF_ESCRIPT") do
      "conformance" -> ["lib", "conformance"]
      _ -> ["lib"]
    end
  end

  defp escript do
    case System.get_env("OMNIBUF_ESCRIPT") do
      "conformance" ->
        [main_module: OmniBuf.Conformance.CLI, name: "conformance-elixir"]

      _ ->
        [main_module: OmniBuf.Plugin.CLI, name: "protoc-gen-omnibuf-elixir"]
    end
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:protobuf, "~> 0.14"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:grpc, "~> 1.0", only: :test}
    ]
  end

  defp description do
    "OmniBuf v1 DRAFT-1 binary wire format for Elixir: Prefix-Varints, self-describing schemas, lazy Opaque views, and Protobuf compatibility."
  end

  defp package do
    [
      name: "omnibuf",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib native/omnibuf_nif/Cargo.toml native/omnibuf_nif/src mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end
end

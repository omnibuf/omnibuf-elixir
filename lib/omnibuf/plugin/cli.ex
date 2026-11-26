defmodule OmniBuf.Plugin.CLI do
  @moduledoc """
  Escript entry point for `protoc-gen-omnibuf-elixir`.

  Reads a binary Protobuf `CodeGeneratorRequest` from stdin and writes a binary
  `CodeGeneratorResponse` to stdout.
  """

  alias Google.Protobuf.Compiler.{CodeGeneratorRequest, CodeGeneratorResponse}
  alias OmniBuf.Plugin.{Editions, Generator}

  @spec main([String.t()]) :: no_return()
  def main(_args) do
    :io.setopts(:standard_io, encoding: :latin1)
    input = IO.binread(:stdio, :eof)

    resp =
      try do
        req = CodeGeneratorRequest.decode(input)
        Generator.generate(req)
      rescue
        e ->
          %CodeGeneratorResponse{
            error: Exception.message(e),
            supported_features: Editions.supported_features(),
            minimum_edition: Editions.minimum_edition(),
            maximum_edition: Editions.maximum_edition()
          }
      end

    output = CodeGeneratorResponse.encode(resp)
    IO.binwrite(:stdio, output)
  end
end

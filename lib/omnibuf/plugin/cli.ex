defmodule OmniBuf.Plugin.CLI do
  @moduledoc """
  Escript entry point for `protoc-gen-omnibuf-elixir`.

  Reads a binary Protobuf `CodeGeneratorRequest` from stdin and writes a binary
  `CodeGeneratorResponse` to stdout.
  """

  alias Google.Protobuf.Compiler.{CodeGeneratorRequest, CodeGeneratorResponse}
  alias OmniBuf.Plugin.Generator

  @spec main([String.t()]) :: no_return()
  def main(_args) do
    :io.setopts(:standard_io, encoding: :latin1)
    input = IO.binread(:stdio, :eof)

    req = CodeGeneratorRequest.decode(input)
    resp = Generator.generate(req)
    output = CodeGeneratorResponse.encode(resp)
    IO.binwrite(:stdio, output)
  end
end

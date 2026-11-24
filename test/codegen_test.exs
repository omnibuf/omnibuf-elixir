defmodule OmniBuf.CodegenTest do
  use ExUnit.Case, async: true

  alias Google.Protobuf.Compiler.CodeGeneratorRequest

  alias Google.Protobuf.{
    DescriptorProto,
    EnumDescriptorProto,
    EnumValueDescriptorProto,
    FieldDescriptorProto,
    FileDescriptorProto
  }

  alias OmniBuf.Plugin.Generator

  describe "enum keyword escaping and TYPE_GROUP rejection" do
    test "escapes Elixir reserved keywords in generated enums so output compiles" do
      enum_desc = %EnumDescriptorProto{
        name: "KeywordEnum",
        value: [
          %EnumValueDescriptorProto{name: "END", number: 0},
          %EnumValueDescriptorProto{name: "DO", number: 1},
          %EnumValueDescriptorProto{name: "FN", number: 2},
          %EnumValueDescriptorProto{name: "TRUE", number: 3},
          %EnumValueDescriptorProto{name: "FALSE", number: 4},
          %EnumValueDescriptorProto{name: "NIL", number: 5},
          %EnumValueDescriptorProto{name: "NORMAL", number: 6}
        ]
      }

      req = %CodeGeneratorRequest{
        file_to_generate: ["kw.proto"],
        parameter: "module_prefix=OmniBuf.CodegenTest.Gen",
        proto_file: [
          %FileDescriptorProto{
            name: "kw.proto",
            package: "test",
            enum_type: [enum_desc]
          }
        ]
      }

      resp = Generator.generate(req)
      assert [%{content: code}] = resp.file
      assert code =~ "def end_, do: 0"
      assert code =~ "def do_, do: 1"
      assert code =~ "def fn_, do: 2"
      assert code =~ "def true_, do: 3"
      assert code =~ "def false_, do: 4"
      assert code =~ "def nil_, do: 5"
      assert code =~ "def normal, do: 6"
      assert [{mod, _}] = Code.compile_string(code)
      assert mod.end_() == 0
      assert mod.normal() == 6
    end

    test "rejects TYPE_GROUP cleanly with ArgumentError" do
      req = %CodeGeneratorRequest{
        file_to_generate: ["group.proto"],
        proto_file: [
          %FileDescriptorProto{
            name: "group.proto",
            message_type: [
              %DescriptorProto{
                name: "HasGroup",
                field: [
                  %FieldDescriptorProto{
                    name: "legacy",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_GROUP
                  }
                ]
              }
            ]
          }
        ]
      }

      assert_raise ArgumentError, ~r/TYPE_GROUP/, fn ->
        Generator.generate(req)
      end
    end
  end
end

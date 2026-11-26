defmodule OmniBuf.EditionsTest do
  use ExUnit.Case, async: false

  alias Google.Protobuf.Compiler.{CodeGeneratorRequest, CodeGeneratorResponse}

  alias Google.Protobuf.{
    DescriptorProto,
    FeatureSet,
    FieldDescriptorProto,
    FileDescriptorProto,
    FileDescriptorSet,
    FileOptions,
    MessageOptions,
    OneofDescriptorProto,
    OneofOptions
  }

  alias OmniBuf.{Blind, Native, Wire}
  alias OmniBuf.Plugin.Generator
  alias OmniBuf.Protobuf, as: OmniProtobuf

  @escript_path Path.expand("../protoc-gen-omnibuf-elixir", __DIR__)

  setup do
    prev = Native.enabled?()

    on_exit(fn ->
      _ = Native.set_enabled(prev)
    end)

    :ok
  end

  defp modes do
    if Native.loaded?(), do: [false, true], else: [false]
  end

  defp mod!(parts) when is_list(parts), do: Module.concat(parts)

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "omnibuf_editions_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp compile_proto_to_fds!(files_map) do
    dir = tmp_dir!()
    fds_path = Path.join(dir, "descriptors.pb")

    paths =
      Enum.map(files_map, fn {rel, content} ->
        full = Path.join(dir, rel)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
        full
      end)

    {out, status} =
      System.cmd(
        "protoc",
        ["-I", dir, "--include_imports", "--descriptor_set_out=#{fds_path}" | paths],
        stderr_to_stdout: true
      )

    assert status == 0, "protoc failed (status #{status}):\n#{out}"
    FileDescriptorSet.decode(File.read!(fds_path)).file
  end

  defp generate_and_compile!(files_map, target_names, module_prefix) do
    proto_files = compile_proto_to_fds!(files_map)

    req = %CodeGeneratorRequest{
      file_to_generate: target_names,
      parameter: "module_prefix=#{module_prefix}",
      proto_file: proto_files
    }

    resp = Generator.generate(req)
    assert resp.error == nil, "unexpected generator error: #{inspect(resp.error)}"
    assert resp.supported_features == 3
    assert resp.minimum_edition == 1000
    assert resp.maximum_edition == 1002

    Enum.each(resp.file, fn f ->
      Code.compile_string(f.content, f.name)
    end)

    resp
  end

  defp run_protoc_plugin!(files_map, target_names, module_prefix) do
    assert File.exists?(@escript_path),
           "plugin escript not found at #{@escript_path}; run `mix escript.build`"

    dir = tmp_dir!()
    out_dir = Path.join(dir, "out")
    File.mkdir_p!(out_dir)

    Enum.each(files_map, fn {rel, content} ->
      full = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    target_paths = Enum.map(target_names, &Path.join(dir, &1))

    {output, status} =
      System.cmd(
        "protoc",
        [
          "-I",
          dir,
          "--plugin=protoc-gen-omnibuf-elixir=#{@escript_path}",
          "--omnibuf-elixir_out=#{out_dir}",
          "--omnibuf-elixir_opt=module_prefix=#{module_prefix}"
          | target_paths
        ],
        stderr_to_stdout: true
      )

    generated =
      out_dir
      |> Path.join("**/*_omnibuf.ex")
      |> Path.wildcard()
      |> Enum.into(%{}, fn path ->
        {Path.relative_to(path, out_dir), File.read!(path)}
      end)

    {status, output, generated}
  end

  describe "real protoc 36.2 + escript E2E across Editions 2023, 2024, and 2026" do
    test "generates, compiles, and round-trips Edition 2023, 2024, and 2026 via protoc-gen-omnibuf-elixir escript" do
      e2023 = """
      edition = "2023";
      package e23;

      enum Status {
        STATUS_UNSPECIFIED = 0;
        STATUS_ACTIVE = 1;
      }

      message Item {
        int32 id = 1;
        string label = 2;
        bool flag = 3;
        Status status = 4;
      }
      """

      e2024 = """
      edition = "2024";
      package e24;

      option features.default_symbol_visibility = STRICT;
      option features.enforce_naming_style = STYLE2024;

      export enum Kind {
        KIND_UNSPECIFIED = 0;
        KIND_ALPHA = 1;
      }

      local message LocalHelper {
        int32 code = 1;
      }

      export message Record {
        int32 count = 1;
        Kind kind = 2;
        LocalHelper helper = 3;
        LocalHelper delimited_helper = 4 [features.message_encoding = DELIMITED];
      }
      """

      e2026 = """
      edition = "2026";
      package e26;

      option features.enforce_naming_style = STYLE2024;

      export message Envelope {
        option features.enforce_proto_limits = PROTO_LIMITS2026;
        uint64 seq = 1;
        bool ok = 2;
        string payload = 3;
        oneof body {
          int32 code = 4;
          string note = 5;
        }
      }
      """

      files = %{
        "e2023.proto" => e2023,
        "e2024.proto" => e2024,
        "e2026.proto" => e2026
      }

      # Confirm protoc 36.2 emits raw integer 1002 for Edition 2026 in elixir-protobuf
      fds = compile_proto_to_fds!(files)
      f26 = Enum.find(fds, &(&1.name == "e2026.proto"))
      assert f26.syntax == "editions"
      assert f26.edition == 1002

      prefix = "OmniBuf.EditionsTest.Escript"

      # Execute real protoc invoking the compiled escript plugin
      {status, output, generated} =
        run_protoc_plugin!(files, ["e2023.proto", "e2024.proto", "e2026.proto"], prefix)

      assert status == 0, "protoc plugin execution failed:\n#{output}"
      assert Map.has_key?(generated, "e2023_omnibuf.ex")
      assert Map.has_key?(generated, "e2024_omnibuf.ex")
      assert Map.has_key?(generated, "e2026_omnibuf.ex")

      for {name, code} <- generated do
        Code.compile_string(code, name)
      end

      item_mod = mod!([prefix, "E23", "Item"])
      record_mod = mod!([prefix, "E24", "Record"])
      helper_mod = mod!([prefix, "E24", "LocalHelper"])
      env_mod = mod!([prefix, "E26", "Envelope"])

      for native? <- modes() do
        :ok = Native.set_enabled(native?)

        # Edition 2023 explicit presence: zero/false/empty differ from absent
        empty_item = struct(item_mod)
        assert item_mod.encode(empty_item) == <<>>
        assert {:ok, ^empty_item} = item_mod.decode(<<>>)

        zero_item = struct(item_mod, id: 0, label: "", flag: false, status: 0)
        z_bin = item_mod.encode(zero_item)
        assert byte_size(z_bin) > 0
        assert {:ok, ^zero_item} = item_mod.decode(z_bin)

        # Edition 2024 with export/local and DELIMITED submessage
        rec =
          struct(record_mod,
            count: 0,
            kind: 99,
            helper: struct(helper_mod, code: 0),
            delimited_helper: struct(helper_mod, code: 7)
          )

        rec_bin = record_mod.encode(rec)
        assert {:ok, ^rec} = record_mod.decode(rec_bin)

        # Edition 2026 with explicit bool false + active zero oneof
        env = struct(env_mod, seq: 0, ok: false, payload: "", body: {:code, 0})
        env_bin = env_mod.encode(env)
        assert byte_size(env_bin) > 0
        assert {:ok, ^env} = env_mod.decode(env_bin)
      end
    end

    test "CodeGeneratorResponse encodes and decodes minimum_edition=1000 and maximum_edition=1002" do
      resp = %CodeGeneratorResponse{
        supported_features: 3,
        minimum_edition: 1000,
        maximum_edition: 1002
      }

      bin = CodeGeneratorResponse.encode(resp)
      decoded = CodeGeneratorResponse.decode(bin)
      assert decoded.supported_features == 3
      assert decoded.minimum_edition == 1000
      assert decoded.maximum_edition == 1002
    end
  end

  describe "explicit presence, inherited overrides, collections, delimited messages, and oneofs" do
    test "distinguishes absent nil from explicit zero/false/empty across all scalar types in Elixir and NIF modes" do
      proto = """
      edition = "2023";
      package pres;

      enum Color {
        COLOR_UNSPECIFIED = 0;
        COLOR_RED = 1;
      }

      message Child {
        int32 v = 1;
      }

      message AllExplicit {
        int32 f_i32 = 1;
        int64 f_i64 = 2;
        uint32 f_u32 = 3;
        uint64 f_u64 = 4;
        sint32 f_s32 = 5;
        sint64 f_s64 = 6;
        fixed32 f_fx32 = 7;
        fixed64 f_fx64 = 8;
        sfixed32 f_sfx32 = 9;
        sfixed64 f_sfx64 = 10;
        float f_f32 = 11;
        double f_f64 = 12;
        bool f_bool = 13;
        string f_str = 14;
        bytes f_bytes = 15;
        Color f_enum = 16;
        Child f_child = 17;
      }
      """

      prefix = "OmniBuf.EditionsTest.Pres"
      generate_and_compile!(%{"pres.proto" => proto}, ["pres.proto"], prefix)
      mod = mod!([prefix, "Pres", "AllExplicit"])
      child_mod = mod!([prefix, "Pres", "Child"])

      absent = struct(mod)

      for field <- [
            :f_i32,
            :f_i64,
            :f_u32,
            :f_u64,
            :f_s32,
            :f_s64,
            :f_fx32,
            :f_fx64,
            :f_sfx32,
            :f_sfx64,
            :f_f32,
            :f_f64,
            :f_bool,
            :f_str,
            :f_bytes,
            :f_enum,
            :f_child
          ] do
        assert Map.fetch!(absent, field) == nil
      end

      explicit_zeros =
        struct(mod,
          f_i32: 0,
          f_i64: 0,
          f_u32: 0,
          f_u64: 0,
          f_s32: 0,
          f_s64: 0,
          f_fx32: 0,
          f_fx64: 0,
          f_sfx32: 0,
          f_sfx64: 0,
          f_f32: 0.0,
          f_f64: 0.0,
          f_bool: false,
          f_str: "",
          f_bytes: <<>>,
          f_enum: 0,
          f_child: struct(child_mod)
        )

      # Verify WireBoolFalse (tag 2) for explicit false and WireBoolTrue (tag 3) for true
      only_false_bin = mod.encode(struct(mod, f_bool: false))
      assert only_false_bin == Wire.encode_tag(13, Wire.wire_bool_false())

      only_true_bin = mod.encode(struct(mod, f_bool: true))
      assert only_true_bin == Wire.encode_tag(13, Wire.wire_bool_true())

      bins =
        for native? <- modes() do
          :ok = Native.set_enabled(native?)
          assert mod.encode(absent) == <<>>
          assert {:ok, ^absent} = mod.decode(<<>>)

          bin = mod.encode(explicit_zeros)
          assert byte_size(bin) > 0
          assert {:ok, ^explicit_zeros} = mod.decode(bin)

          # Merge semantics: absent wire keeps existing; present zero overwrites non-zero
          non_zero = struct(mod, f_i32: 42, f_bool: true, f_str: "abc")
          assert {:ok, ^non_zero} = mod.merge(non_zero, <<>>)

          zero_patch = mod.encode(struct(mod, f_i32: 0, f_bool: false, f_str: ""))
          assert {:ok, merged} = mod.merge(non_zero, zero_patch)
          assert merged.f_i32 == 0
          assert merged.f_bool == false
          assert merged.f_str == ""

          bin
        end

      if length(bins) == 2 do
        assert Enum.at(bins, 0) == Enum.at(bins, 1)
      end
    end

    test "resolves inherited feature overrides across file -> message -> nested -> field" do
      implicit_file = """
      edition = "2023";
      package inherit_impl;

      option features.field_presence = IMPLICIT;
      option features.json_format = LEGACY_BEST_EFFORT;

      message MsgImplicit {
        int32 impl_a = 1;
        int32 expl_b = 2 [features.field_presence = EXPLICIT];

        message Nested {
          bool impl_nested = 1;
          bool expl_nested = 2 [features.field_presence = EXPLICIT];
        }

        Nested nested = 3 [features.message_encoding = DELIMITED];
      }

      message ExplicitChild {
        int32 expl_c = 1 [features.field_presence = EXPLICIT];
        string impl_d = 2;
      }

      message ImplicitParentWithExplicitChild {
        int32 tag = 1;
        ExplicitChild child = 2;
      }
      """

      explicit_file = """
      edition = "2023";
      package inherit_expl;

      message MsgExplicit {
        int32 expl_c = 1;
        string impl_d = 2 [features.field_presence = IMPLICIT];
      }
      """

      prefix = "OmniBuf.EditionsTest.Inherit"

      generate_and_compile!(
        %{"inherit_impl.proto" => implicit_file, "inherit_expl.proto" => explicit_file},
        ["inherit_impl.proto", "inherit_expl.proto"],
        prefix
      )

      m_impl = mod!([prefix, "InheritImpl", "MsgImplicit"])
      m_nested = mod!([prefix, "InheritImpl", "MsgImplicit", "Nested"])
      m_child = mod!([prefix, "InheritImpl", "ExplicitChild"])
      m_parent = mod!([prefix, "InheritImpl", "ImplicitParentWithExplicitChild"])
      m_expl = mod!([prefix, "InheritExpl", "MsgExplicit"])

      assert struct(m_impl).impl_a == 0
      assert struct(m_impl).expl_b == nil
      assert struct(m_nested).impl_nested == false
      assert struct(m_nested).expl_nested == nil
      assert struct(m_expl).expl_c == nil
      assert struct(m_expl).impl_d == ""

      for native? <- modes() do
        :ok = Native.set_enabled(native?)

        # Implicit zero omitted; explicit zero encoded
        assert m_impl.encode(struct(m_impl, impl_a: 0, expl_b: nil)) == <<>>
        b = m_impl.encode(struct(m_impl, impl_a: 0, expl_b: 0))
        assert byte_size(b) > 0
        assert {:ok, dec} = m_impl.decode(b)
        assert dec.impl_a == 0
        assert dec.expl_b == 0

        # Explicit default file with field-level IMPLICIT override
        assert m_expl.encode(struct(m_expl, expl_c: nil, impl_d: "")) == <<>>
        eb = m_expl.encode(struct(m_expl, expl_c: 0, impl_d: ""))
        assert byte_size(eb) > 0
        assert {:ok, edec} = m_expl.decode(eb)
        assert edec.expl_c == 0
        assert edec.impl_d == ""

        # Nested explicit child inside implicit parent (verifies NIF fallback walks schema graph)
        p =
          struct(m_parent,
            tag: 0,
            child: struct(m_child, expl_c: 0, impl_d: "")
          )

        p_bin = m_parent.encode(p)
        assert {:ok, p_dec} = m_parent.decode(p_bin)
        assert p_dec.tag == 0
        assert p_dec.child.expl_c == 0
        assert p_dec.child.impl_d == ""
      end

      # Verify descriptor-level MessageOptions -> Nested -> Field feature inheritance
      desc_prefix = "OmniBuf.EditionsTest.MsgInherit"

      req = %CodeGeneratorRequest{
        file_to_generate: ["msg_inherit.proto"],
        parameter: "module_prefix=#{desc_prefix}",
        proto_file: [
          %FileDescriptorProto{
            name: "msg_inherit.proto",
            package: "mi",
            syntax: "editions",
            edition: :EDITION_2023,
            options: %FileOptions{features: %FeatureSet{field_presence: :IMPLICIT}},
            message_type: [
              %DescriptorProto{
                name: "Outer",
                options: %MessageOptions{features: %FeatureSet{field_presence: :EXPLICIT}},
                field: [
                  %FieldDescriptorProto{
                    name: "outer_expl",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_INT32
                  }
                ],
                nested_type: [
                  %DescriptorProto{
                    name: "Inner",
                    field: [
                      %FieldDescriptorProto{
                        name: "inner_expl",
                        number: 1,
                        label: :LABEL_OPTIONAL,
                        type: :TYPE_BOOL
                      },
                      %FieldDescriptorProto{
                        name: "inner_impl",
                        number: 2,
                        label: :LABEL_OPTIONAL,
                        type: :TYPE_BOOL,
                        options: %Google.Protobuf.FieldOptions{
                          features: %FeatureSet{field_presence: :IMPLICIT}
                        }
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      resp = Generator.generate(req)
      assert resp.error == nil
      Enum.each(resp.file, &Code.compile_string(&1.content, &1.name))

      outer_mod = mod!([desc_prefix, "Mi", "Outer"])
      inner_mod = mod!([desc_prefix, "Mi", "Outer", "Inner"])
      assert struct(outer_mod).outer_expl == nil
      assert struct(inner_mod).inner_expl == nil
      assert struct(inner_mod).inner_impl == false
    end

    test "supports open enums, packed/expanded repeated, maps, delimited messages, and zero defaults" do
      proto = """
      edition = "2023";
      package feat;

      option features.json_format = ALLOW;

      enum OpenStatus {
        OPEN_STATUS_UNSPECIFIED = 0;
        OPEN_STATUS_OK = 1;
      }

      message Child {
        int32 x = 1;
        string name = 2;
      }

      message FeatureMix {
        OpenStatus status = 1 [default = OPEN_STATUS_UNSPECIFIED];
        int32 zero_i = 2 [default = 0];
        bool zero_b = 3 [default = false];
        string zero_s = 4 [default = ""];
        bytes zero_by = 5 [default = ""];
        float zero_f = 6 [default = 0.0];
        double zero_d = 7 [default = 0];
        repeated int32 packed_nums = 8 [features.repeated_field_encoding = PACKED];
        repeated int32 expanded_nums = 9 [features.repeated_field_encoding = EXPANDED];
        repeated Child children = 10;
        Child delim_one = 11 [features.message_encoding = DELIMITED];
        repeated Child delim_many = 12 [features.message_encoding = DELIMITED];
        map<string, int32> scores = 13;
        map<string, Child> child_map = 14;
      }
      """

      prefix = "OmniBuf.EditionsTest.Feat"
      generate_and_compile!(%{"feat.proto" => proto}, ["feat.proto"], prefix)
      mod = mod!([prefix, "Feat", "FeatureMix"])
      child_mod = mod!([prefix, "Feat", "Child"])

      for native? <- modes() do
        :ok = Native.set_enabled(native?)

        # Unknown positive and negative open enum values preserved
        msg =
          struct(mod,
            status: 1234,
            packed_nums: [1, 2, 3],
            expanded_nums: [-5, 0, 5],
            children: [struct(child_mod, x: 1, name: "a")],
            delim_one: struct(child_mod, x: 0, name: ""),
            delim_many: [struct(child_mod, x: 2, name: "b"), struct(child_mod, x: 3, name: "c")],
            scores: %{"a" => 10, "b" => 0},
            child_map: %{"k" => struct(child_mod, x: 9, name: "v")}
          )

        bin = mod.encode(msg)
        assert {:ok, ^msg} = mod.decode(bin)

        neg_enum = struct(mod, status: -7)
        assert {:ok, ^neg_enum} = mod.decode(mod.encode(neg_enum))
      end
    end

    test "supports Editions synthetic TYPE_GROUP descriptor as normal WireSubMsg" do
      prefix = "OmniBuf.EditionsTest.Group"

      req = %CodeGeneratorRequest{
        file_to_generate: ["delim_group.proto"],
        parameter: "module_prefix=#{prefix}",
        proto_file: [
          %FileDescriptorProto{
            name: "delim_group.proto",
            package: "dg",
            syntax: "editions",
            edition: :EDITION_2023,
            message_type: [
              %DescriptorProto{
                name: "Sub",
                field: [
                  %FieldDescriptorProto{
                    name: "v",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_INT32
                  }
                ]
              },
              %DescriptorProto{
                name: "Holder",
                field: [
                  %FieldDescriptorProto{
                    name: "g",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_GROUP,
                    type_name: ".dg.Sub"
                  },
                  %FieldDescriptorProto{
                    name: "gs",
                    number: 2,
                    label: :LABEL_REPEATED,
                    type: :TYPE_GROUP,
                    type_name: ".dg.Sub"
                  }
                ]
              }
            ]
          }
        ]
      }

      resp = Generator.generate(req)
      assert resp.error == nil
      Enum.each(resp.file, &Code.compile_string(&1.content, &1.name))

      holder = mod!([prefix, "Dg", "Holder"])
      sub = mod!([prefix, "Dg", "Sub"])

      msg = struct(holder, g: struct(sub, v: 0), gs: [struct(sub, v: 1), struct(sub, v: 2)])
      assert {:ok, ^msg} = holder.decode(holder.encode(msg))
    end

    test "supports oneof in eager structs, Opaque views, and self-describing Blind decode" do
      proto = """
      edition = "2024";
      package oo;

      export message Payload {
        int32 a = 1;
        string b = 2;
      }

      export message Event {
        uint32 id = 1;
        oneof choice {
          int32 opt_int = 2;
          string opt_str = 3;
          bool opt_bool = 4;
          bytes opt_bytes = 5;
          Payload opt_sub = 6;
        }
      }
      """

      prefix = "OmniBuf.EditionsTest.OO"
      generate_and_compile!(%{"oo.proto" => proto}, ["oo.proto"], prefix)
      mod = mod!([prefix, "Oo", "Event"])
      op_mod = mod!([prefix, "Oo", "Event", "Opaque"])
      sub_mod = mod!([prefix, "Oo", "Payload"])

      for native? <- modes() do
        :ok = Native.set_enabled(native?)

        # Absent oneof
        empty = struct(mod)
        assert empty.choice == nil
        assert mod.encode(empty) == <<>>
        assert {:ok, ^empty} = mod.decode(<<>>)
        assert op_mod.get_choice(op_mod.new(<<>>)) == nil

        # Active zero/false/empty/submsg branches
        for branch <- [
              {:opt_int, 0},
              {:opt_str, ""},
              {:opt_bool, false},
              {:opt_bool, true},
              {:opt_bytes, <<>>},
              {:opt_sub, struct(sub_mod)},
              {:opt_sub, struct(sub_mod, a: 7, b: "ok")}
            ] do
          msg = struct(mod, id: 1, choice: branch)
          bin = mod.encode(msg)
          assert byte_size(bin) > 0
          assert {:ok, ^msg} = mod.decode(bin)
          assert op_mod.get_choice(op_mod.new(bin)) == branch
        end

        # Switching branch on wire: last branch wins
        p1 = mod.encode(struct(mod, choice: {:opt_int, 99}))
        p2 = mod.encode(struct(mod, choice: {:opt_str, ""}))
        combined = p1 <> p2
        assert {:ok, dec} = mod.decode(combined)
        assert dec.choice == {:opt_str, ""}
        assert op_mod.get_choice(op_mod.new(combined)) == {:opt_str, ""}

        # Consecutive submsg branch merges; sibling in between resets
        s1 = mod.encode(struct(mod, choice: {:opt_sub, struct(sub_mod, a: 1)}))
        s2 = mod.encode(struct(mod, choice: {:opt_sub, struct(sub_mod, b: "two")}))

        merged_sub = struct(sub_mod, a: 1, b: "two")
        assert {:ok, dec_consec} = mod.decode(s1 <> s2)
        assert dec_consec.choice == {:opt_sub, merged_sub}
        assert op_mod.get_choice(op_mod.new(s1 <> s2)) == {:opt_sub, merged_sub}

        interleaved = s1 <> p1 <> s2
        reset_sub = struct(sub_mod, a: nil, b: "two")
        assert {:ok, dec_reset} = mod.decode(interleaved)
        assert dec_reset.choice == {:opt_sub, reset_sub}
        assert op_mod.get_choice(op_mod.new(interleaved)) == {:opt_sub, reset_sub}

        # Opaque mutation: switch branch and strip old sibling wire bytes
        op =
          s1
          |> op_mod.new()
          |> op_mod.set_choice({:opt_bool, false})

        assert op_mod.get_choice(op) == {:opt_bool, false}
        spliced = op_mod.marshal!(op)
        assert {:ok, dec_spliced} = mod.decode(spliced)
        assert dec_spliced.choice == {:opt_bool, false}
        # Confirm field 6 (opt_sub) was removed, leaving only field 4 WireBoolFalse
        assert spliced == Wire.encode_tag(4, Wire.wire_bool_false())

        # Opaque clear via nil and {branch, nil}
        cleared = spliced |> op_mod.new() |> op_mod.set_choice(nil) |> op_mod.marshal!()
        assert cleared == <<>>

        cleared2 =
          spliced |> op_mod.new() |> op_mod.set_choice({:opt_bool, nil}) |> op_mod.marshal!()

        assert cleared2 == <<>>

        # Self-describing Blind decode resolves oneof branch and child names
        sd =
          mod.encode(struct(mod, id: 5, choice: {:opt_sub, struct(sub_mod, a: 10, b: "hi")}),
            self_describing: true
          )

        assert {:ok, blind} = Blind.decode(sd)
        assert blind["id"] == 5
        assert blind["opt_sub"] == %{"a" => 10, "b" => "hi"}
      end
    end

    test "Opaque views read absent nil vs present zero and splice optional fields cleanly" do
      proto = """
      edition = "2023";
      package opq;

      message Metrics {
        int32 count = 1;
        bool ok = 2;
        string note = 3;
        bytes raw = 4;
        float ratio = 5;
      }
      """

      prefix = "OmniBuf.EditionsTest.Opq"
      generate_and_compile!(%{"opq.proto" => proto}, ["opq.proto"], prefix)
      mod = mod!([prefix, "Opq", "Metrics"])
      op_mod = mod!([prefix, "Opq", "Metrics", "Opaque"])

      for native? <- modes() do
        :ok = Native.set_enabled(native?)

        # Absent fields return nil
        empty_op = op_mod.new(<<>>)
        assert op_mod.get_count(empty_op) == nil
        assert op_mod.has_count?(empty_op) == false
        assert op_mod.get_ok(empty_op) == nil
        assert op_mod.has_ok?(empty_op) == false
        assert op_mod.get_note(empty_op) == nil
        assert op_mod.get_raw(empty_op) == nil
        assert op_mod.get_ratio(empty_op) == nil

        # Set explicit zero/false/empty via Opaque setters
        spliced =
          empty_op
          |> op_mod.set_count(0)
          |> op_mod.set_ok(false)
          |> op_mod.set_note("")
          |> op_mod.set_raw(<<>>)
          |> op_mod.set_ratio(0.0)
          |> op_mod.marshal!()

        assert byte_size(spliced) > 0

        # Read back from wire via fresh Opaque view
        read_op = op_mod.new(spliced)
        assert op_mod.get_count(read_op) == 0
        assert op_mod.has_count?(read_op) == true
        assert op_mod.get_ok(read_op) == false
        assert op_mod.has_ok?(read_op) == true
        assert op_mod.get_note(read_op) == ""
        assert op_mod.get_raw(read_op) == <<>>
        assert op_mod.get_ratio(read_op) == 0.0

        # Decode with struct codec matches
        assert {:ok, dec} = mod.decode(spliced)
        assert dec.count == 0
        assert dec.ok == false
        assert dec.note == ""
        assert dec.raw == <<>>
        assert dec.ratio == 0.0

        # Clear specific fields to nil and verify removal
        cleared =
          read_op
          |> op_mod.set_count(nil)
          |> op_mod.set_ok(nil)
          |> op_mod.set_note(nil)
          |> op_mod.set_raw(nil)
          |> op_mod.set_ratio(nil)
          |> op_mod.marshal!()

        assert cleared == <<>>
        assert {:ok, empty_dec} = mod.decode(cleared)
        assert empty_dec == struct(mod)
      end
    end
  end

  describe "OmniBuf.Protobuf reflection codec explicit presence and open enums" do
    defmodule RefEnum do
      use Protobuf, enum: true, syntax: :proto3
      field(:ZERO, 0)
      field(:ONE, 1)
    end

    defmodule RefProto3Optional do
      use Protobuf, syntax: :proto3

      field(:impl_int, 1, type: :int32)
      field(:opt_int, 2, proto3_optional: true, type: :int32)
      field(:opt_bool, 3, proto3_optional: true, type: :bool)
      field(:opt_str, 4, proto3_optional: true, type: :string)
      field(:opt_bytes, 5, proto3_optional: true, type: :bytes)
      field(:opt_float, 6, proto3_optional: true, type: :float)
      field(:opt_enum, 7, proto3_optional: true, type: RefEnum, enum: true)
    end

    defmodule RefEditions do
      use Protobuf, syntax: :editions

      field(:count, 1, optional: true, type: :int32)
      field(:flag, 2, optional: true, type: :bool)
      field(:label, 3, optional: true, type: :string)
      field(:status, 4, optional: true, type: RefEnum, enum: true)
    end

    test "encodes explicit zero/false/empty for proto3_optional and editions optional fields" do
      # Absent optional fields produce empty bytes
      assert OmniProtobuf.encode(%RefProto3Optional{}) == <<>>

      # Present explicit zeros/false/empty encode on wire and round-trip
      p3 = %RefProto3Optional{
        impl_int: 0,
        opt_int: 0,
        opt_bool: false,
        opt_str: "",
        opt_bytes: <<>>,
        opt_float: 0.0,
        opt_enum: :ZERO
      }

      p3_bin = OmniProtobuf.encode(p3)
      assert byte_size(p3_bin) > 0
      assert {:ok, ^p3} = OmniProtobuf.decode(p3_bin, RefProto3Optional)

      # Explicit false encodes WireBoolFalse tag 2
      assert OmniProtobuf.encode(%RefProto3Optional{opt_bool: false}) ==
               Wire.encode_tag(3, Wire.wire_bool_false())

      # Editions syntax with optional: true fields and unknown negative enum value
      assert OmniProtobuf.encode(%RefEditions{}) == <<>>

      ed = %RefEditions{count: 0, flag: false, label: "", status: :ZERO}
      ed_bin = OmniProtobuf.encode(ed)
      assert byte_size(ed_bin) > 0
      assert {:ok, ^ed} = OmniProtobuf.decode(ed_bin, RefEditions)

      # Unknown positive and negative open enum values round-trip safely
      ed_unk = %RefEditions{status: -42}
      assert {:ok, ^ed_unk} = OmniProtobuf.decode(OmniProtobuf.encode(ed_unk), RefEditions)
    end
  end

  describe "proto3 optional and oneof feature inheritance" do
    test "generates explicit-presence fields (not synthetic oneofs) for proto3 optional" do
      proto = """
      syntax = "proto3";
      package p3opt;

      message P3Opt {
        int32 impl_x = 1;
        optional int32 opt_x = 2;
        optional bool opt_b = 3;
        oneof real_choice {
          int32 c_int = 4;
          string c_str = 5;
        }
      }
      """

      prefix = "OmniBuf.EditionsTest.P3"
      generate_and_compile!(%{"p3opt.proto" => proto}, ["p3opt.proto"], prefix)
      mod = mod!([prefix, "P3opt", "P3Opt"])

      assert struct(mod).impl_x == 0
      assert struct(mod).opt_x == nil
      assert struct(mod).opt_b == nil
      assert struct(mod).real_choice == nil
      assert length(mod.__omnibuf_oneofs__()) == 1

      for native? <- modes() do
        :ok = Native.set_enabled(native?)
        msg = struct(mod, impl_x: 0, opt_x: 0, opt_b: false, real_choice: {:c_int, 0})
        bin = mod.encode(msg)
        assert {:ok, ^msg} = mod.decode(bin)
      end
    end

    test "inherits FeatureSet overrides from OneofOptions to oneof branch fields" do
      req = %CodeGeneratorRequest{
        file_to_generate: ["oneof_inherit.proto"],
        proto_file: [
          %FileDescriptorProto{
            name: "oneof_inherit.proto",
            package: "oi",
            syntax: "editions",
            edition: :EDITION_2023,
            message_type: [
              %DescriptorProto{
                name: "M",
                oneof_decl: [
                  %OneofDescriptorProto{
                    name: "ch",
                    options: %OneofOptions{
                      features: %FeatureSet{
                        utf8_validation: :NONE
                      }
                    }
                  }
                ],
                field: [
                  %FieldDescriptorProto{
                    name: "s",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_STRING,
                    oneof_index: 0
                  }
                ]
              }
            ]
          }
        ]
      }

      resp = Generator.generate(req)
      assert resp.error =~ "utf8_validation = NONE"
    end
  end

  describe "negative validation tests for unsupported editions and rejected features" do
    test "rejects unsupported protobuf editions with clear error" do
      for bad_edition <- [0, :EDITION_UNKNOWN, 1003, 9999] do
        req = %CodeGeneratorRequest{
          file_to_generate: ["bad.proto"],
          proto_file: [
            %FileDescriptorProto{
              name: "bad.proto",
              syntax: "editions",
              edition: bad_edition
            }
          ]
        }

        resp = Generator.generate(req)
        assert is_binary(resp.error)
        assert resp.error =~ "unsupported protobuf edition"
        assert resp.supported_features == 3
        assert resp.minimum_edition == 1000
        assert resp.maximum_edition == 1002
      end
    end

    test "rejects closed enums (declared, inherited, cross-file Editions, and cross-file proto2)" do
      # 1. Directly declared CLOSED enum
      fds1 =
        compile_proto_to_fds!(%{
          "closed_decl.proto" => """
          edition = "2023";
          package c1;
          enum ClosedE {
            option features.enum_type = CLOSED;
            CLOSED_E_ZERO = 0;
          }
          message M { ClosedE e = 1; }
          """
        })

      resp1 =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["closed_decl.proto"],
          proto_file: fds1
        })

      assert resp1.error =~ "CLOSED"

      # 2. File-level CLOSED enum inherited by enum
      fds2 =
        compile_proto_to_fds!(%{
          "closed_file.proto" => """
          edition = "2023";
          package c2;
          option features.enum_type = CLOSED;
          enum InheritedClosed {
            INHERITED_CLOSED_ZERO = 0;
          }
          """
        })

      resp2 =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["closed_file.proto"],
          proto_file: fds2
        })

      assert resp2.error =~ "CLOSED"

      # 3. File-level CLOSED overridden to OPEN on enum IS allowed
      fds_open_override =
        compile_proto_to_fds!(%{
          "open_override.proto" => """
          edition = "2023";
          package c2ok;
          option features.enum_type = CLOSED;
          enum OpenOverride {
            option features.enum_type = OPEN;
            OPEN_OVERRIDE_ZERO = 0;
          }
          message M { OpenOverride e = 1; }
          """
        })

      resp_ok =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["open_override.proto"],
          proto_file: fds_open_override
        })

      assert resp_ok.error == nil

      # 4. Cross-file closed enum in Editions (singular and map value)
      fds3 =
        compile_proto_to_fds!(%{
          "dep_closed.proto" => """
          edition = "2023";
          package depc;
          enum ForeignClosed {
            option features.enum_type = CLOSED;
            FOREIGN_CLOSED_ZERO = 0;
          }
          """,
          "use_closed.proto" => """
          edition = "2023";
          package usec;
          import "dep_closed.proto";
          message M {
            depc.ForeignClosed e = 1;
          }
          """,
          "use_closed_map.proto" => """
          edition = "2023";
          package usecm;
          import "dep_closed.proto";
          message M {
            map<string, depc.ForeignClosed> m = 1;
          }
          """
        })

      resp3 =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["use_closed.proto"],
          proto_file: fds3
        })

      assert resp3.error =~ "closed enum"

      resp3_map =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["use_closed_map.proto"],
          proto_file: fds3
        })

      assert resp3_map.error =~ "closed enum"

      # 5. Cross-file proto2 enum (closed by proto2 semantics) referenced from Editions
      fds4 =
        compile_proto_to_fds!(%{
          "p2_enum.proto" => """
          syntax = "proto2";
          package p2e;
          enum LegacyClosed {
            LEGACY_CLOSED_ZERO = 0;
          }
          """,
          "ed_uses_p2.proto" => """
          edition = "2023";
          package edp2;
          import "p2_enum.proto";
          message M {
            p2e.LegacyClosed e = 1;
          }
          """
        })

      resp4 =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["ed_uses_p2.proto"],
          proto_file: fds4
        })

      assert resp4.error =~ "closed enum"
    end

    test "rejects field_presence = LEGACY_REQUIRED" do
      fds =
        compile_proto_to_fds!(%{
          "req.proto" => """
          edition = "2023";
          package lr;
          message M {
            int32 x = 1 [features.field_presence = LEGACY_REQUIRED];
          }
          """
        })

      resp =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["req.proto"],
          proto_file: fds
        })

      assert resp.error =~ "LEGACY_REQUIRED"
    end

    test "rejects utf8_validation = NONE on singular, repeated, oneof, and map string fields" do
      cases = [
        {"singular_utf8.proto",
         """
         edition = "2023";
         package u1;
         message M {
           string s = 1 [features.utf8_validation = NONE];
         }
         """},
        {"repeated_utf8.proto",
         """
         edition = "2023";
         package u2;
         message M {
           repeated string s = 1 [features.utf8_validation = NONE];
         }
         """},
        {"oneof_utf8.proto",
         """
         edition = "2023";
         package u3;
         option features.utf8_validation = NONE;
         message M {
           oneof c {
             int32 a = 1;
             string s = 2;
           }
         }
         """},
        {"map_key_utf8.proto",
         """
         edition = "2023";
         package u4;
         option features.utf8_validation = NONE;
         message M {
           map<string, int32> m = 1;
         }
         """},
        {"map_val_utf8.proto",
         """
         edition = "2023";
         package u5;
         option features.utf8_validation = NONE;
         message M {
           map<int32, string> m = 1;
         }
         """}
      ]

      for {name, src} <- cases do
        fds = compile_proto_to_fds!(%{name => src})

        resp =
          Generator.generate(%CodeGeneratorRequest{
            file_to_generate: [name],
            proto_file: fds
          })

        assert resp.error =~ "utf8_validation = NONE",
               "expected utf8_validation = NONE rejection for #{name}, got: #{inspect(resp.error)}"
      end

      # File-level utf8_validation = NONE with NO string fields is allowed
      fds_no_str =
        compile_proto_to_fds!(%{
          "no_str_utf8.proto" => """
          edition = "2023";
          package u_ok;
          option features.utf8_validation = NONE;
          message M {
            int32 x = 1;
            bytes b = 2;
          }
          """
        })

      resp_ok =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["no_str_utf8.proto"],
          proto_file: fds_no_str
        })

      assert resp_ok.error == nil
    end

    test "rejects custom non-zero defaults in Editions" do
      cases = [
        {"def_int.proto",
         """
         edition = "2023";
         package d1;
         message M { int32 x = 1 [default = 5]; }
         """},
        {"def_bool.proto",
         """
         edition = "2023";
         package d2;
         message M { bool b = 1 [default = true]; }
         """},
        {"def_str.proto",
         """
         edition = "2023";
         package d3;
         message M { string s = 1 [default = "abc"]; }
         """},
        {"def_neg_zero.proto",
         """
         edition = "2023";
         package d4;
         message M { float f = 1 [default = -0.0]; }
         """},
        {"def_float.proto",
         """
         edition = "2023";
         package d5;
         message M { double d = 1 [default = 1.5]; }
         """},
        {"def_enum.proto",
         """
         edition = "2023";
         package d6;
         enum E { E_ZERO = 0; E_ONE = 1; }
         message M { E e = 1 [default = E_ONE]; }
         """}
      ]

      for {name, src} <- cases do
        fds = compile_proto_to_fds!(%{name => src})

        resp =
          Generator.generate(%CodeGeneratorRequest{
            file_to_generate: [name],
            proto_file: fds
          })

        assert resp.error =~ "custom non-zero default",
               "expected custom non-zero default rejection for #{name}, got: #{inspect(resp.error)}"
      end
    end

    test "rejects non-option extensions in Editions and allows custom option extensions" do
      # Non-option extension range + extend
      fds_bad =
        compile_proto_to_fds!(%{
          "ext_bad.proto" => """
          edition = "2023";
          package eb;
          message Base {
            int32 id = 1;
            extensions 100 to 199;
          }
          extend Base {
            string extra = 100;
          }
          """
        })

      resp_bad =
        Generator.generate(%CodeGeneratorRequest{
          file_to_generate: ["ext_bad.proto"],
          proto_file: fds_bad
        })

      assert resp_bad.error =~ "non-option extension"

      # Custom option extension is allowed (synthetic descriptor since descriptor.proto import varies)
      req_opt = %CodeGeneratorRequest{
        file_to_generate: ["ext_opt.proto"],
        proto_file: [
          %FileDescriptorProto{
            name: "ext_opt.proto",
            package: "eo",
            syntax: "editions",
            edition: :EDITION_2023,
            extension: [
              %FieldDescriptorProto{
                name: "my_opt",
                number: 50_001,
                label: :LABEL_OPTIONAL,
                type: :TYPE_STRING,
                extendee: ".google.protobuf.MessageOptions"
              }
            ],
            message_type: [
              %DescriptorProto{
                name: "Normal",
                field: [
                  %FieldDescriptorProto{
                    name: "id",
                    number: 1,
                    label: :LABEL_OPTIONAL,
                    type: :TYPE_INT32
                  }
                ]
              }
            ]
          }
        ]
      }

      resp_opt = Generator.generate(req_opt)
      assert resp_opt.error == nil
    end

    test "protoc CLI surfaces plugin errors cleanly with non-zero exit status" do
      {status, output, _generated} =
        run_protoc_plugin!(
          %{
            "bad_cli.proto" => """
            edition = "2023";
            package badcli;
            message M {
              int32 x = 1 [features.field_presence = LEGACY_REQUIRED];
            }
            """
          },
          ["bad_cli.proto"],
          "OmniBuf.EditionsTest.BadCli"
        )

      assert status != 0
      assert output =~ "LEGACY_REQUIRED"
    end
  end
end

defmodule Mix.Tasks.Compile.OmnibufNif do
  @moduledoc false
  use Mix.Task.Compiler

  @crate_dir "native/omnibuf_nif"

  @impl true
  def run(_args) do
    cond do
      System.get_env("OMNIBUF_NATIVE") in ["0", "false", "FALSE", "no"] ->
        {:noop, []}

      not File.exists?(Path.join(@crate_dir, "Cargo.toml")) ->
        {:noop, []}

      is_nil(find_cargo()) ->
        {:noop, []}

      true ->
        build_nif(find_cargo())
    end
  end

  defp find_cargo do
    System.find_executable("cargo") ||
      (
        home_cargo = Path.expand("~/.cargo/bin/cargo")
        if File.exists?(home_cargo), do: home_cargo, else: nil
      )
  end

  defp build_nif(cargo) do
    case System.cmd(cargo, ["build", "--release"], cd: @crate_dir, stderr_to_stdout: true) do
      {_out, 0} ->
        install_artifact()
        {:ok, []}

      {out, code} ->
        Mix.shell().error(
          "omnibuf_nif build failed (exit #{code}), falling back to pure Elixir:\n#{out}"
        )

        {:noop, []}
    end
  end

  defp install_artifact do
    src =
      case :os.type() do
        {:unix, :darwin} -> Path.join([@crate_dir, "target", "release", "libomnibuf_nif.dylib"])
        {:win32, _} -> Path.join([@crate_dir, "target", "release", "omnibuf_nif.dll"])
        _ -> Path.join([@crate_dir, "target", "release", "libomnibuf_nif.so"])
      end

    if File.exists?(src) do
      ext = if match?({:win32, _}, :os.type()), do: ".dll", else: ".so"
      dest_name = "libomnibuf_nif" <> ext

      for dir <- [
            Path.join(["priv", "native"]),
            Path.join([Mix.Project.app_path(), "priv", "native"])
          ] do
        File.mkdir_p!(dir)
        File.cp!(src, Path.join(dir, dest_name))
      end
    end
  end
end

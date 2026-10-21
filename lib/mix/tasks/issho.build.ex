defmodule Mix.Tasks.Issho.Build do
  @shortdoc "Builds the browser bundles into priv/static"

  @moduledoc """
  Builds Issho's browser client into `priv/static`.

      $ mix issho.build

  This task is for work on Issho itself. An application that uses Issho
  gets the built files in the Hex package and does not run this task: in
  any project but Issho, the task stops with an error before it changes a
  file.

  The task:

    1. Runs `npm ci` in `assets/` when `assets/node_modules` is missing or
       `assets/package-lock.json` changed since the last install.
    2. Empties `priv/static`, so that it holds only the files of this
       build.
    3. Runs esbuild (the `esbuild` Mix package) with the `:issho_esm` and
       `:issho_cjs` profiles.

  After the task, `priv/static` holds exactly the two bundles, which are
  the files of the Hex package. It needs `npm` on the path and the
  `:esbuild` dependency, which is available in the `:dev` environment.
  """

  use Mix.Task

  @compile {:no_warn_undefined, Esbuild}

  @assets "assets"
  @static "priv/static"
  @lock_hash "node_modules/.issho-lock-sha256"
  @profiles [:issho_esm, :issho_cjs]

  @impl Mix.Task
  def run(_args) do
    ensure_issho!(Mix.Project.config())
    Mix.Task.run("loadpaths")

    unless Code.ensure_loaded?(Esbuild) do
      Mix.raise("""
      mix issho.build needs the :esbuild dependency, which is available in \
      the :dev environment. Run it as `MIX_ENV=dev mix issho.build`.\
      """)
    end

    {:ok, _apps} = Application.ensure_all_started(:esbuild)

    install_packages()
    File.rm_rf!(@static)
    File.mkdir_p!(@static)
    Enum.each(@profiles, &bundle/1)

    Mix.shell().info("Issho assets are in #{@static}/")
  end

  # The task empties priv/static, so it must never run in an application.
  @doc false
  @spec ensure_issho!(keyword()) :: :ok
  def ensure_issho!(config) do
    if config[:app] == :issho do
      :ok
    else
      Mix.raise(
        "mix issho.build is for work on Issho itself; an app gets the built files in the Hex package"
      )
    end
  end

  defp install_packages do
    lock = Path.join(@assets, "package-lock.json")
    stamp = Path.join(@assets, @lock_hash)
    hash = lock |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    if File.dir?(Path.join(@assets, "node_modules")) and File.read(stamp) == {:ok, hash} do
      Mix.shell().info("assets/node_modules is up to date")
    else
      npm = System.find_executable("npm") || Mix.raise("mix issho.build needs npm on the path")
      Mix.shell().info("Running npm ci in assets/")

      case System.cmd(npm, ["ci", "--prefix", @assets], into: IO.stream(), stderr_to_stdout: true) do
        {_output, 0} -> File.write!(stamp, hash)
        {_output, status} -> Mix.raise("npm ci exited with status #{status}")
      end
    end
  end

  defp bundle(profile) do
    case Esbuild.install_and_run(profile, []) do
      0 -> :ok
      status -> Mix.raise("esbuild #{profile} exited with status #{status}")
    end
  end
end

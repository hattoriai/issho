defmodule Issho.EndToEndTest do
  # The browser client (assets/src) on a real endpoint: two clients over
  # WebSockets change one document at once, see each other's place and
  # presence, and end with the server's state. Needs Node.js and
  # assets/node_modules (`npm ci --prefix assets`); skipped without them.
  use ExUnit.Case, async: false

  alias Issho.{Authority, Documents, Token, Transaction}

  @assets Path.expand("../../assets", __DIR__)
  @esbuild Path.join(@assets, "node_modules/.bin/esbuild")

  @moduletag :e2e
  @moduletag timeout: 60_000

  unless File.exists?(@esbuild) and System.find_executable("node") != nil,
    do: @moduletag(skip: "needs Node.js and assets/node_modules (npm ci --prefix assets)")

  setup do
    start_supervised!(IsshoTest.LiveEndpoint)
    :ok
  end

  test "two browsers converge through the channel" do
    room = "board:" <> Transaction.id()
    out = Path.join(System.tmp_dir!(), "issho-e2e-#{System.unique_integer([:positive])}.mjs")

    {_, 0} =
      System.cmd(
        @esbuild,
        ~w(e2e/two_browsers.ts --bundle --platform=node --format=esm --target=node20 --log-level=warning --outfile=#{out}),
        cd: @assets,
        stderr_to_stdout: true
      )

    env = [
      {"ISSHO_URL", "ws://127.0.0.1:4871/issho/socket"},
      {"ISSHO_ROOM", room},
      {"ISSHO_ADA", Token.sign(IsshoTest.Issho, %{id: "user:ada", name: "Ada"}, room)},
      {"ISSHO_KEN", Token.sign(IsshoTest.Issho, %{id: "user:ken", name: "Kenji"}, room)}
    ]

    {output, status} = System.cmd("node", node_flags() ++ [out], env: env, stderr_to_stdout: true)
    File.rm(out)
    assert status == 0, output

    if System.get_env("SHOW_E2E"), do: IO.puts(output)
    result = output |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

    expected = %{"title" => "Plan", "n" => 20, "doc" => room}
    assert result["ada"] == expected
    assert result["ken"] == expected
    assert result["revisions"] == [21, 21]

    assert result["kenSeesPlace"] == %{
             "place" => %{"doc" => room, "at" => %{"path" => ["title"]}}
           }

    assert result["kenSeesPeople"] == ["user:ada"]
    assert result["shared"] == %{"same" => true, "can" => "write", "status" => "live"}

    {:ok, pid} = Documents.open(IsshoTest.Issho, room)
    assert {:ok, %{"state" => ^expected, "revision" => 21}} = Authority.snapshot(pid)
  end

  # Node.js 20 (the CI's) has WebSocket behind a flag; 22 has it on.
  defp node_flags do
    {version, 0} = System.cmd("node", ["-p", "process.versions.node"])
    [major | _] = version |> String.trim() |> String.split(".")
    if String.to_integer(major) < 22, do: ["--experimental-websocket"], else: []
  end
end

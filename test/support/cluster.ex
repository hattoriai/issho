defmodule IsshoTest.Cluster do
  @moduledoc false
  # A second node of the test's cluster (OTP's :peer), with the test's
  # PubSub and Issho instance: for what Issho does across nodes.

  @cookie :issho_test

  # The test's node is distributed (once), and a peer starts with its code.
  def start do
    unless Node.alive?() do
      System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:"issho_test@127.0.0.1", :longnames])
    end

    Node.set_cookie(@cookie)

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"issho_peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args:
          [~c"-setcookie", Atom.to_charlist(@cookie)] ++
            Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    :ok = :erpc.call(node, __MODULE__, :boot, [])
    # Both know the cluster's names (:global) before the test goes on.
    :ok = :global.sync()
    :ok = :erpc.call(node, :global, :sync, [])
    {peer, node}
  end

  # On the peer: the apps, then the PubSub and the instance, under a
  # process that stays (an :erpc call's own process ends with the call).
  def boot do
    for app <- [:elixir, :logger, :telemetry, :phoenix_pubsub],
        do: {:ok, _} = Application.ensure_all_started(app)

    test = self()

    spawn(fn ->
      {:ok, _} =
        Supervisor.start_link(
          [
            {Phoenix.PubSub, name: IsshoTest.PubSub},
            {Issho,
             name: IsshoTest.Issho,
             pubsub: IsshoTest.PubSub,
             secret_key_base: String.duplicate("s", 64),
             policy: IsshoTest.Policy,
             presence: false}
          ],
          strategy: :one_for_one
        )

      send(test, :booted)
      Process.sleep(:infinity)
    end)

    receive do
      :booted -> :ok
    after
      10_000 -> {:error, :timeout}
    end
  end

  # On the peer: subscribes a process of the peer to a stream, which sends
  # the test's process what it hears.
  def subscribe(id, who, to) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:subscribed, Issho.Streams.subscribe(IsshoTest.Issho, id, who)})
        forward(to)
      end)

    receive do
      {:subscribed, result} -> {pid, result}
    end
  end

  defp forward(to) do
    receive do
      message ->
        send(to, {:peer, message})
        forward(to)
    end
  end
end

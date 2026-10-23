children = [
  {Phoenix.PubSub, name: IsshoTest.PubSub},
  IsshoTest.Endpoint,
  # Sake's streams: an MCP client that listens for changes (the inbox).
  {Sake, []},
  {Issho.Store.Memory, name: IsshoTest.Store},
  {Issho,
   name: IsshoTest.Issho,
   pubsub: IsshoTest.PubSub,
   endpoint: IsshoTest.Endpoint,
   policy: IsshoTest.Policy,
   store: {Issho.Store.Memory, IsshoTest.Store},
   ttl: 200,
   awareness_interval: 10,
   awareness_full_every: 20}
]

{:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)

# The :build tests run `mix issho.build` (npm, and the network on the first
# run) and `mix hex.build`: `mix test --include build`.
ExUnit.start(exclude: [:build])

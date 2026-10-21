children = [
  {Phoenix.PubSub, name: IsshoTest.PubSub},
  IsshoTest.Endpoint,
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

ExUnit.start()

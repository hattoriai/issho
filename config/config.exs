import Config

if config_env() == :dev do
  # The browser bundles. NODE_PATH is unset: the bundles never pick up a
  # package from deps/.
  esbuild_args = ~w(
    src/index.ts
    --bundle
    --minify
    --target=es2020
    --external:phoenix
  )

  config :esbuild,
    version: "0.28.2",
    issho_esm: [
      args: esbuild_args ++ ~w(--format=esm --outfile=../priv/static/issho.esm.js),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => nil}
    ],
    issho_cjs: [
      args: esbuild_args ++ ~w(--format=cjs --outfile=../priv/static/issho.cjs.js),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => nil}
    ]
end

if config_env() == :test do
  config :logger, level: :warning
  config :phoenix, :json_library, JSON
end

if config_env() == :test do
  config :issho, IsshoTest.Endpoint,
    secret_key_base: String.duplicate("issho-test-secret-key-base-", 4),
    live_view: [signing_salt: "issho-test-salt"],
    pubsub_server: IsshoTest.PubSub,
    server: false

  # The end-to-end test's endpoint, served on a port for the browser client.
  config :issho, IsshoTest.LiveEndpoint,
    adapter: Bandit.PhoenixAdapter,
    http: [ip: {127, 0, 0, 1}, port: 4871],
    secret_key_base: String.duplicate("issho-test-secret-key-base-", 4),
    pubsub_server: IsshoTest.PubSub,
    server: true
end

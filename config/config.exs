import Config

if config_env() == :test do
  config :logger, level: :warning
  config :phoenix, :json_library, JSON
end

if config_env() == :test do
  config :issho, IsshoTest.Endpoint,
    secret_key_base: String.duplicate("issho-test-secret-key-base-", 4),
    pubsub_server: IsshoTest.PubSub,
    server: false
end

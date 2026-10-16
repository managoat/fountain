import Config
config :remote_broker, enabled: config_env() != :test
config :logger, level: :info

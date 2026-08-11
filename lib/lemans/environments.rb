# frozen_string_literal: true

module Lemans
  # The backends `lemans run --backend` can name, and the one place a name
  # becomes a class. An unknown backend fails as a config mistake.
  module Environments
    BACKENDS = { "daytona" => "Daytona" }.freeze

    def self.build(backend, **)
      constant = BACKENDS[backend.to_s] or
        raise ConfigError, "unknown backend #{backend.inspect} (known: #{BACKENDS.keys.join(", ")})"

      const_get(constant).new(**)
    end
  end
end

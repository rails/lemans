# frozen_string_literal: true

module Lemans
  # The agents by name, resolved the way Environments.build resolves backends:
  # the abstract class carries no list of its own children.
  module Agents
    REGISTRY = {
      "nop" => "Nop",
      "oracle" => "Oracle",
      "miniswen" => "Miniswen",
      "miniswen-installed" => "MiniswenInstalled"
    }.freeze

    def self.build(name, profile:, model: nil)
      constant = REGISTRY[name] or
        raise ConfigError, "unknown agent #{name.inspect} (known: #{REGISTRY.keys.join(", ")})"

      const_get(constant).new(profile: profile, model: model)
    end
  end
end

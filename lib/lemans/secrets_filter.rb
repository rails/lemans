# frozen_string_literal: true

module Lemans
  # Redacts known secret values (API credentials) from everything the store persists.
  class SecretsFilter
    # Credentials follow the <PROVIDER>_<KIND> environment convention
    # (DAYTONA_API_KEY, OPENROUTER_API_KEY, DAYTONA_TOKEN, ...).
    def self.default = new(ENV.filter_map { |name, value| value if name.match?(/_(API_KEY|TOKEN|SECRET|JWT)\z/) })

    def initialize(secrets, replacement: "<filtered>", min_length: 8)
      @replacement = replacement

      secrets = secrets.compact.uniq.select { it.length >= min_length }
      # Match bytes, not characters, so artifacts with non-UTF-8 content
      # (binary patch hunks) don't raise on scanning.
      @pattern = Regexp.union(secrets.map(&:b)) unless secrets.empty?
    end

    def filter(text)
      return text unless @pattern

      text.b.gsub(@pattern, @replacement)
    end
  end
end

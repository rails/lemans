# frozen_string_literal: true

module Miniswen
  # Represents a current runtime environment for an agent (the one
  # where instructions must be executed)
  class Environment
    ExecResult = Data.define(:exit_code, :output) do
      def success? = exit_code.zero?
    end

    # Execute a shell command
    def exec(cmd, timeout: nil, env: nil) = raise NotImplementedError
  end
end

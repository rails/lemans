# frozen_string_literal: true

module Lemans
  # What every backend must do, and nothing more: a narrow contract is what
  # makes a second backend a day of work instead of a subsystem. The
  # name-to-class registry lives on the Environments module.
  class Environment
    # Backends interleave a command's streams before we ever see them, so one
    # output field is the honest shape.
    ExecResult = Data.define(:command, :exit_code, :output, :duration) do
      def success? = exit_code.zero?
    end

    DEFAULT_TIMEOUT = 60

    attr_reader :image, :resources, :network, :env, :labels, :build_timeout

    # `labels` is backend-agnostic trial metadata (task, trial id, phase);
    # every backend receives it even if it has nowhere to put it.
    def initialize(image:, resources:, network:, env: {}, labels: {}, build_timeout: nil)
      @image = image
      @resources = resources
      @network = network
      @env = env
      @labels = labels
      @build_timeout = build_timeout
    end

    # Build the image and bring the sandbox up under the network policy it was
    # constructed with; a backend that cannot honour the policy must raise.
    def start = raise(NotImplementedError)

    def exec(command, timeout: nil, env: {}) = raise(NotImplementedError)

    def upload(local_path, remote_path) = raise(NotImplementedError)

    def download(remote_path, local_path) = raise(NotImplementedError)

    # Phases change what the sandbox may reach: setup pulls packages, the agent
    # reaches the model API and nothing else, the verifier reaches nothing.
    def switch_network_policy!(policy)
      raise NotImplementedError
    end

    def stop = raise(NotImplementedError)

    def exec!(command, **)
      result = exec(command, **)
      return result if result.success?

      raise InfrastructureError, "#{command} exited #{result.exit_code}: #{result.output.to_s[0, 2000]}"
    end
  end
end

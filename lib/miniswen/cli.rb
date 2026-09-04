# frozen_string_literal: true

require "optparse"
require "fileutils"

require "miniswen/version"
require "miniswen/cli/reporter"

module Miniswen
  class CLI # :nodoc:
    attr_reader :instruction, :model, :options

    def initialize
      @instruction = nil
      @model = ENV.fetch("MINISWEN_MODEL", nil)
      @options = {}
      @verbose = false
      @show_output = false
      @reasoning = true
      @quiet = false
      @results_path = nil
      @atif_path = nil
      @refresh_registry = false
      @skip_registry_refresh = false
    end

    def run
      parse_args!

      # Require the core library after parsing options,
      # so env flags kick in
      require "miniswen"

      refresh_registry_and_exit if @refresh_registry

      Miniswen.refresh_registry! unless @skip_registry_refresh

      require "miniswen/local"

      reporter = @quiet ? nil : Reporter.new(verbose: @verbose, tool_output: @verbose || @show_output, reasoning: @reasoning)
      environment =
        if @docker_id
          require "miniswen/environment/docker"
          Environment::Docker.new(@docker_id)
        else
          Local.new
        end

      agent = Agent.new(model:, reporter:, environment:, **options)

      begin
        result = agent.run(instruction)
      rescue StandardError => e
        write_results(agent.partial_result(error_message(e)))
        raise
      end

      write_results(result)

      if result.success?
        reporter&.print_summary(result)
      else
        reporter&.print_failure(result)
        Kernel.exit(1)
      end
    end

    private

    def write_results(result)
      if @results_path
        FileUtils.mkdir_p(File.dirname(@results_path))
        File.write(@results_path, JSON.generate(result.to_h))
      end

      if @atif_path
        FileUtils.mkdir_p(File.dirname(@atif_path))
        write_atif(result)
      end
    end

    def error_message(error)
      error.is_a?(Miniswen::Error) ? error.message : "#{error.class}: #{error.message}"
    end

    def write_atif(result)
      trajectory = Trajectory.from(result, model: model)
      File.write(@atif_path, JSON.pretty_generate(trajectory.to_atif))
    end

    def refresh_registry_and_exit
      refreshed = Miniswen.refresh_registry!(persist: true)
      $stdout.puts Miniswen.registry_revision if refreshed
      Kernel.exit(refreshed ? 0 : 1)
    end

    def parse_args!
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: miniswen -m MODEL -p INSTRUCTION [...options]"

        opts.on("-m MODEL", "--model=MODEL", String,
                "LLM to use (litellm format, e.g.: openrouter/openai/gpt-5.6-luna") do |v|
          @model = v
        end

        opts.on("-p INSTRUCTION", "--prompt=INSTRUCTION", String, "Instruction prompt") do |v|
          @instruction = File.file?(v) ? File.read(v) : v
        end

        opts.on("--max-steps=STEPS", Integer, "Max steps count") do |v|
          options[:max_steps] = v
        end

        opts.on("--max-cost=COST", Float, "Max cost (USD)") do |v|
          options[:max_cost] = v
        end

        opts.on("--max-time=TIME", Float, "Max inference duration (seconds)") do |v|
          options[:max_time] = v
        end

        opts.on("--exec-timeout=TIMEOUT", Float, "Tool execution timeout (seconds)") do |v|
          options[:exec_timeout] = v
        end

        opts.on("--max-output-tokens=TOKENS", Integer, "Output cap per model call (default: the provider's)") do |v|
          options[:max_output_tokens] = v
        end

        opts.on("-q", "--quiet", "Disable progress output") do
          @quiet = true
        end

        opts.on("--show-output", "Print tool output instead of just the exit status") do
          @show_output = true
        end

        opts.on("--no-reasoning", "Hide the model's reasoning") do
          @reasoning = false
        end

        opts.on("--results-path=PATH", String, "Write the run result as JSON to PATH") do |v|
          @results_path = v
        end

        opts.on("--atif-path=PATH", String, "Write the ATIF trajectory to PATH") do |v|
          @atif_path = v
        end

        opts.on("--docker=ID", String, "Docker container ID to exec commands on") do |v|
          @docker_id = v
        end

        opts.on("--refresh-registry", "Refresh the model registry, persist it, and exit") do
          @refresh_registry = true
        end

        opts.on("--no-refresh-registry", "Skip the model registry refresh on startup") do
          @skip_registry_refresh = true
        end

        opts.on("-v", "--version", "Print version") do
          $stdout.puts Miniswen::VERSION
          exit 0
        end

        opts.on("-vv", "Print verbose logs") do
          @verbose = true
          ENV["MINISWEN_DEBUG"] = "1"
          ENV["RUBYLLM_LOG_LEVEL"] = "debug"
        end
      end

      parser.parse!

      return if @refresh_registry

      raise "Use -m to specify the model" unless @model
      raise "Please, provide instructions via -p option" unless @instruction
    end
  end
end

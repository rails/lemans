# frozen_string_literal: true

require "open3"

require "miniswen/environment"

module Miniswen
  class Environment
    class Docker < self
      TIMEOUT_MARKED_EXIT_CODES = [ 124, 143 ].freeze

      private attr_reader :id

      def initialize(id)
        @id = id
      end

      def exec(command, timeout: nil, env: nil)
        argv = [ "docker", "exec" ]
        env&.each { |key, value| argv += [ "--env", "#{key}=#{value}" ] }
        argv << id
        argv += [ "timeout", timeout.ceil.to_s ] if timeout&.positive?
        argv += [ "sh", "-c", command ]

        Open3.popen2e(*argv) do |stdin, pipe, wait|
          stdin.close
          deadline = (now + timeout + 10 if timeout&.positive?) # add some slack
          output = +""
          timed_out = false

          loop do
            remaining = deadline && deadline - now
            if remaining && remaining <= 0
              timed_out = true
              kill(wait.pid)
              break
            end
            next unless pipe.wait_readable(remaining)

            chunk = pipe.read_nonblock(65_536, exception: false)
            break if chunk.nil?
            next if chunk == :wait_readable

            output << chunk
          end

          status = wait.value
          exit_code = timed_out ? 124 : (status.exitstatus || 1)
          output = output.force_encoding(Encoding::UTF_8).scrub
          if timeout&.positive? && (timed_out || TIMEOUT_MARKED_EXIT_CODES.include?(exit_code))
            output = "#{output}\n<command timed out after #{timeout} seconds>"
          end

          ExecResult.new(exit_code:, output:)
        end
      end

      private

      def kill(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

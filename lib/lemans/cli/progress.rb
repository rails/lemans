# frozen_string_literal: true

module Lemans
  class CLI < Thor
    # The pulse under the streamed statuses: a spinner with live counts, so a
    # long quiet image build reads as work, not a hang. It owns the terminal's
    # last line — event output goes through #record so the two never collide.
    # On a non-tty (CI, a pipe) it draws nothing and only relays the events.
    class Progress
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
      REDRAW_SEC = 0.1

      def initialize(out: $stderr)
        @out = out
        @lock = Mutex.new
        @in_flight = 0
        @done = 0
        @frame = 0
      end

      def start
        return self unless @out.tty?

        @thread = Thread.new do
          loop do
            @lock.synchronize { draw }
            sleep REDRAW_SEC
          end
        end
        self
      end

      # Counts the event and prints its line while the spinner is off-screen:
      # events arrive from worker threads, and two writers on one terminal
      # line is how progress bars end up inside other people's words.
      def record(event)
        @lock.synchronize do
          @in_flight += 1 if event == :started
          if event == :finished
            @in_flight -= 1
            @done += 1
          end
          erase
          yield
          draw if @thread
        end
      end

      def stop
        @thread&.kill
        @thread = nil
        @lock.synchronize { erase }
      end

      private

      def draw
        @frame += 1
        @out.print "\r\e[2K#{FRAMES[@frame % FRAMES.size]} #{@done} done · #{@in_flight} in flight"
      end

      def erase = @out.print("\r\e[2K")
    end
  end
end

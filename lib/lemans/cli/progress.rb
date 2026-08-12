# frozen_string_literal: true

module Lemans
  class CLI < Thor
    # A spinner with live counts that owns the terminal's last line; event output goes through
    # #record so the two never collide. On a non-tty it draws nothing and only relays events.
    class Progress
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
      REDRAW_SEC = 0.1

      def initialize(total:, out: $stderr)
        @total = total
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

      # Prints the event's line while the spinner is off-screen: events arrive from worker
      # threads, and two writers on one terminal line collide.
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
        @out.print "\r\e[2K#{FRAMES[@frame % FRAMES.size]} #{@done}/#{@total} done · #{@in_flight} in flight"
      end

      def erase = @out.print("\r\e[2K")
    end
  end
end

# frozen_string_literal: true

# ============================================================================
# events (from forge events.rb)
# ============================================================================

#
# EO::Engine::Events - in-process pub/sub event bus with blocking await.
#
# The spine of the framework: parsers/hooks emit, actions await, the
# logger/recorder subscribe. Thread-safe: emissions typically arrive from
# Lich's downstream hook thread while awaits block the engine thread.
#
# Depends on nothing (pure Ruby) so it is fully spec-testable.
#
module EO::Engine
  # In-process pub/sub event bus with blocking await; see the file header.
  module Events
    # One emission: its `type` Symbol, the `data` Hash it carried, and the
    # Time `at` which it was emitted.
    #
    # @!attribute type
    #   @return [Symbol] the event name
    # @!attribute data
    #   @return [Hash] the emitter's payload
    # @!attribute at
    #   @return [Time] when it was emitted
    Event = Struct.new(:type, :data, :at, keyword_init: true)

    # A registered wait: `arm` returns one, `wait` blocks on it, `cancel`
    # removes it. The registration lives from `arm` until `cancel`, so an
    # event emitted in between is queued even while nobody is waiting yet.
    class Waiter
      # @return [Hash] the bus's own record: types, matcher and queue
      attr_reader :entry

      # @param bus [Module] Events
      # @param types [Array<Symbol>]
      # @param matcher [Proc, nil]
      def initialize(bus, types, matcher)
        @bus = bus
        @entry = { types: types, matcher: matcher, queue: Queue.new }
      end

      # Block until a queued event or the timeout.
      #
      # @param timeout [Numeric] seconds
      # @return [Event, nil] the first queued event, or nil on timeout
      def wait(timeout:)
        deadline = Time.now + timeout
        loop do
          remaining = deadline - Time.now
          return nil if remaining <= 0

          begin
            return @entry[:queue].pop(true)
          rescue ThreadError
            sleep([remaining, 0.05].min)
          end
        end
      end

      # An event already queued, without waiting.
      #
      # @return [Event, nil]
      def poll
        @entry[:queue].pop(true)
      rescue ThreadError
        nil
      end

      # Remove the registration. Safe to call twice.
      #
      # @return [nil]
      def cancel = @bus.disarm(self)
    end

    @mutex = Mutex.new
    @subscribers = Hash.new { |h, k| h[k] = [] } # type => [callable, ...]
    @any_subscribers = []
    @waiters = [] # [{types:, matcher:, queue:}]

    class << self
      # Subscribe to one or more event types (or :any). Returns the handler
      # (keep it if you want to unsubscribe).
      #
      # @param types [Array<Symbol>] the event types; none, or :any, means every event
      # @yield [event] on each matching emission, inline on the emitting thread
      # @yieldparam event [Event]
      # @return [Proc] the handler, for `off`
      # @raise [ArgumentError] without a block
      def on(*types, &block)
        raise ArgumentError, 'block required' unless block

        @mutex.synchronize do
          if types.empty? || types == [:any]
            @any_subscribers << block
          else
            types.each { |t| @subscribers[t] << block }
          end
        end
        block
      end

      # Unsubscribe a handler from every type it was registered under.
      #
      # @param handler [Proc] what `on` returned
      # @return [nil]
      def off(handler)
        @mutex.synchronize do
          @any_subscribers.delete(handler)
          @subscribers.each_value { |list| list.delete(handler) }
        end
        nil
      end

      # Emit an event. Subscribers run inline on the emitting thread; a
      # subscriber that raises is reported (if a reporter is set) but never
      # breaks other subscribers or the emitter.
      #
      # @param type [Symbol] the event name
      # @param data [Hash] the payload; waiters see it through `Event#data`
      # @return [Event] the event that was emitted
      def emit(type, data = {})
        event = Event.new(type: type, data: data, at: Time.now)
        handlers, waiters = @mutex.synchronize do
          [@subscribers[type].dup + @any_subscribers.dup, @waiters.dup]
        end
        handlers.each do |h|
          begin
            h.call(event)
          rescue StandardError => e
            report_subscriber_error(type, e)
          end
        end
        waiters.each do |w|
          next unless w[:types].include?(type)
          next if w[:matcher] && !safe_match?(w[:matcher], event)

          w[:queue] << event
        end
        event
      end

      # Block until an event of one of +types+ arrives (optionally passing
      # +matcher+, a callable given the event). Returns the Event, or nil on
      # timeout. `arm` then `wait` then `cancel`, for a caller with nothing
      # to do between registering and waiting.
      #
      # @param types [Array<Symbol>] the event types to wait for
      # @param timeout [Numeric] seconds to wait
      # @yield [event] an optional filter; only a true answer releases the wait
      # @yieldparam event [Event]
      # @return [Event, nil] the first matching event, or nil on timeout
      def await(*types, timeout:, &matcher)
        waiter = arm(*types, &matcher)
        waiter.wait(timeout: timeout)
      ensure
        waiter&.cancel
      end

      # Register a waiter for +types+ now and hand it back, so the caller
      # can do something (send a command) before it waits. Events emitted
      # from this call on are queued for it; anything earlier is not, which
      # is what keeps a previous run's fact from confirming this one. The
      # caller must `cancel` it, or `wait` inside a begin/ensure that does.
      #
      # @param types [Array<Symbol>] the event types to wait for
      # @yield [event] an optional filter; only a true answer is queued
      # @yieldparam event [Event]
      # @return [Waiter]
      def arm(*types, &matcher)
        waiter = Waiter.new(self, types, matcher)
        @mutex.synchronize { @waiters << waiter.entry }
        waiter
      end

      # Drop a waiter's registration (Waiter#cancel calls this).
      #
      # @param waiter [Waiter]
      # @return [nil]
      def disarm(waiter)
        @mutex.synchronize { @waiters.delete(waiter.entry) }
        nil
      end

      # Errors raised by subscribers are handed to this callable (e.g. the
      # logger); defaults to silent to keep the bus dependency-free.
      #
      # @return [#call, nil] called with (type, error)
      attr_accessor :error_reporter

      # Drop every subscriber and waiter (specs, and a fresh run of the script).
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @subscribers.clear
          @any_subscribers.clear
          @waiters.clear
        end
      end

      private

      def safe_match?(matcher, event)
        matcher.call(event)
      rescue StandardError
        false
      end

      def report_subscriber_error(type, error)
        error_reporter&.call(type, error)
      end
    end
  end
end

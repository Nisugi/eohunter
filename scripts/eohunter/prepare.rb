# frozen_string_literal: true

# ============================================================================
# prepare (a profile entry that sends a command and awaits a user_ event)
# ============================================================================

#
# EO::Engine::Prepare - the word side of the item-preparation bridge.
#
# Lich's supplement file (lich-5 #1608) lets a player teach the message
# scanner a line and the fact it means: "You feed the crystal and it hums
# softly." becomes a :user_feed_result event carrying ok: true. Watch
# puts that on the bus under its own name. This part is the other half:
# a profile entry names the command to send, the event that answers it
# and what the payload must say, and the word `prepare <name>` runs the
# entry from a routine or a preparation list. The engine learns nothing
# about the item; it is the same action for a feed, a charge or a rub.
#
#   preparations:
#     crystal:
#       perform: feed my crystal      # sent through the refusal ladder
#       result:  user_feed_result     # the bus event that answers it
#       expect:  { ok: true }         # every key must equal; omitted, the event alone confirms
#       timeout: 6                    # seconds; the action default when omitted
#
#   hunting_prep_commands: prepare crystal
#   hunting_commands: 702, prepare crystal(repeatdelay300), attack
#
module EO::Engine
  # The preparation entries: parsed once from the profile, run by name.
  module Prepare
    # A routine or preparation line that runs an entry.
    WORD = /^prepare\s+(\S+)\s*$/i

    # One entry: the command to `perform`, the event that is its `result`,
    # the payload keys to `expect` and the seconds of `timeout`.
    #
    # @!attribute name
    #   @return [String] the key in the profile
    # @!attribute perform
    #   @return [String] the command sent
    # @!attribute result
    #   @return [Symbol] the bus event awaited
    # @!attribute expect
    #   @return [Hash{Symbol => Object}] payload keys and the values they must equal
    # @!attribute timeout
    #   @return [Numeric, nil] seconds; nil for the action's default
    Entry = Struct.new(:name, :perform, :result, :expect, :timeout, keyword_init: true) do
      # True when every expected key is present in +data+ with an equal
      # value. Payload values are what Lich's typed captures made them
      # (Integer, String, Symbol, true/false); the profile's are what YAML
      # made them, so the comparison is on the string form for a Symbol.
      #
      # @param data [Hash] an event's payload
      # @return [Boolean]
      def satisfied_by?(data)
        expect.all? do |key, want|
          next false unless data.key?(key)

          got = data[key]
          got == want || (got.is_a?(Symbol) && got.to_s == want.to_s)
        end
      end
    end

    module_function

    # The profile's `preparations` mapping into Entries, keyed by name.
    # Every entry needs a `perform` command and a `result` event;
    # `expect` must be a mapping and `timeout` a positive number. An
    # entry that is not is an ArgumentError naming it, at profile load.
    #
    # @param raw [Hash, nil] the YAML mapping
    # @return [Hash{String => Entry}]
    # @raise [ArgumentError] naming the entry and what is wrong with it
    def parse(raw)
      return {} if raw.nil?
      raise ArgumentError, 'preparations must be a mapping of name to entry' unless raw.is_a?(Hash)

      raw.to_h do |name, spec|
        raise ArgumentError, "preparations.#{name} must be a mapping" unless spec.is_a?(Hash)

        perform = spec['perform'].to_s.strip
        result = spec['result'].to_s.strip
        raise ArgumentError, "preparations.#{name} needs a perform command" if perform.empty?
        raise ArgumentError, "preparations.#{name} needs a result event" if result.empty?

        expect = spec.fetch('expect', {})
        raise ArgumentError, "preparations.#{name}: expect must be a mapping" unless expect.is_a?(Hash)

        timeout = spec['timeout']
        unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.positive?)
          raise ArgumentError, "preparations.#{name}: timeout must be a positive number of seconds"
        end

        [name.to_s, Entry.new(name: name.to_s, perform: perform, result: result.to_sym,
                              expect: expect.to_h { |k, v| [k.to_sym, v] }, timeout: timeout)]
      end
    end

    # The action for a `prepare <name>` line, or a failed Result for a name
    # the profile does not define. Both dispatch paths (a routine line in
    # Engage, a preparation line in Rest) call this.
    #
    # @param world [World]
    # @param entries [Hash{String => Entry}] the policy's preparations
    # @param name [String] the word's argument
    # @return [Actions::Result]
    def run(world, entries, name)
      entry = entries[name.to_s]
      return Actions::Result.new(status: :failed, reason: :unknown_preparation, line: name.to_s) unless entry

      Actions::Prepare.new(world, entry: entry).call
    end
  end

  module Actions
    # One preparation entry: the command through the ladder, the result
    # event awaited (armed before the send), the payload checked.
    class Prepare < Base
      # @param world [World]
      # @param entry [Prepare::Entry]
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, entry:, **opts)
        super(world, **opts)
        @entry = entry
      end

      # @return [Symbol] :ok, or :dead
      def preconditions = me.dead? ? :dead : :ok

      # @return [Actions::Result] success :confirmed with the event; failed
      #   :denied with the event whose payload did not satisfy `expect`;
      #   timeout :no_confirmation; or the ladder's own failure
      def perform
        result = send_and_await(@entry.perform, @entry.result, timeout: @entry.timeout || DEFAULT_TIMEOUT)
        return result unless result.success?
        return Result.new(status: :success, reason: :confirmed, event: result.event) if @entry.satisfied_by?(result.event.data)

        Result.new(status: :failed, reason: :denied, event: result.event, line: result.event.data[:raw])
      end
    end
  end
end

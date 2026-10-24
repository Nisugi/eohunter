# frozen_string_literal: true

module EO
  module HunterSetup
    # Routine lines the hunt would not run as written, found before it runs.
    #
    # Two kinds, both warnings: the hunt carries on past either, so neither
    # makes a profile invalid.
    #
    # * A line the engine skips. Engage sends anything it does not know to
    #   the game as typed, so an unknown word is not a skip. The skips are
    #   the words Engage hands to Routines (Behaviors::Engage::UNSUPPORTED)
    #   in a shape Routines does not take: `curse sneeze`, `force smite`
    #   without `till N`, a bare `celerity`.
    # * A `script` line naming no installed script, found the way Lich finds
    #   one: exact name first, then any script whose name starts with it.
    #
    # Nothing here runs a routine line.
    module RoutineCheck
      # Settings holding routines.
      KEYS = (%w[hunting_commands] + ('b'..'j').map { |letter| "hunting_commands_#{letter}" } +
              %w[quick_commands disable_commands]).freeze

      # A `script` line, and the script it names.
      SCRIPT = /\Ascript\s+(\S+)/

      module_function

      # @param settings [Hash{String => Object}] the profile's normalized
      #   settings, where a routine is an Array of lines
      # @param scripts [Array<String>, nil] installed script names, without
      #   their extensions; nil when unknown, which skips the script check
      # @return [Array<Hash>] warnings as key, message, kind
      def warnings(settings, scripts: nil)
        KEYS.flat_map do |key|
          lines = ::EO::Engine::Engage::Routine.parse(settings[key])
          lines.filter_map { |line| problem(line.text, scripts) }.uniq
               .map { |message| { 'key' => key, 'message' => message, 'kind' => 'routine' } }
        end
      end

      # @param text [String] a routine line, lowercased, its modifiers off
      # @param scripts [Array<String>, nil] installed script names
      # @return [String, nil] what is wrong with it, or nil
      def problem(text, scripts)
        return nil if text.empty?

        if skipped?(text)
          return "'#{text}' is not a form eohunter runs; the hunt skips this line."
        end

        name = text[SCRIPT, 1]
        return nil if name.nil? || scripts.nil? || installed?(name, scripts)

        "'#{text}': no script named #{name} is installed."
      end

      # Whether Engage would hand the line to Routines and Routines would
      # refuse it. Engage tests ALLY_CAST, PREFIX and SPELL before
      # UNSUPPORTED, so a line any of those take never reaches the skip.
      #
      # @param text [String] a routine line
      # @return [Boolean]
      def skipped?(text)
        engage = ::EO::Engine::Behaviors::Engage
        routines = ::EO::Engine::Engage::Routines
        return false unless engage::UNSUPPORTED.match?(text)
        return false if [engage::ALLY_CAST, routines::PREFIX, engage::SPELL].any? { |shape| shape.match?(text) }

        !routines.handles?(text)
      end

      # @param name [String] the script a line names
      # @param scripts [Array<String>] installed script names
      # @return [Boolean] whether Lich would find a script for it
      def installed?(name, scripts)
        wanted = name.downcase
        scripts.any? { |script| script.downcase.start_with?(wanted) }
      end
    end
  end
end

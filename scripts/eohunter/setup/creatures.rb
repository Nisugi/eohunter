# frozen_string_literal: true

module EO
  module HunterSetup
    # Finding something to hunt, from the installed creature templates.
    #
    # A player arrives knowing their level and how they fight, not which
    # habitat they want: "I am 100 and I put things to sleep" is the question,
    # and the area follows from the answer. So the search is over creatures
    # and the areas are derived, rather than the other way round.
    #
    # The templates carry far more than this uses -- per-circle TDs, AS by
    # attack type, immunities, treasure, the creature's own messaging -- and
    # what is offered here is only what a player chooses a hunt on.
    module Creatures
      module_function

      # Fields populated for nearly every creature, and so safe to filter
      # hard on: a creature missing one is a gap in the catalogue rather than
      # a meaningful answer.
      #
      # Measured across the installed templates: level 95%, family 98%,
      # type 96%, areas 96%, boon-capable 91%.
      RELIABLE = %i[level family type undead boss bcs].freeze

      # Fields catalogued for only some creatures, where nil means NOBODY HAS
      # CHECKED rather than "no".
      #
      # sleepable is known for 45% of creatures, limbs 52%, blood 74%. A
      # filter that treated nil as false would quietly hide half the game --
      # every creature of the Elemental Confluence has sleepable, blood and
      # witherable unrecorded, so a level-95 sleep hunter asking for sleepable
      # creatures would be shown none of them and told nothing about it.
      #
      # So these are three-state, and unknown is kept unless it is excluded on
      # purpose.
      SPARSE = %i[sleepable witherable sympathy muggable blood bones limbs].freeze

      # What each sparse trait is called on an installed CreatureTemplate.
      #
      # They are predicates, and three of them carry a `has_` prefix
      # (creature.rb:237-286). Asking for a bare `sleepable` finds no method
      # and reads nil, so every creature counted as uncatalogued and all seven
      # filters reported the whole band as unknown -- a wrong answer that
      # looked exactly like the right one, since nil IS the unknown value.
      TRAIT_READERS = {
        sleepable: :sleepable?, witherable: :witherable?, sympathy: :sympathy?,
        muggable: :muggable?, blood: :has_blood?, bones: :has_bones?, limbs: :has_limbs?
      }.freeze

      # How far either side of the character's own level to look, before the
      # player says otherwise. Downward is narrower than upward because the
      # question is usually "what can I take on", not "what can I farm".
      LEVEL_BELOW = 5
      LEVEL_ABOVE = 10

      # The level range to open with.
      # @param level [Integer, nil] the character's level
      # @return [Hash] {low:, high:}
      def default_range(level)
        here = level.to_i
        return { low: 1, high: 100 } unless here.positive?

        { low: [here - LEVEL_BELOW, 1].max, high: here + LEVEL_ABOVE }
      end

      # One creature, flattened to what a player chooses on.
      #
      # @param template [#name] an installed CreatureTemplate
      # @return [Hash]
      def describe(template)
        {
          name: value(template, :name).to_s,
          level: value(template, :level),
          family: value(template, :family).to_s,
          type: value(template, :type).to_s,
          undead: value(template, :undead) == true,
          boss: value(template, :boss) == true,
          bcs: value(template, :bcs) == true,
          max_hp: value(template, :max_hp),
          otherclass: Array(value(template, :otherclass)).map(&:to_s),
          areas: Array(value(template, :areas)).filter_map { |area| area_name(area) }.uniq,
          # Kept as written: nil is "not catalogued", and flattening it to
          # false is the whole trap SPARSE exists to describe.
          traits: SPARSE.to_h { |trait| [trait, trait_value(template, trait)] }
        }
      end

      # Every creature, described.
      # @param templates [Enumerable]
      # @return [Array<Hash>]
      def catalogue(templates)
        Array(templates).filter_map do |template|
          entry = describe(template)
          entry unless entry[:name].empty?
        end.sort_by { |entry| [entry[:level] || 0, entry[:name]] }
      end

      # The creatures matching a search.
      #
      # @param entries [Array<Hash>] from catalogue
      # @param query [Hash] any of:
      #   low, high      -- level range, inclusive; nil for open
      #   name           -- substring, case-insensitive
      #   families, types, classes -- lists; empty means any
      #   undead, boss, bcs        -- true/false; nil means either
      #   traits         -- {trait => true/false}, matching SPARSE keys
      #   unknown_traits -- false to exclude creatures whose trait is nil
      # @return [Array<Hash>]
      def search(entries, query = {})
        Array(entries).select { |entry| matches?(entry, query) }
      end

      # @return [Boolean]
      def matches?(entry, query)
        return false unless within_level?(entry, query)
        return false unless named?(entry, query[:name])
        return false unless listed?(entry[:family], query[:families])
        return false unless listed?(entry[:type], query[:types])
        return false unless overlaps?(entry[:otherclass], query[:classes])
        return false unless flagged?(entry, query)

        traited?(entry, query)
      end

      # How many of these creatures have a trait recorded either way.
      #
      # Shown beside a sparse filter so a player can tell "none are sleepable"
      # from "nobody has checked". Without it an empty result is
      # indistinguishable from an uncatalogued one.
      #
      # @param entries [Array<Hash>]
      # @param trait [Symbol]
      # @return [Hash] {yes:, no:, unknown:}
      def trait_tally(entries, trait)
        tally = { yes: 0, no: 0, unknown: 0 }
        Array(entries).each do |entry|
          case entry[:traits][trait]
          when true then tally[:yes] += 1
          when false then tally[:no] += 1
          else tally[:unknown] += 1
          end
        end
        tally
      end

      # The values a filter can offer, from the creatures themselves rather
      # than a list written here: a family added to Lich shows up by itself.
      # @param entries [Array<Hash>]
      # @param field [Symbol] :family, :type
      # @return [Array<String>]
      def values_for(entries, field)
        Array(entries).map { |entry| entry[field].to_s }.reject(&:empty?).uniq.sort
      end

      # Every otherclass any of these creatures carries.
      # @return [Array<String>]
      def classes_for(entries)
        Array(entries).flat_map { |entry| entry[:otherclass] }.reject(&:empty?).uniq.sort
      end

      # The areas these creatures live in, with how many of them are in each.
      #
      # This is the step from "what do I want to fight" to "where do I go":
      # having chosen creatures, the areas holding the most of them are the
      # hunts worth looking at.
      # @param entries [Array<Hash>]
      # @return [Array<Hash>] {name:, creatures:} commonest first
      def areas_for(entries)
        tally = Hash.new { |hash, key| hash[key] = [] }
        Array(entries).each do |entry|
          entry[:areas].each { |area| tally[area] << entry[:name] }
        end
        tally.map { |name, names| { name: name, creatures: names.uniq.sort } }
             .sort_by { |area| [-area[:creatures].size, area[:name]] }
      end

      # @api private
      def within_level?(entry, query)
        level = entry[:level]
        low = query[:low]
        high = query[:high]
        # A creature with no level recorded is shown rather than filtered out:
        # 5% of them have none, and hiding them for a missing field is the
        # same mistake as treating an unknown trait as a no.
        return true if level.nil?

        return false if low && level < low.to_i
        return false if high && level > high.to_i

        true
      end

      # @api private
      def named?(entry, text)
        wanted = text.to_s.strip.downcase
        return true if wanted.empty?

        entry[:name].downcase.include?(wanted)
      end

      # @api private
      def listed?(value, wanted)
        list = Array(wanted).map(&:to_s).reject(&:empty?)
        list.empty? || list.include?(value.to_s)
      end

      # @api private
      def overlaps?(values, wanted)
        list = Array(wanted).map(&:to_s).reject(&:empty?)
        list.empty? || (Array(values).map(&:to_s) & list).any?
      end

      # @api private
      def flagged?(entry, query)
        %i[undead boss bcs].all? do |flag|
          wanted = query[flag]
          wanted.nil? || entry[flag] == wanted
        end
      end

      # @api private
      def traited?(entry, query)
        wanted = query[:traits] || {}
        keep_unknown = query[:unknown_traits] != false
        wanted.all? do |trait, want|
          next true if want.nil?

          held = entry[:traits][trait.to_sym]
          next keep_unknown if held.nil?

          held == want
        end
      end

      # @api private
      def area_name(area)
        name = area.is_a?(Hash) ? (area[:name] || area['name']) : area
        text = name.to_s
        text.empty? ? nil : text
      end

      # A sparse trait, however the template spells it.
      #
      # A Hash carries the plain key (that is how the data files are written);
      # a CreatureTemplate answers the predicate.
      # @api private
      def trait_value(template, trait)
        return template[trait] if template.is_a?(Hash)

        reader = TRAIT_READERS.fetch(trait, trait)
        return template.send(reader) if template.respond_to?(reader)

        value(template, trait)
      rescue StandardError
        nil
      end

      # @api private
      def value(template, field)
        return template[field] if template.is_a?(Hash)

        template.respond_to?(field) ? template.send(field) : nil
      rescue StandardError
        nil
      end
    end
  end
end

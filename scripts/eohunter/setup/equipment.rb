# frozen_string_literal: true

module EO
  module HunterSetup
    # What the character can put in a hand, and what it can shoot.
    #
    # The engine accepts four kinds of hand value: `keep`, `empty`,
    # `ready:<slot>` naming a ReadyList entry, or an item name matched against
    # inventory (loadout.rb, Reference.parse). Typing one correctly means
    # knowing the slot names, so the editor offers them instead.
    #
    # ReadyList comes first, because what the character has READYed is the
    # game's own statement that an item is a weapon or a shield -- it accepted
    # the READY. The pack follows, recognised against Lich's armament tables:
    # gameobj-data.xml types almost nothing as a weapon (its pattern matches
    # bows and a few exotics, so a knife, a falchion and a runestaff are all
    # untyped) and has no shield type at all, while Armaments carries combat
    # statistics for every one of them.
    #
    # Nothing here reaches into Lich: the slots and items are captured once by
    # the script and handed in, the same way creature templates and rooms are.
    module Equipment
      # ReadyList slots a hand can draw from, in the order they are worth
      # trying, with the tag each is labelled by.
      #
      # Both hands take the weapon slots. Only the left is offered a shield: a
      # shield in the weapon hand is not what anyone means, and offering it
      # invites the mistake.
      HAND_SLOTS = {
        'right' => [%w[weapon W], %w[secondary_weapon W2], %w[ranged_weapon R]],
        'left'  => [%w[shield S], %w[weapon W], %w[secondary_weapon W2], %w[ranged_weapon R]]
      }.freeze

      # Slots holding ammunition.
      AMMO_SLOTS = [%w[ammo_bundle A], %w[ammo2_bundle A2]].freeze

      # Slots worth offering when a hand may hold a wand.
      WAND_SLOTS = [%w[wand D]].freeze

      # Item types that can go in a hand. A last resort: the pattern behind
      # this matches bows and little else, which is why the armament tables
      # are consulted first.
      HAND_TYPES = %w[weapon].freeze

      # ...and for ammunition.
      AMMO_TYPES = %w[ammo ammunition].freeze

      # Armament names that are ammunition rather than something to hold.
      #
      # The tables carry one such entry -- "arrow"/"sitka", filed under edged
      # because a swung arrow really is an edged weapon, as the table's own
      # comment says ("when swung, not when fired"). True, and not what a
      # player means when asked what should be in their hands.
      AMMUNITION_NAMES = %w[arrow sitka bolt quarrel].freeze

      # ...and for wands.
      WAND_TYPES = %w[wand].freeze

      module_function

      # The choices for one hand, most useful first.
      #
      # @param hand [String] 'right' or 'left'
      # @param ready [Hash] slot name => what is readied there, or nil
      # @param inventory [Array] carried items
      # @param wands [Boolean] whether to offer wands after the weapons
      # @return [Array<Hash>] option records for a select
      def hand_options(hand, ready: {}, inventory: [], wands: false, armaments: {})
        slots = HAND_SLOTS.fetch(hand.to_s, [])
        slots += WAND_SLOTS if wands
        options = [
          { 'value' => 'keep', 'label' => 'Leave the hand alone' },
          { 'value' => 'empty', 'label' => 'Empty the hand' }
        ]
        # 2.20: named runs rather than one undivided list. What a character
        # has readied and everything else they are carrying are different
        # answers to "what goes in this hand", and they ran together with no
        # seam -- the readied bow and the spare in a pack looked alike.
        readied = grouped(slot_options(slots, ready), READIED_GROUP)
        options.concat(readied)
        types = wands ? HAND_TYPES + WAND_TYPES : HAND_TYPES
        taken = readied_nouns(ready, slots)
        carried = []
        # A shield goes in the off hand, so it is only offered there.
        carried.concat(named_options(inventory, shield_words(armaments), skip: taken)) if hand.to_s == 'left'
        carried.concat(named_options(inventory, weapon_words(armaments),
                                     skip: taken + shown(options) + shown(carried)))
        carried.concat(item_options(inventory, types, skip: taken + shown(options) + shown(carried)))
        options.concat(grouped(carried, CARRIED_GROUP))
        unique(options)
      end

      # Headings for the two runs an equipment list is made of.
      READIED_GROUP = 'Readied'
      CARRIED_GROUP = 'Carried'

      # Put every option under a heading.
      def grouped(options, heading)
        options.map { |option| option.merge('group' => heading) }
      end

      # The names that make an item a weapon, from Lich's armament tables.
      #
      # Falls back to nothing rather than a guess: without the tables the type
      # matching still runs, which finds the bows and misses the rest -- thin,
      # but not a list invented here that would drift from the game's.
      def weapon_words(armaments)
        word_set(armaments, :weapons)
      end

      # ...and a shield. Lich has no shield type at all, so without these a
      # shield is only reachable when it has been readied.
      def shield_words(armaments)
        word_set(armaments, :shields)
      end

      # An armament table as the names it holds, lowercased.
      #
      # Kept whole rather than split into words. Splitting looked tempting --
      # the tables say "long bow" where an item is "a scorched glowbark long
      # bow" -- but a weapon somewhere is made of leather, and matching single
      # words then made "a leather backpack" a weapon. Matching is on the
      # item's own noun, or on a table name appearing in the item's name.
      def word_set(armaments, key)
        names = armaments.is_a?(Hash) ? (armaments[key] || armaments[key.to_s]) : nil
        Array(names).map { |name| name.to_s.downcase.strip }.reject(&:empty?).to_set
      rescue StandardError
        Set.new
      end

      # Items the armament tables name.
      def named_options(inventory, words, skip: [])
        return [] if words.empty?

        offer(inventory, skip: skip) { |item| named?(item, words) }
      end

      # One option per item the block accepts, keyed by its full name.
      #
      # The name, not the noun and not the id.
      #
      # Not the noun, because Stash resolves a wanted item by whole name
      # first, then by part of it, then by noun (stash.rb, match_specificity
      # scores an exact name 0) -- so the name is both the most precise thing
      # the engine can be given and the thing that tells a yew long bow from
      # a glowbark one. The noun made every bow the same choice.
      #
      # Not the id, though it is the only truly unique key: an item's id
      # changes when the character relogs or the server reboots, and a hunt
      # profile is saved to be used next week. It would name nothing by then.
      #
      # So two items with identical names are one choice here, and nothing
      # is lost by that: Stash says so itself -- "items with identical names
      # are interchangeable and collapse to the first" -- and it ranks what
      # it finds by where the item is, hands before ready list before worn
      # before containers, so asking for the name gets the most reachable
      # copy. Two options would have carried the same value and behaved the
      # same way.
      #
      # Deduplicating matters beyond tidiness: a list whose options repeat a
      # value cannot tell them apart.
      def offer(inventory, skip: [])
        seen = skip.map { |name| name.to_s.downcase }
        Array(inventory).filter_map do |item|
          next unless yield(item)

          name = display_name(item)
          next if name.empty? || seen.include?(name.downcase)

          seen << name.downcase
          { 'value' => name, 'label' => name }
        end
      end

      # Whether an item is one of these things.
      #
      # The noun settles it when the tables name it -- "knife", "runestaff",
      # "longbow" are all table entries, and the noun is what the game calls
      # the item when it is alone.
      #
      # Otherwise a multi-word table name has to appear in the item's name as
      # a phrase: "long bow" matches "a scorched glowbark long bow", and the
      # phrase has to end the name or be followed by a word boundary, so a
      # "longbowman's pack" is not a bow. Single-word table names are not
      # tried this way -- that is what made a leather backpack a weapon.
      def named?(item, names)
        return false if container?(item) || ammunition?(item)

        noun = value_of(item, :noun).to_s.downcase.strip
        return true if names.include?(noun)

        text = value_of(item, :name).to_s.downcase
        return false if text.empty?

        names.any? do |name|
          next false unless name.include?(' ')

          text.match?(/(?:\A|\s)#{Regexp.escape(name)}(?:\z|\s)/)
        end
      end

      # The last word on duplicates, whatever the passes above did.
      #
      # A list whose options repeat a value cannot tell them apart. Two items
      # sharing a noun is ordinary (a
      # character carrying faewood and ora arrows has two of `arrows`), so
      # this is not a safety net for a mistake: it is the rule.
      def unique(options)
        seen = {}
        options.reject { |option| seen.key?(option['value']).tap { seen[option['value']] = true } }
      end

      # The values already offered, so a later pass does not repeat one.
      #
      # Values, matching what `offer` deduplicates on: a shield found in the
      # pack and then found again as a weapon would otherwise be two options
      # carrying the same noun.
      def shown(options)
        options.map { |option| option['value'].to_s.downcase }
      end

      # The choices for ammunition.
      #
      # @param ready [Hash] slot name => what is readied there, or nil
      # @param inventory [Array] carried items
      # @return [Array<Hash>] option records for a select
      def ammo_options(ready: {}, inventory: [])
        options = [{ 'value' => '', 'label' => '(none)' }]
        options.concat(grouped(slot_options(AMMO_SLOTS, ready), READIED_GROUP))
        options.concat(grouped(item_options(inventory, AMMO_TYPES,
                                            skip: readied_nouns(ready, AMMO_SLOTS)), CARRIED_GROUP))
        unique(options)
      end

      # Ready slots that actually hold something, labelled by the item.
      #
      # An empty slot is skipped rather than offered: "Shield - nothing
      # readied" is a line that cannot be chosen usefully, and a list of them
      # buries the entries that can. A hunt that wants a slot filled later can
      # still say so by typing it.
      def slot_options(slots, ready)
        slots.filter_map do |(slot, tag)|
          held = ready_noun(ready, slot)
          next if held.nil?

          { 'value' => "ready:#{slot}", 'label' => "[#{tag}] #{held}" }
        end
      end

      # The nouns already reachable through a ready slot, so the same item is
      # not offered twice -- once as its slot and once loose.
      # The nouns already reachable through a ready slot, so the same item is
      # not offered twice -- once as its slot and once loose.
      #
      # The item's name as the pack entries are keyed, so a readied longbow
      # and the same longbow in the pack are recognised as one item.
      def readied_nouns(ready, slots)
        slots.filter_map do |(slot, _tag)|
          entry = ready[slot] || ready[slot.to_s] || ready[slot.to_sym]
          next if entry.nil?

          name = display_name(entry).downcase
          name.empty? ? nil : name
        end
      end

      # Inventory items of the given types, by name, without repeats.
      def item_options(inventory, types, skip: [])
        offer(inventory, skip: skip) { |item| matches_type?(item, types) }
      end

      # What is readied in a slot, named as the player would recognise it.
      def ready_noun(ready, slot)
        entry = ready[slot] || ready[slot.to_sym]
        return nil if entry.nil?

        name = display_name(entry)
        name.empty? ? nil : name
      end

      # An item's full name without its article, falling back to the noun.
      #
      # "a scorched glowbark long bow" reads as "scorched glowbark long bow":
      # the article is noise in a list, and the rest is what distinguishes one
      # bow from another.
      def display_name(item)
        name = value_of(item, :name).to_s.strip.sub(/\A(?:an?|some|the)\s+/i, '')
        name.empty? ? value_of(item, :noun).to_s.strip : name
      end

      # Whether an item carries one of the wanted type tags.
      #
      # A captured record names the field `types`; a live GameObj answers
      # `type`, comma-joined. Both are read, so a harness holding either kind
      # of record behaves the same as the script.
      def matches_type?(item, types)
        return false if container?(item)

        tags = value_of(item, :types) || value_of(item, :type)
        list = tags.is_a?(String) ? tags.split(',') : Array(tags)
        list.map { |tag| tag.to_s.strip.downcase }.any? { |tag| types.include?(tag) }
      end

      # Whether an item holds other things.
      #
      # The inventory feed's own word for it: the item has contents, or it
      # advertises a weight cap. Nothing a hand is told to hold is a container
      # -- and the name cannot settle it, because "disc" is both a thrown
      # weapon in the armament tables and what a player's inventory disc is
      # called. An item captured without the field (the GameObj fallback,
      # which does not report it) is not treated as one.
      def container?(item)
        value_of(item, :container) == true
      end

      # Whether an item is ammunition, which belongs in the ammo setting
      # rather than in a hand.
      def ammunition?(item)
        noun = value_of(item, :noun).to_s.downcase.strip
        return true if AMMUNITION_NAMES.include?(noun)

        words = value_of(item, :name).to_s.downcase.scan(/[a-z']+/)
        words.any? { |word| AMMUNITION_NAMES.include?(word) } ||
          words.any? { |word| AMMUNITION_NAMES.include?(word.sub(/s\z/, '')) }
      end

      # Read a field from a Hash or an object, so a captured record and a live
      # GameObj are both acceptable.
      def value_of(item, field)
        if item.is_a?(Hash)
          item[field] || item[field.to_s]
        elsif item.respond_to?(field)
          item.public_send(field)
        end
      end
    end
  end
end

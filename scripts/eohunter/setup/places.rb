# frozen_string_literal: true

module EO
  module HunterSetup
    # Where a hunt can happen, named as the map names it.
    #
    # A creature template records a broad habitat -- every gigas in the
    # Hinterwilds says "Hinterwilds" -- but their rooms do not overlap: the
    # shield-maiden lives in Ojandhaart, Fjallarhaart and Eldurhaart, and the
    # flayed disciple only in Angargreft. Choosing the habitat gets all four
    # villages' creatures at once, which is not a hunt anyone wants.
    #
    # The subdivision is already in the map. A room title reads
    # "[Ojandhaart, Mid Street]", and the part before the comma is the place.
    # So places are read off the rooms the creatures actually spawn in, rather
    # than curated per area by hand -- AreaZones does that for The Rift, and
    # it cannot be written out for everywhere.
    #
    # A place is only worth offering when it is more specific than the habitat
    # it sits in AND does not simply repeat it, so an undivided area stays one
    # choice rather than becoming two identical ones.
    module Places
      # Rooms below this many in a place are usually a shop or a single
      # landmark rather than somewhere to hunt.
      MINIMUM_ROOMS = 2

      # When a title's second part covers this many rooms, it names an area
      # rather than a room, and the place splits on it.
      #
      # "[Angargreft, Pits of the Dead]" covers 31 rooms and "[Angargreft,
      # Sanguine Grove]" 17: those are separate hunting grounds that share a
      # regional name, and offering "Angargreft" alone means all 98 rooms of
      # them at once. A village's own suffixes name single rooms -- Smithy,
      # Mead Hall, Henge -- and its largest, Fjallarhaart's "Ruins", is five.
      # Above that the second part is doing the work of a place name.
      SUBAREA_ROOMS = 8

      module_function

      # The places within a habitat, by the creatures that spawn there.
      #
      # A place is a connected group of spawn rooms, named after whichever
      # title prefix is commonest in it. Connectivity is what decides
      # membership, not the title: Ojandhaart is the village, and a room
      # titled "Mid Street" that links continuously into it is part of the
      # village even though its title never says so. Grouping by title alone
      # put those rooms nowhere and made the village look a third of its size.
      #
      # @param creatures [Array<Hash>] {name:, room_ids:} per creature
      # @param room_titles [Hash] room id => its title
      # @param neighbours [#call] room id => the ids it links to
      # @return [Array<Hash>] {name:, room_ids:, creature_names:}
      def within(creatures, room_titles, neighbours: nil)
        spawn_rooms = {}
        Array(creatures).each do |creature|
          name = value_of(creature, :name).to_s
          Array(value_of(creature, :room_ids)).each do |id|
            (spawn_rooms[id] ||= []) << name
          end
        end
        return [] if spawn_rooms.empty?

        named = groups(spawn_rooms.keys, neighbours, room_titles).filter_map do |ids|
          name = name_for(ids, room_titles)
          name && [name, ids]
        end
        # Two groups of the same name are one place reached from two spawn
        # points -- a village whose halves are joined through a room the walk
        # would not cross. Keeping them separate would offer "Fjallarhaart"
        # twice, meaning different things.
        merged = Hash.new { |hash, key| hash[key] = [] }
        named.each { |(name, ids)| merged[name].concat(ids) }
        merged.flat_map do |name, ids|
          subdivide(ids.uniq, room_titles).filter_map do |suffix, rooms|
            next if rooms.size < MINIMUM_ROOMS

            creatures_here = rooms.flat_map { |id| spawn_rooms[id] || [] }.uniq.sort
            # A subdivision nothing spawns in is scenery, not a hunt.
            next if creatures_here.empty?

            # Both sets matter. `room_ids` is the place as a player sees it --
            # the village, its smithy included. `spawn_room_ids` is the subset
            # the creature catalogue actually knows about, and resolving
            # against a habitat only accepts those: a room with no creature
            # UID is not part of the resolved habitat, so offering the whole
            # village to `resolve` is refused outright.
            { name: suffix ? "#{name}, #{suffix}" : name, room_ids: rooms.sort,
              spawn_room_ids: rooms.select { |id| spawn_rooms[id] }.sort,
              creature_names: creatures_here }
          end
        end.sort_by { |place| place[:name] }
      end

      # The spawn rooms split into connected groups, grown through the rooms
      # between them.
      #
      # Creatures spawn at scattered points, not in a continuous block: of the
      # nineteen rooms the Hinterwilds gigas spawn in, only two touch another
      # spawn room. The village's own connective tissue -- its smithy, its
      # longhouses, the dock -- holds no spawns at all. Walking spawn rooms
      # alone therefore finds nineteen separate places rather than four.
      #
      # So the walk crosses any room sharing the group's title prefix, and the
      # group is everything it reaches. That is what makes Ojandhaart the
      # village rather than the five rooms whose titles happen to say so.
      #
      # Rooms of another named place are never crossed, which is what keeps
      # the villages apart: they are joined by the open Hinterwilds, and a
      # walk that ignored titles would swallow the whole region in one group.
      def groups(ids, neighbours, room_titles)
        return [ids] if neighbours.nil?

        spawn = ids.to_h { |id| [id, true] }
        unseen = ids.to_h { |id| [id, true] }
        result = []
        until unseen.empty?
          seed = unseen.keys.first
          place = place_of(room_titles[seed])
          result << grow(seed, place, spawn, unseen, neighbours, room_titles)
        end
        result
      end

      # Everything reachable from one spawn room without leaving its place.
      def grow(seed, place, spawn, unseen, neighbours, room_titles)
        queue = [seed]
        seen = {}
        portion = []
        until queue.empty?
          id = queue.pop
          next if seen[id]

          seen[id] = true
          here = place_of(room_titles[id])
          # A room belongs when it is in this place, or is a spawn room with
          # no place of its own -- an unnamed clearing the creatures use.
          belongs = (place && here == place) || (here.nil? && spawn[id])
          next unless belongs

          portion << id
          unseen.delete(id)
          Array(neighbours.call(id)).each { |link| queue << link unless seen[link] }
        end
        portion
      end

      # What to call a group of rooms.
      #
      # The commonest title prefix in it, because a village's own rooms
      # outnumber the unnamed paths threading through it. A tie is broken
      # alphabetically so the same map always produces the same name.
      def name_for(ids, room_titles)
        counts = Hash.new(0)
        ids.each do |id|
          place = place_of(room_titles[id] || room_titles[id.to_i] || room_titles[id.to_s])
          counts[place] += 1 unless place.nil?
        end
        return nil if counts.empty?

        counts.max_by { |place, count| [count, -place.length, place] }&.first
      end

      # Split a group whose title suffixes name areas rather than rooms.
      #
      # Angargreft's rooms are "Pits of the Dead", "Sanguine Grove", "Hanging
      # Gardens" and so on -- each a hunting ground in its own right. Left
      # whole, choosing Angargreft means all of them, which is the same
      # mistake as choosing Hinterwilds meaning all four villages.
      #
      # Only suffixes big enough to be an area split off. The rest stay with
      # the parent, so a village keeps its smithy.
      def subdivide(ids, room_titles)
        by_suffix = ids.group_by { |id| suffix_of(room_titles[id]) }
        areas = by_suffix.select { |suffix, rooms| suffix && rooms.size >= SUBAREA_ROOMS }
        return { nil => ids } if areas.empty?

        rest = ids - areas.values.flatten
        result = areas.transform_keys { |suffix| suffix }
        result[nil] = rest unless rest.empty?
        result
      end

      # The second part of a room title: the room within its place.
      def suffix_of(title)
        text = title.to_s.sub(/\A\[/, '').sub(/\]\z/, '').strip
        parts = text.split(',', 2)
        return nil if parts.size < 2

        name = parts[1].to_s.strip
        name.empty? ? nil : name
      end

      # The place a room title names.
      #
      # "[Ojandhaart, Mid Street]" is Ojandhaart. A title with no comma names
      # the whole area rather than a place inside it, so it groups under its
      # own text -- "The Long Snow" stays "The Long Snow".
      #
      # @param title [String, nil]
      # @return [String, nil]
      def place_of(title)
        text = title.to_s.sub(/\A\[/, '').sub(/\]\z/, '').strip
        return nil if text.empty?

        name = text.split(',').first.to_s.strip
        name.empty? ? nil : name
      end

      # Whether these places say more than the habitat already did.
      #
      # One place covering everything is the habitat under another name, and
      # offering it alongside would be two choices doing one job.
      #
      # @param places [Array<Hash>]
      # @return [Boolean]
      def useful?(places)
        Array(places).size > 1
      end

      # What a search should match against for a habitat: its own name, the
      # places inside it, and every creature that lives there.
      #
      # Searching creatures matters as much as places -- a player is as likely
      # to know what they want to fight as where it lives.
      #
      # @param area [Hash] {name:, creatures:, places:}
      # @return [String] one lowercase haystack
      def haystack(area)
        parts = [value_of(area, :name)]
        parts.concat(Array(value_of(area, :places)).map { |place| value_of(place, :name) })
        parts.concat(Array(value_of(area, :creatures)).map { |creature| value_of(creature, :name) })
        parts.concat(Array(value_of(area, :zones)).map { |zone| value_of(zone, :label) })
        parts.join(' ').downcase
      end

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

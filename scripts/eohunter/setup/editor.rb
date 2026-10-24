# frozen_string_literal: true

module EO
  module HunterSetup
    # The editing session: the draft, what it was loaded from, and the last
    # validation of it.
    #
    # Ruby owns this state and the window is drawn from it. Nothing in
    # this class sends a game command or evaluates a profile expression --
    # execution remains the hunter's job.
    #
    # Callers mutate through the +on_*+ methods, which are what the page's
    # event handlers bind to. Each returns true when the page should be
    # re-rendered.
    class Editor
      # Titles for the schema's own page identities. The identities come from
      # Schema::PAGES rather than being repeated here: a settings page that
      # exists in the schema but not in this table would still get a tab, under
      # a generated title, instead of silently rendering nowhere.
      #
      # They label the sidebar, so they can say what the page is for.
      TITLES = {
        'area' => 'Areas & creatures', 'hunting' => 'Hunting behavior',
        'rest' => 'Rest & services', 'recovery' => 'Recovery & emergencies',
        'monitoring' => 'Monitoring', 'combat' => 'Combat plans',
        'equipment' => 'Equipment', 'buffs' => 'Buffs',
        'preparations' => 'Preparations & commands', 'team' => 'Multi-account team'
      }.freeze

      # Settings pages, in the schema's own order.
      SETTINGS_PAGES = Schema::PAGES.keys.freeze

      # The sidebar's sections, each naming the pages beneath it.
      #
      # The grouping is the one worked out in the design discussion -- profile
      # management, then the hunt itself, then how a fight is fought, then the
      # settings that only matter with other people.
      SECTIONS = [
        ['Profiles', %w[manage]],
        ['Hunting & recovery', %w[area hunting rest recovery monitoring]],
        ['Combat & equipment', %w[combat equipment buffs preparations]],
        ['Hunting with others', %w[team]],
        ['Finish', %w[review]]
      ].freeze

      # Pages that are not settings pages, with their titles and the section
      # they sit under.
      # Compare, from the design sketch, is deliberately absent: there is no
      # comparison page yet, and a sidebar item leading nowhere is worse than
      # one that is missing.
      EXTRA_TITLES = {
        'manage' => 'Manage profiles', 'review' => 'Review & save'
      }.freeze

      # The sidebar's items, in section order: id, label, section.
      #
      # Built from SECTIONS so a page named there but missing from the schema
      # cannot appear as an item leading nowhere.
      NAV_ITEMS = SECTIONS.flat_map do |(section, pages)|
        pages.filter_map do |page|
          next if SETTINGS_PAGES.none?(page) && !EXTRA_TITLES.key?(page)

          title = EXTRA_TITLES[page] || TITLES[page] || page.split('_').map(&:capitalize).join(' ')
          { id: page, label: title, section: section }
        end
      end.freeze

      # The guided path: five steps, each a plain-language question rather than
      # a settings page. Each step names the handful of settings it asks about,
      # grouped under the question it answers -- the point of the wizard is
      # that it does NOT show all 119 fields.
      STEPS = [
        # Where and what, first.
        #
        # This asked for the hands first, and nobody opens a hunt editor
        # thinking about their left hand -- they arrive wanting to hunt
        # somewhere. Leading with the area also puts the two in the order
        # they depend on: which weapon a player wants follows from what they
        # are fighting, not the other way round.
        { id: 'area', title: 'Area & creatures', hint: 'Where and what to hunt',
          groups: [['What do you want to hunt?', %w[targets invalid_targets always_flee_from]],
                   ['Use room numbers from your map', %w[hunting_room_id hunting_boundaries]]] },
        { id: 'character', title: 'Your character', hint: 'Equipment and usual settings',
          # No ammunition group. `ammo` and `ammo_container` are from an older
          # game: the ready list sets what a character fires, and ammunition
          # that needs putting away gets a STOW. Both settings still exist in
          # the full editor for a hunt that has them.
          groups: [['What should be in your hands?', %w[hunting_right_hand hunting_left_hand]]] },
        { id: 'combat', title: 'Combat approach', hint: 'Usual sequence and exceptions',
          groups: [['What do you do to a creature?', %w[hunting_commands]],
                   ['How many creatures can you handle?', %w[flee_count lone_targets_only]],
                   ['How do you stand and move?', %w[hunting_stance wander_stance]]] },
        { id: 'rest', title: 'Rest & recovery', hint: 'When to return and recover',
          groups: [['Where will you recover?', %w[resting_room_id field_rest_room_id]],
                   ['When should you return?', %w[fried oom encumbered]],
                   ['What happens at rest?', %w[resting_scripts resting_commands]],
                   ['When should hunting resume?', %w[rest_till_exp rest_till_mana]]] },
        { id: 'review', title: 'Review & save', hint: 'Check the whole plan', groups: [] }
      ].freeze

      # @return [Array<String>] the step identities, in order
      STEP_IDS = STEPS.map { |step| step[:id] }.freeze

      attr_reader :app, :boot, :draft, :name, :kind, :revision, :validation, :status, :status_error,
                  :pending_delete

      # @param app [App] transport-independent editor operations
      def initialize(app:)
        @app = app
        @boot = app.call('action' => 'bootstrap')
        @kind = 'profiles'
        @name = ''
        @loaded_name = ''
        @revision = nil
        @draft = { 'schema_version' => 1, 'settings' => {} }
        @baseline = deep_copy(@draft)
        @validation = nil
        @map = nil
        @status = nil
        @status_error = false
        @pending_delete = nil
      end

      # Ask to delete a document. Holds the preview -- revision and what
      # depends on it -- so the confirmation can say what is at stake, and so
      # the delete is checked against the document as it was when asked about.
      # @param name [String] document basename
      # @param kind [String] document kind
      # @return [Boolean] whether to re-render
      def on_request_delete(name, kind: 'profiles')
        preview = delete_preview(name, kind: kind)
        return true unless preview

        @pending_delete = preview.merge(kind: kind, name: name)
        true
      end

      # Abandon a delete that was asked about but not confirmed.
      # @return [Boolean] whether to re-render
      def on_cancel_delete
        @pending_delete = nil
        true
      end

      # Carry out the delete the pending preview describes.
      # @return [Boolean] whether to re-render
      def on_confirm_delete
        pending = @pending_delete
        return true unless pending

        @pending_delete = nil
        on_delete(pending[:name], pending[:revision], kind: pending[:kind])
      end

      # @return [Boolean] whether the guided path is showing
      def guided? = @guided == true

      # @return [String] the step being shown
      def step = @step ||= STEP_IDS.first

      # @return [Integer] its 1-based position, for "step N of 5"
      def step_number = STEP_IDS.index(step).to_i + 1

      # Whether every setting a step asks about has been given a value.
      #
      # "Answered", not "valid": the wizard marks a step done when the player
      # has said something for each of its questions. Validation is the Review
      # step's job, and a step marked done can still hold a value the engine
      # will reject.
      # @param id [String] step identity
      # @return [Boolean]
      def step_answered?(id)
        definition = STEPS.find { |entry| entry[:id] == id.to_s }
        keys = Array(definition && definition[:groups]).flat_map { |(_question, fields)| Array(fields) }
        return false if keys.empty?

        keys.all? { |key| !settings[key].to_s.strip.empty? }
      end

      # @return [Hash] the current step's definition
      def step_definition = STEPS.find { |entry| entry[:id] == step } || STEPS.first

      # Enter or leave the guided path. Both views edit the same draft: the
      # wizard is a way through the settings, not a separate document.
      # @return [Boolean] whether to re-render
      def on_toggle_guided
        @guided = !guided?
        @step = STEP_IDS.first if guided?
        note(guided? ? 'Wizard. The same draft, one question at a time.' : 'Full editor.')
      end

      # Show a particular step.
      # @param id [String] step identity
      # @return [Boolean] whether to re-render
      def on_step(id)
        return false unless STEP_IDS.include?(id.to_s)

        @step = id.to_s
        true
      end

      # Move one step along, stopping at either end.
      # @param offset [Integer] -1 back, 1 forward
      # @return [Boolean] whether to re-render
      def on_step_by(offset)
        index = STEP_IDS.index(step).to_i + offset
        return false unless index.between?(0, STEP_IDS.size - 1)

        @step = STEP_IDS[index]
        true
      end

      # @return [Array<Hash>] every field descriptor the schema publishes
      def fields = @boot[:fields] || @boot['fields'] || []

      # @param page [String] settings page identity
      # @return [Array<Hash>] that page's field descriptors, schema order
      def fields_for(page)
        fields.select { |field| field['page'] == page }
      end

      # @return [Hash] this draft's settings, never nil
      def settings = @draft['settings'] ||= {}

      # @return [Boolean] whether the draft differs from what was loaded
      def dirty?
        @draft != @baseline || @name != @loaded_name
      end

      # @return [Array<String>] native profile names
      def profiles = Array(@boot[:profiles] || @boot['profiles'])

      # @return [Hash] ReadyList slots and what is readied in them
      def ready_list = @boot[:ready_list] || @boot['ready_list'] || {}

      # @return [Array] carried items, for the hand and ammunition pickers
      def inventory = Array(@boot[:inventory] || @boot['inventory'])

      # Replace the equipment the pickers offer.
      #
      # The editor opens before the game has been asked for a ready list or an
      # inventory, because both block and neither is worth an unresponsive
      # window. This is how the answers reach the pickers when they arrive.
      # @param ready_list [Hash] ReadyList slots and what is in them
      # @param inventory [Array] carried items
      # @return [void]
      def equipment=(replacement)
        @boot = @boot.merge(
          ready_list: replacement[:ready_list] || ready_list,
          inventory: replacement[:inventory] || inventory
        )
      end

      # Choose a hand or ammunition value from the picker.
      #
      # The "something else" choice is not a value: it clears the setting and
      # lets the text field beside it carry what is typed. Clearing rather
      # than keeping the old value is deliberate -- the player has just said
      # the old value was not what they meant.
      # @param key [String] setting key
      # @param value [String] chosen option value
      # @return [Boolean] whether to re-render
      def on_equipment(key, value)
        on_change(key, value.to_s == Page::OTHER ? '' : value)
        true
      end

      # The choices for a setting the character's own equipment can answer.
      #
      # Returns nil for every other setting, which is how the renderer decides
      # between a picker and a plain text field.
      # @param key [String] setting key
      # @return [Array<Hash>, nil] option records
      def equipment_options(key)
        case key.to_s
        when 'hunting_right_hand'
          Equipment.hand_options('right', ready: ready_list, inventory: inventory, armaments: armaments)
        when 'hunting_left_hand'
          Equipment.hand_options('left', ready: ready_list, inventory: inventory, armaments: armaments)
        when 'ammo'
          Equipment.ammo_options(ready: ready_list, inventory: inventory)
        end
      end

      # @return [Hash] Lich's weapon and shield name tables, which is how an
      #   item is recognised when the type data does not name it
      def armaments = @boot[:armaments] || @boot['armaments'] || {}

      # @return [Array<String>] read-only Bigshot profiles, openable as copies
      def legacy_profiles = Array(@boot[:legacy_profiles] || @boot['legacy_profiles'])

      # @return [Hash] hidden names and the argument-free launch default
      def visibility
        @boot[:profile_visibility] || @boot['profile_visibility'] || {}
      end

      # @return [String, nil] the profile a bare ;eohunter starts
      def active_profile = visibility[:active_profile] || visibility['active_profile']

      # @param name [String] profile basename
      # @param source [Symbol] :native or :legacy
      # @return [Boolean] whether the list hides this name
      def hidden?(name, source: :native)
        hidden = visibility[:hidden] || visibility['hidden'] || {}
        Array(hidden[source.to_s]).include?(name)
      end

      # Choose the profile an argument-free `;eohunter` starts. Selecting one
      # never starts a hunt.
      # @param name [String, nil] profile basename, or nil to clear
      # @return [Boolean] whether to re-render
      def on_set_active(name)
        @app.call('action' => 'set_active_profile', 'name' => name,
                  'revision' => visibility[:revision] || visibility['revision'])
        refresh_boot
        note(name ? "#{name} is now the default hunt. This did not start it." : 'Cleared the default hunt.')
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Hide or show a name in the list, without touching either profile.
      # @param name [String] profile basename
      # @param hidden [Boolean] desired state
      # @param source [Symbol] :native or :legacy
      # @return [Boolean] whether to re-render
      def on_set_hidden(name, hidden, source: :native)
        @app.call('action' => 'profile_visibility', 'name' => name, 'source' => source.to_s,
                  'hidden' => hidden, 'revision' => visibility[:revision] || visibility['revision'])
        refresh_boot
        note("#{hidden ? 'Hid' : 'Restored'} #{name}.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # What deleting this document would take with it. Asked before the
      # confirmation dialog, so the dialog can say what is at stake.
      # @param name [String] document basename
      # @param kind [String] document kind
      # @return [Hash, nil] revision, dependents and legacy fallback
      def delete_preview(name, kind: 'profiles')
        @app.call('action' => 'delete_preview', 'kind' => kind, 'name' => name)
      rescue StandardError => error
        note(error.message, error: true)
        nil
      end

      # Delete a native document, keeping a recoverable backup. Requires the
      # revision from the preview, so a document edited in between is refused.
      # @param name [String] document basename
      # @param revision [String] digest from delete_preview
      # @param kind [String] document kind
      # @return [Boolean] whether to re-render
      def on_delete(name, revision, kind: 'profiles')
        @app.call('action' => 'delete_document', 'kind' => kind, 'name' => name,
                  'revision' => revision, 'confirm' => true)
        refresh_boot
        if @loaded_name == name && @kind == kind
          @name = ''
          @loaded_name = ''
          @revision = nil
          @draft = { 'schema_version' => 1, 'settings' => {} }
          @baseline = deep_copy(@draft)
        end
        note("Deleted #{name}. A backup was kept.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Start a new, empty draft. Nothing is written until it is saved.
      # @return [Boolean] whether to re-render
      def on_new
        @kind = 'profiles'
        @name = ''
        @loaded_name = ''
        @revision = nil
        @draft = { 'schema_version' => 1, 'settings' => {} }
        @baseline = deep_copy(@draft)
        @validation = nil
        @map = nil
        note('Started a new hunt. Name it, then save.')
      end

      # Open a read-only Bigshot profile as an unsaved copy. The original is
      # never written to: saving creates an EOHunter-owned document.
      # @param name [String] legacy basename
      # @return [Boolean] whether to re-render
      def on_copy_legacy(name)
        document = @app.call('action' => 'read', 'kind' => 'profiles', 'name' => name, 'source' => 'legacy')
        @kind = 'profiles'
        @name = name
        @loaded_name = ''
        @revision = nil
        # A Bigshot profile is the settings themselves, one flat mapping; an
        # EOHunter hunt holds them under `settings`. Left flat, every key sat
        # beside `settings` where no control looks, and the copy opened empty.
        data = document[:data] || {}
        data = { 'schema_version' => 1, 'settings' => data } unless data.key?('settings')
        # Only what eohunter reads comes across. The hunt it saves is not a
        # Bigshot profile and is not kept compatible with one, so Bigshot's
        # bookkeeping and the features eohunter does not have would be
        # carried for nothing. Empty values are unset in all but name.
        known = fields.to_set { |field| field['key'] }
        kept, dropped = data['settings'].to_h.partition do |key, value|
          known.include?(key) && !(value.nil? || value == '')
        end
        data['settings'] = kept.to_h
        @draft = data
        @baseline = { 'schema_version' => 1, 'settings' => {} }
        @validation = nil
        @map = nil
        unused = dropped.count { |(key, _)| !known.include?(key) }
        left = unused.zero? ? '' : " Left out #{unused} Bigshot setting#{'s' if unused != 1} eohunter does not use."
        note("Opened the Bigshot profile #{name} as a copy. Saving creates an EOHunter hunt; " \
             "the original is left alone.#{left}")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Load a stored document into the draft, replacing anything unsaved.
      # @param name [String] document basename
      # @param kind [String] profiles, defaults, plans or injury_policies
      # @return [Boolean] whether to re-render
      def on_load(name, kind: 'profiles')
        document = @app.call('action' => 'read', 'kind' => kind, 'name' => name)
        @kind = kind
        @name = name
        @loaded_name = name
        @revision = document[:revision]
        @draft = document[:data] || { 'schema_version' => 1, 'settings' => {} }
        @baseline = deep_copy(@draft)
        @validation = nil
        @map = nil
        note("Loaded #{name}.")
      rescue StandardError => error
        # The list is rebuilt from disk before the message, so a hunt that has
        # gone missing stops being offered rather than staying on screen with
        # an Edit button that keeps failing.
        refresh_boot
        note("Could not open #{name}: #{error.message}", error: true)
      end

      # Set one setting, or remove it when the value is blank. Removing is how
      # a hunt falls back to its inherited or engine default, so an emptied
      # field must not persist as an empty string.
      # @param key [String] native setting key
      # @param value [Object] cleaned value
      # @return [Boolean] whether to re-render
      def on_change(key, value)
        if value.nil? || value == ''
          settings.delete(key)
        else
          settings[key] = value
        end
        @validation = nil
        @map = nil
        true
      end

      # Hunting areas the installed creature and map data know about, with the
      # creatures and map sheets each one has. Read once: the catalogue is
      # derived from installed data, not from the draft.
      # @return [Array<Hash>] area records, or [] when there is no map data
      def areas
        @areas ||= Array(@app.call('action' => 'areas'))
      rescue StandardError => error
        @area_error = error.message
        @areas = []
      end

      # @return [String] what the area search box holds
      def area_query = @area_query.to_s

      # The areas matching the search, or all of them when it is empty.
      #
      # Matches on the area's name and on the creatures living there, because
      # a player is as likely to know what they want to fight as where.
      # @return [Array<Hash>]
      def area_matches
        terms = area_query.downcase.split
        return areas if terms.empty?

        # Places.haystack, not a hand-rolled one. This read `entry[:zone]` and
        # `entry[:creature_names]`, and an area record carries neither -- it
        # has `zones`, `creatures` and `places` -- so every term but the
        # habitat's own name silently matched nothing. Searching "ojandhaart",
        # a village inside the Hinterwilds, found no area at all.
        areas.select do |entry|
          haystack = Places.haystack(entry)
          terms.all? { |term| haystack.include?(term) }
        end
      end

      # Narrow the area list.
      # @param text [String] search text
      # @return [Boolean] whether to re-render
      def on_area_search(text)
        @area_query = text.to_s
        true
      end

      # --- Finding something to hunt ---------------------------------------
      #
      # The question a player arrives with is "what can I fight", and the
      # area follows from the answer. See Creatures.

      # @return [Integer] the character's level, or 0 when it is not known
      def character_level
        context = @boot[:context] || @boot['context'] || {}
        (context[:level] || context['level']).to_i
      end

      # @return [Hash] the search as it stands
      def hunt_query
        @hunt_query ||= Creatures.default_range(character_level).merge(traits: {})
      end

      # Every creature the installed templates know, described.
      # @return [Array<Hash>]
      def creature_catalogue
        @creature_catalogue ||= Array(@app.call('action' => 'creatures'))
      rescue StandardError => error
        @creature_error = error.message
        @creature_catalogue = []
      end

      # @return [String, nil] why the creature catalogue could not be read
      attr_reader :creature_error

      # The creatures matching the search.
      # @return [Array<Hash>]
      def creature_matches = Creatures.search(creature_catalogue, hunt_query)

      # The areas those creatures live in, the fullest first.
      # @return [Array<Hash>]
      def creature_areas = Creatures.areas_for(creature_matches)

      # Change one part of the search.
      # @param field [Symbol, String] a key of the query
      # @param value [Object] its new value, nil to clear
      # @return [Boolean] whether to re-render
      def on_hunt_filter(field, value)
        key = field.to_sym
        if Creatures::SPARSE.include?(key)
          hunt_query[:traits] = hunt_query[:traits].merge(key => value)
          hunt_query[:traits].compact!
        elsif value.nil? || value == '' || value == []
          hunt_query.delete(key)
        else
          hunt_query[key] = value
        end
        true
      end

      # Choose an area from the finder's table.
      #
      # The row key is the area name run through the page's own key scrubber,
      # so it is matched back rather than parsed.
      # @param key [String] the activated row's key
      # @return [Boolean] whether to re-render
      def on_choose_area_row(key)
        wanted = key.to_s
        name = creature_areas.map { |area| area[:name].to_s }
                             .find { |candidate| Page.row_key('a', candidate) == wanted }
        return false unless name

        on_choose_area(name)
      end

      # @param trait [Symbol] a sparse trait
      # @return [Hash] {yes:, no:, unknown:} over the current matches
      def trait_tally(trait) = Creatures.trait_tally(creature_matches, trait)

      # The named places inside the chosen area, where it has any.
      #
      # A creature template records a broad habitat, so every gigas says
      # "Hinterwilds" while their rooms sit in four separate villages. The
      # places let a hunt name one village rather than all of them.
      # @return [Array<Hash>]
      def places
        entry = areas.find { |candidate| candidate[:name].to_s == area_name.to_s }
        Array(entry && entry[:places])
      end

      # @return [String, nil] the place the hunt is narrowed to
      attr_reader :place

      # @return [Array<String>] the places the hunt is narrowed to
      def places_chosen = Array(@places_chosen)

      # Narrow the area to one of its places, or widen back to all of them.
      #
      # Selecting a place re-resolves with only the creatures that spawn
      # there, which is the whole point: choosing Ojandhaart should not offer
      # Angargreft's disciple.
      # @param name [String, nil] place name, or blank for the whole area
      # @return [Boolean] whether to re-render
      # Choose the hunting area, or clear it.
      #
      # Takes a list of nought or one rather than a name, so a searchable
      # picker can hand over what it holds: there are hundreds of areas.
      # @param names [Array<String>] the chosen area, or empty
      # @return [Boolean] whether to re-render
      def on_choose_areas(names)
        wanted = Array(names).map(&:to_s).reject(&:empty?).uniq
        return on_clear_area if wanted.empty?

        @areas_chosen = wanted
        @place = nil
        @places_chosen = []
        @dispositions = {}
        @area_applied = false
        on_resolve_area(wanted)
      end

      # @return [Array<String>] the area names the hunt covers
      def areas_chosen
        chosen = Array(@areas_chosen)
        return chosen unless chosen.empty?

        name = area_name.to_s
        name.empty? ? [] : [name]
      end

      # Narrow the area to several of its places, or widen back to all.
      #
      # The split is derived from room titles, so it is a good guess rather
      # than a fact -- two villages a player thinks of as one hunt come back
      # as two places, and being made to pick one was the picker imposing its
      # own guess. Several resolve to the union of their creatures and their
      # spawn rooms, which is the same resolve one place does with more in it.
      #
      # @param names [Array<String>] place names, or empty for the whole area
      # @return [Boolean] whether to re-render
      def on_choose_places(names)
        wanted = Array(names).map(&:to_s).reject(&:empty?)
        entries = places.select { |candidate| wanted.include?(candidate[:name].to_s) }
        @places_chosen = entries.map { |entry| entry[:name].to_s }
        # `place` stays the single name where there is one, so everything
        # reading it -- the heading, the applied note -- keeps working, and
        # holds nil for none or several rather than claiming one of them.
        @place = @places_chosen.size == 1 ? @places_chosen.first : nil
        @dispositions = {}
        @area_applied = false
        creatures = entries.empty? ? nil : entries.flat_map { |entry| Array(entry[:creature_names]).map(&:to_s) }.uniq
        rooms = entries.empty? ? nil : entries.flat_map { |entry| Array(entry[:room_ids]) }.uniq
        on_resolve_area(area_name, creature_names: creatures, room_ids: rooms,
                        zone: @area && @area[:zone_id], map_image: @area && @area[:map_image])
      end

      def on_choose_place(name)
        text = name.to_s
        entry = places.find { |candidate| candidate[:name].to_s == text }
        @place = entry && text
        @places_chosen = @place ? [@place] : []
        @dispositions = {}
        @area_applied = false
        creatures = entry ? Array(entry[:creature_names]).map(&:to_s) : nil
        # The place's spawn rooms, not just its creatures. Resolving by
        # creature alone widens back to everywhere those creatures live -- the
        # three Hinterwilds villages share their gigas, so picking one village
        # would otherwise hand back all three.
        #
        # Its spawn rooms rather than all of them: a village's smithy is part
        # of the place but carries no creature UID, and a resolve refuses any
        # room the catalogue does not place in the habitat. The walker fills
        # the rest back in when the footprint is built.
        on_resolve_area(area_name, creature_names: creatures,
                        room_ids: entry ? Array(entry[:room_ids]) : nil,
                        zone: @area && @area[:zone_id], map_image: @area && @area[:map_image])
      end

      # The rooms the chosen place covers, which is what an apply should
      # write rather than the whole habitat's.
      # @return [Array<Integer>]
      def place_room_ids
        chosen_places.flat_map { |entry| Array(entry[:room_ids]) }.uniq
      end

      # The place records the hunt is narrowed to, however many.
      # @return [Array<Hash>]
      def chosen_places
        names = places_chosen
        return [] if names.empty?

        places.select { |candidate| names.include?(candidate[:name].to_s) }
      end

      # Every creature the current area or place offers, for the picker.
      # @return [Array<Hash>] {name:, chosen:}
      def area_creatures
        return [] unless @area

        # The editor's own ticks, not the resolver's selection. Resolving
        # returns every creature as selected, so an area opened with all
        # nineteen ticked and the player's first job was to untick them --
        # and passing an empty list back is not the opposite, it filters the
        # area down to no creatures and no rooms at all.
        #
        # Nothing ticked is not an empty answer either: the engine hunts
        # everything otherwise eligible when the list is empty, so the two
        # say the same thing and this one says it more quietly.
        dispositions = @dispositions ||= {}
        levels = Array(@area[:creatures]).to_h { |creature| [creature[:name].to_s, creature[:level]] }
        narrowed = chosen_places
        offered = if narrowed.empty?
                    Array(@area[:creatures]).map { |creature| creature[:name].to_s }
                  else
                    narrowed.flat_map { |place| Array(place[:creature_names]).map(&:to_s) }
                  end
        # By level, hardest last: a player reading a list of nineteen wants
        # to know what is in it, and the name tells them less than the level.
        offered.uniq
               .sort_by { |name| [levels[name] || 0, name] }
               .map do |name|
                 { name: name, level: levels[name],
                   # Nil, not "leave alone": a creature nobody has said
                   # anything about is unanswered, and the two differ now
                   # that each disposition is a list naming its members.
                   # Defaulting to leave alone would put every creature in
                   # that list, the opposite of what an untouched draft means.
                   disposition: dispositions[name],
                   chosen: dispositions[name] == CREATURE_HUNT }
               end
      end

      # Whether the resolved area has been written into the draft.
      #
      # What the picker was for: once it has been used the step's own
      # settings carry the answer, and the picker can fold away.
      # @return [Boolean]
      def area_applied? = @area_applied == true

      # Choose an area from a card, which is resolving it by name.
      # @param name [String] area name
      # @return [Boolean] whether to re-render
      # Forget the chosen area, so the picker is open again.
      # @return [Boolean] whether to re-render
      def on_clear_area
        @area = nil
        @area_name = nil
        @areas_chosen = []
        @place = nil
        @places_chosen = []
        @dispositions = {}
        @area_applied = false
        true
      end

      # How several area names are carried as one, matching Geography::SEPARATOR.
      AREA_JOIN = ' | '

      def on_choose_area(name)
        @areas_chosen = [name.to_s]
        @place = nil
        @places_chosen = []
        @dispositions = {}
        @area_applied = false
        on_resolve_area(name)
      end

      # @return [String, nil] why the area catalogue could not be read
      attr_reader :area_error

      # @return [Hash, nil] the last resolved area: its rooms, boundaries and
      #   the creatures living there
      attr_reader :area

      # @return [String, nil] the area name the draft names
      # The area being worked on: the one just resolved, or failing that the
      # one the draft already names.
      #
      # Resolving deliberately does not write to the draft -- applying is what
      # does that -- so reading the draft alone meant a freshly chosen area
      # was invisible to everything downstream. The places and the creature
      # list both key off this, so choosing an area drew neither until it had
      # already been applied.
      def area_name = @area_name || @draft['area'] || settings['area']

      # Resolve an area into rooms and boundaries, without writing anything.
      # Nothing here is field-verified; it is a proposal for the player to
      # approve.
      # @param name [String] habitat name
      # @param creature_names [Array<String>, nil] creatures to hunt
      # @param zone [String, nil] named subarea, where one is required
      # @param map_image [String, nil] restrict to one sheet
      # @return [Boolean] whether to re-render
      def on_resolve_area(name, creature_names: nil, zone: nil, map_image: nil, room_ids: nil)
        @area = @app.call('action' => 'area', 'area' => name,
                          'creature_names' => creature_names, 'zone' => zone,
                          'map_image' => map_image, 'room_ids' => room_ids)
        # One name for everything that reads it, however many were resolved.
        @area_name = Array(name).map(&:to_s).reject(&:empty?).join(AREA_JOIN)
        note(area_summary)
      rescue StandardError => error
        @area = nil
        note(error.message, error: true)
      end

      # Put the resolved area into the draft: its start room, boundaries and
      # the creature list. This is the step that actually edits the hunt, and
      # it is deliberately separate from resolving, so nothing changes until
      # the player accepts the proposal.
      # Where a hunt should begin.
      #
      # A room the creatures actually spawn in, not simply the lowest id in
      # the footprint. Many areas stop spawning while nobody is standing in
      # them, so a start room outside the creatures' own rooms -- the far side
      # of an arch, a path in -- means every return walks back into somewhere
      # that has been emptying while it was away.
      #
      # The most central of them, so the first walk out is short in any
      # direction, and the plain first room only when the area names no spawn
      # rooms at all.
      # @param rooms [Array<Integer>] the hunt's footprint
      # @return [Integer]
      def start_room_for(rooms)
        spawns = Array(@area && @area[:spawn_room_ids]).map(&:to_i) & rooms
        return rooms.first if spawns.empty?
        return spawns.first if spawns.size < 3

        middle = spawns.sum / spawns.size.to_f
        spawns.min_by { |id| [(id - middle).abs, id] }
      end

      # @return [Boolean] whether to re-render
      def on_apply_area
        return note('Resolve an area first.', error: true) unless @area

        rooms = Array(@area[:room_ids])
        return note('That area resolved to no mapped rooms.', error: true) if rooms.empty?

        on_change('hunting_room_id', start_room_for(rooms))
        write_list('hunting_boundaries', Array(@area[:boundary_ids]).map(&:to_s))
        by_disposition = Hash.new { |hash, key| hash[key] = [] }
        area_creatures.each { |creature| by_disposition[creature[:disposition]] << creature[:name] }
        # One list per answer, each said out loud.
        #
        # Left alone goes to `invalid_targets` rather than being left implicit.
        # A named `targets` is a whitelist, so in that case the two agree --
        # but the moment a player clears `targets` to hunt everything
        # eligible, silence would turn every creature they had set aside back
        # into a target. Saying it keeps the answer true either way.
        hunted = by_disposition[CREATURE_HUNT]
        write_list('targets', hunted) unless hunted.empty?
        ignored = by_disposition[CREATURE_IGNORE]
        write_list('invalid_targets', ignored) unless ignored.empty?
        avoided = by_disposition[CREATURE_AVOID]
        write_list('always_flee_from', avoided) unless avoided.empty?
        @draft['area'] = @area_name if @area_name
        @area_applied = true
        note("Applied #{@area_name}: #{rooms.size} rooms, #{Array(@area[:boundary_ids]).size} boundaries. " \
             'Area suggestions are not field-verified.')
      end

      # Recompute boundaries for a hand-picked set of rooms, using the same
      # walker the hunt itself uses. Refuses rather than silently widening.
      # @param room_ids [Array<Integer>] the rooms to hunt
      # @param start_room_id [Integer] which one to start in
      # @return [Boolean] whether to re-render
      def on_room_geometry(room_ids, start_room_id)
        result = @app.call('action' => 'room_geometry', 'room_ids' => room_ids,
                           'start_room_id' => start_room_id)
        on_change('hunting_room_id', result[:start_room_id])
        write_list('hunting_boundaries', Array(result[:boundary_ids]).map(&:to_s))
        note("Recomputed: #{Array(result[:room_ids]).size} rooms, #{Array(result[:boundary_ids]).size} boundaries.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # @return [Array<Hash>] named injury policies this character can use
      def injury_policies = Array(@boot[:injury_policies] || @boot['injury_policies'])

      # @return [String, nil] the character-wide injury default
      def character_injury_policy
        preferences = @boot[:character_preferences] || @boot['character_preferences'] || {}
        preferences[:injury_policy] || preferences['injury_policy']
      end

      # Set the character-wide injury default. Running hunts keep the settings
      # they captured.
      # @param name [String, nil] policy name, or nil to clear
      # @return [Boolean] whether to re-render
      def on_set_character_injury_policy(name)
        preferences = @boot[:character_preferences] || @boot['character_preferences'] || {}
        @app.call('action' => 'set_character_injury_policy', 'name' => name,
                  'revision' => preferences[:revision] || preferences['revision'])
        refresh_boot
        note(name ? "#{name} is this character's injury default." : 'Cleared the character injury default.')
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Override the character default for this hunt only, or clear the
      # override. An existing custom wounded_eval stays an override until the
      # player deliberately replaces it.
      # @param name [String, nil] policy name, or nil to inherit
      # @return [Boolean] whether to re-render
      def on_set_hunt_injury_policy(name)
        if name.to_s.empty?
          @draft.delete('injury_policy')
        else
          @draft['injury_policy'] = name.to_s
        end
        @validation = nil
        @map = nil
        note(name.to_s.empty? ? 'This hunt uses the character injury default.' : "This hunt uses #{name}.")
      end

      # Add or remove one creature from the resolution, and re-resolve so the
      # rooms follow the choice.
      # @param name [String] creature name
      # @return [Boolean] whether to re-render
      def on_choose_creature(name)
        return note('Resolve an area first.', error: true) unless @area

        wanted = disposition_for(name) == CREATURE_HUNT ? CREATURE_IGNORE : CREATURE_HUNT
        on_creature_disposition(name, wanted)
      end

      # What a hunt does when it meets a creature.
      #
      # Three settings, three behaviours: `targets` is what it goes after,
      # `invalid_targets` is what it will not deliberately attack, and
      # `always_flee_from` makes it leave the room. They are separate lists
      # in the engine but one decision per creature to a player, so they are
      # asked as one.
      CREATURE_HUNT = 'hunt'
      CREATURE_IGNORE = 'ignore'
      CREATURE_AVOID = 'avoid'

      # In the order they escalate, with what each says.
      CREATURE_DISPOSITIONS = [
        [CREATURE_HUNT, 'Hunt'],
        [CREATURE_IGNORE, 'Leave alone'],
        [CREATURE_AVOID, 'Leave the room']
      ].freeze

      # What this hunt does about one creature.
      # @param name [String] creature name
      # @return [String] one of CREATURE_HUNT, CREATURE_IGNORE, CREATURE_AVOID
      def disposition_for(name)
        (@dispositions ||= {})[name.to_s] || CREATURE_IGNORE
      end

      # Decide what to do about one creature.
      # @param name [String] creature name
      # @param disposition [String] what to do
      # @return [Boolean] whether to re-render
      def on_creature_disposition(name, disposition)
        return note('Resolve an area first.', error: true) unless @area

        wanted = disposition.to_s
        return false unless CREATURE_DISPOSITIONS.any? { |(value, _label)| value == wanted }

        (@dispositions ||= {})[name.to_s] = wanted
        true
      end

      # Set one disposition's whole list at once.
      #
      # A change is the new membership of that list rather than one creature's
      # answer. A creature named here takes this disposition; one that was
      # here and is no longer falls back to hunting, which is what the engine
      # does with a creature it has not been told to avoid.
      #
      # @param disposition [String] one of CREATURE_DISPOSITIONS' values
      # @param names [Array<String>] creatures that now hold it
      # @return [Boolean] whether to re-render
      def on_disposition_list(disposition, names)
        return note('Resolve an area first.', error: true) unless @area

        wanted = disposition.to_s
        return false unless CREATURE_DISPOSITIONS.any? { |(value, _label)| value == wanted }

        listed = Array(names).map(&:to_s).reject(&:empty?)
        @dispositions ||= {}
        # Only this disposition's own entries are rewritten: the other lists
        # are other fields, and a creature absent from this one may well be
        # spoken for by another.
        @dispositions.delete_if { |_name, value| value == wanted }
        listed.each { |name| @dispositions[name] = wanted }
        true
      end

      # Tick every creature, or none of them.
      #
      # None is a real answer, not an empty one: the engine hunts everything
      # otherwise eligible when the list is empty, so clearing it is how a
      # player says "whatever lives here".
      # @return [Boolean] whether to re-render
      def on_choose_all_creatures
        return note('Resolve an area first.', error: true) unless @area

        hunting = area_creatures.any? { |creature| creature[:chosen] }
        @dispositions = area_creatures.to_h do |creature|
          [creature[:name].to_s, hunting ? CREATURE_IGNORE : CREATURE_HUNT]
        end
        true
      end

      # Choose a named subarea, where the habitat requires one.
      # @param zone [String] zone id
      # @return [Boolean] whether to re-render
      def on_choose_zone(zone)
        return note('Resolve an area first.', error: true) unless @area

        on_resolve_area(@area_name, creature_names: Array(@area[:selected_creature_names]),
                                    zone: zone.to_s.empty? ? nil : zone.to_s,
                                    map_image: @area[:map_image])
      end

      # @return [Array<String>] reusable Combat Plans this character has
      def plans = Array(@boot[:plans] || @boot['plans'])

      # @return [Array<Hash>] maneuver words the installed engine knows,
      #   so the editor can offer them without inventing a vocabulary
      def routine_maneuvers = Array(@boot[:routine_maneuvers] || @boot['routine_maneuvers'])

      # Point this hunt at a reusable Combat Plan, or clear the link.
      # @param name [String, nil] plan name
      # @return [Boolean] whether to re-render
      def on_set_combat_plan(name)
        if name.to_s.empty?
          @draft.delete('combat_plan')
        else
          @draft['combat_plan'] = name.to_s
        end
        @validation = nil
        @map = nil
        note(name.to_s.empty? ? 'This hunt uses its own routines.' : "This hunt uses the #{name} plan.")
      end

      # Creature names the draft targets, in the order they are written.
      # @return [Array<String>]
      def target_names
        list_entries('targets').map { |entry| entry.sub(/\([a-j]\)\z/i, '').strip }.reject(&:empty?)
      end

      # Which routine slot a creature uses, if it has its own.
      # @param creature [String] creature name
      # @return [String, nil] a-j
      def routine_slot(creature)
        entry = list_entries('targets').find { |text| text.sub(/\([a-j]\)\z/i, '').strip.casecmp?(creature.to_s) }
        entry.to_s[/\(([b-j])\)\z/i, 1]
      end

      # The command text for a routine slot. 'a' is the hunt's main routine.
      # @param slot [String, nil] a-j
      # @return [String]
      def routine_text(slot)
        key = slot.nil? || slot.to_s.casecmp?('a') ? 'hunting_commands' : "hunting_commands_#{slot.to_s.downcase}"
        settings[key].to_s
      end

      # Give one creature its own action sequence. The native composer picks
      # the slot and rewrites the target list; existing routines are kept.
      # @param creature [String] creature name
      # @param commands [String] the routine text
      # @return [Boolean] whether to re-render
      def on_creature_sequence(creature, commands)
        return note('Give this creature some actions first.', error: true) if commands.to_s.strip.empty?

        result = @app.call('action' => 'creature_sequence', 'data' => @draft,
                           'creature' => creature, 'commands' => commands)
        @draft = result.is_a?(Hash) && result['settings'] ? result : @draft.merge(result || {})
        @validation = nil
        @map = nil
        note("#{creature} now has its own sequence.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # @return [String] the current search text
      def query = @query.to_s

      # Find settings by label, key, help text or a familiar legacy name.
      #
      # @param text [String] search terms
      # @return [Boolean] whether to re-render
      def on_search(text)
        @query = text.to_s.strip
        true
      end

      # @return [Array<Hash>] fields matching every term in the query
      def search_results
        return [] if query.empty?

        terms = query.downcase.split
        fields.select do |field|
          haystack = [field['key'], field['label'], field['help'], *Array(field['aliases'])].join(' ').downcase
          terms.all? { |term| haystack.include?(term) }
        end
      end

      # What this draft changes against what was last loaded, as a list of
      # before/after pairs. Answers "what am I about to save?" without
      # reading two YAML dumps side by side.
      # @return [Array<Hash>] key, before and after
      def changes
        keys = (@baseline['settings'].to_h.keys + settings.keys).uniq.sort
        keys.filter_map do |key|
          before = @baseline['settings'].to_h[key]
          after = settings[key]
          next if before == after

          { 'key' => key, 'before' => before, 'after' => after }
        end
      end

      # Entries of a comma-list setting, in order.
      # @param key [String] native setting key
      # @return [Array<String>]
      def list_entries(key)
        value = settings[key]
        return [] if value.nil?
        return value.map(&:to_s) if value.is_a?(Array)

        value.to_s.split(',').map(&:strip).reject(&:empty?)
      end

      # Replace one entry, dropping it when it is blanked.
      # @param key [String] native setting key
      # @param index [Integer] which entry
      # @param value [String] its new text
      # @return [Boolean] whether to re-render
      def on_list_set(key, index, value)
        entries = list_entries(key)
        return false unless index.between?(0, entries.size - 1)

        text = value.to_s.strip
        text.empty? ? entries.delete_at(index) : entries[index] = text
        write_list(key, entries)
      end

      # Append an entry. Blank input is not an entry.
      # @param key [String] native setting key
      # @param value [String] the new entry
      # @return [Boolean] whether to re-render
      def on_list_add(key, value)
        text = value.to_s.strip
        return false if text.empty?

        write_list(key, list_entries(key) + [text])
      end

      # Replace a list wholesale.
      #
      # Takes the whole list rather than one edit, so adding, removing and reordering all arrive here as the new
      # list. Blanks are dropped and duplicates collapse: the same room named
      # twice is one boundary.
      # @param key [String] native setting key
      # @param values [Array<String>] the list as it now stands
      # @return [Boolean] whether to re-render
      def on_list_set_all(key, values)
        entries = Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
        write_list(key, entries)
      end

      # Fill a list with everything the area offers for it.
      # @param key [String] native setting key
      # @return [Boolean] whether to re-render
      def on_list_fill(key)
        offered = Page.list_suggestions(self, 'key' => key.to_s)
        return false if offered.empty?

        write_list(key, (list_entries(key) + offered).uniq)
      end

      # Empty a list.
      # @param key [String] native setting key
      # @return [Boolean] whether to re-render
      def on_list_clear(key)
        return false if list_entries(key).empty?

        write_list(key, [])
      end

      # Drop one entry.
      # @param key [String] native setting key
      # @param index [Integer] which entry
      # @return [Boolean] whether to re-render
      def on_list_remove(key, index)
        entries = list_entries(key)
        return false unless index.between?(0, entries.size - 1)

        entries.delete_at(index)
        write_list(key, entries)
      end

      # Move an entry. Order is meaningful for scripts and command lists, so
      # this is the reason these are edited as rows rather than one text field.
      # @param key [String] native setting key
      # @param index [Integer] which entry
      # @param offset [Integer] -1 for up, 1 for down
      # @return [Boolean] whether to re-render
      def on_list_move(key, index, offset)
        entries = list_entries(key)
        target = index + offset
        return false unless index.between?(0, entries.size - 1) && target.between?(0, entries.size - 1)

        entries[index], entries[target] = entries[target], entries[index]
        write_list(key, entries)
      end

      # Rename the draft without touching what is on disk. Saving under a new
      # name creates a new document; the original is left alone.
      # @param name [String] new basename
      # @return [Boolean] whether to re-render
      def on_rename(name)
        @name = name.to_s.strip
        true
      end

      # Check the draft against the installed engine, without saving.
      # @return [Boolean] whether to re-render
      def on_validate
        @validation = @app.call('action' => 'validate', 'data' => @draft, 'kind' => @kind)
        note(validation_summary)
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Write the draft, honouring the revision read with it.
      # @return [Boolean] whether to re-render
      def on_save
        return note('Name this hunt before saving.', error: true) if @name.empty?

        saved = @app.call('action' => 'save', 'kind' => @kind, 'name' => @name,
                          'data' => @draft, 'revision' => @revision)
        @revision = saved[:revision]
        @loaded_name = @name
        @baseline = deep_copy(@draft)
        refresh_boot
        note("Saved #{@name}. Saving does not start a hunt.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Discard unsaved edits, returning to the last loaded state.
      # @return [Boolean] whether to re-render
      def on_revert
        @draft = deep_copy(@baseline)
        @name = @loaded_name
        @validation = nil
        @map = nil
        note('Reverted to the last saved version.')
      end

      # What each room role is called.
      ROLE_LABELS = {
        'hunting' => 'Hunting room', 'hunting_boundaries' => 'Boundary',
        'hunting_room_id' => 'Starting room', 'field_rest_room_id' => 'Field rest',
        'resting_room_id' => 'Town rest'
      }.freeze

      # @return [String, nil] the map sheet being looked at
      attr_reader :sheet

      # The area record the map is drawn for, when one has been chosen.
      # @return [Hash, nil]
      def map_area
        return @area if @area.is_a?(Hash) && @area[:maps]

        name = area_name
        return nil if name.to_s.empty?

        areas.find { |entry| entry[:name].to_s == name.to_s }
      end

      # The draft's rooms, laid out on an installed map sheet. Recomputed from
      # the draft rather than cached, so it always describes what is loaded.
      # @return [Hash, nil] markers, rooms and diagnostics, or nil if unavailable
      def map
        # The chosen area anchors which rooms the map shows, so the picture
        # survives a draft with nothing marked in it: see Geography#profile_map.
        @map ||= @app.call('action' => 'profile_map', 'settings' => settings,
                           'sheet' => @sheet, 'area' => map_area)
      rescue StandardError => error
        @map_error = error.message
        nil
      end

      # @return [String, nil] why the map could not be built
      attr_reader :map_error

      # Look at a different sheet without changing the draft.
      # @param sheet [String] map image filename
      # @return [Boolean] whether to re-render
      def on_sheet(sheet)
        @sheet = sheet.to_s.empty? ? nil : sheet.to_s
        @map = nil
        true
      end

      # Which role a room holds, if any.
      # @param id [Integer] room id
      # @return [String, nil] role key
      def role_for(id)
        current = map
        return nil unless current

        markers = current[:markers] || {}
        return 'hunting_room_id' if markers['hunting_room_id'] == id
        return 'hunting_boundaries' if Array(markers['hunting_boundaries']).include?(id)
        return 'field_rest_room_id' if markers['field_rest_room_id'] == id
        return 'resting_room_id' if markers['resting_room_id'] == id
        return 'hunting' if Array(current[:hunting_room_ids]).include?(id)

        nil
      end

      # Put a room in a role, or clear it. A single-room role replaces whatever
      # held it; boundaries are a list, so a room toggles in and out.
      # @param role [String] one of ROLE_LABELS' keys
      # @param id [Integer] room id
      # @return [Boolean] whether to re-render
      def on_assign_room(role, id)
        case role
        when 'hunting_boundaries'
          current = settings['hunting_boundaries']
          list = current.is_a?(Array) ? current.map(&:to_s) : current.to_s.split(',').map(&:strip)
          list.reject!(&:empty?)
          list.include?(id.to_s) ? list.delete(id.to_s) : list << id.to_s
          # A comma string, not an Array: the `rooms` cleaner splits a string,
          # and handed an Array it stringifies it -- ["101"] round-trips as
          # ["[\"101\"]"]. Every list-shaped setting here is stored as text.
          on_change('hunting_boundaries', list.join(', '))
        when 'hunting_room_id', 'field_rest_room_id', 'resting_room_id'
          on_change(role, settings[role].to_s == id.to_s ? '' : id)
        else
          return note("#{role} is not a room role.", error: true)
        end
        @map = nil
        note("#{ROLE_LABELS.fetch(role, role)}: room #{id}.")
      end

      # @return [Array<Hash>] errors from the last validation
      def errors = Array(@validation && (@validation[:errors] || @validation['errors']))

      # @return [Array<Hash>] warnings from the last validation
      def warnings = Array(@validation && (@validation[:warnings] || @validation['warnings']))

      # @param key [String] native setting key
      # @return [String, nil] where this key's effective value came from
      def provenance_for(key)
        table = @validation && (@validation[:provenance] || @validation['provenance'])
        table && table[key]
      end

      private

      # A plain-language account of what an area resolution produced,
      # including what it could not resolve.
      def area_summary
        rooms = Array(@area[:room_ids]).size
        bounds = Array(@area[:boundary_ids]).size
        parts = ["#{@area_name}: #{rooms} rooms, #{bounds} boundaries"]
        parts << 'a named subarea is required before rooms can be suggested' if @area[:zone_selection_required]
        parts << 'incomplete: some rooms or UIDs did not resolve' unless @area[:complete]
        "#{parts.join('; ')}. Not field-verified."
      end

      def refresh_boot
        @boot = @app.call('action' => 'bootstrap')
      end

      # Comma text, never an Array: the engine's split/rooms cleaners split a
      # String and stringify an Array, so a list stored as one round-trips as
      # ["[\"a\"", "\"b\"]"].
      def write_list(key, entries)
        on_change(key, entries.empty? ? '' : entries.join(', '))
      end

      def validation_summary
        return 'Checked: no problems found.' if errors.empty? && warnings.empty?

        parts = []
        parts << "#{errors.size} error#{'s' if errors.size != 1}" unless errors.empty?
        parts << "#{warnings.size} warning#{'s' if warnings.size != 1}" unless warnings.empty?
        "Checked: #{parts.join(', ')}."
      end

      def note(message, error: false)
        @status = message
        @status_error = error
        true
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
        when Array then value.map { |item| deep_copy(item) }
        when String then value.dup
        else value
        end
      end
    end
  end
end

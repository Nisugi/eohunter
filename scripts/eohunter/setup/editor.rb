# frozen_string_literal: true

module EO
  module HunterSetup
    # The editing session: the draft, what it was loaded from, and the last
    # validation of it.
    #
    # Under the browser editor this state lived in JavaScript and was POSTed
    # back; here Ruby owns it and the page is a pure function of it. Nothing in
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
      # Short on purpose: these label one horizontal strip of tabs, not a
      # sidebar -- the client ignores `vertical` -- so a long title pushes the
      # rest of the tabs off the window.
      TITLES = {
        'area' => 'Area', 'hunting' => 'Hunting',
        'rest' => 'Rest', 'recovery' => 'Recovery',
        'monitoring' => 'Monitoring', 'combat' => 'Combat',
        'equipment' => 'Equipment', 'buffs' => 'Buffs',
        'preparations' => 'Items', 'team' => 'Team'
      }.freeze

      # Settings pages, in the schema's own order.
      SETTINGS_PAGES = Schema::PAGES.keys.freeze

      # Every tab: the landing page, each settings page, then review.
      PAGES = ([%w[manage Profiles]] +
               SETTINGS_PAGES.map { |page| [page, TITLES[page] || page.split('_').map(&:capitalize).join(' ')] } +
               [%w[review Review]]).freeze

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
        @draft = document[:data] || { 'schema_version' => 1, 'settings' => {} }
        @baseline = { 'schema_version' => 1, 'settings' => {} }
        @validation = nil
        @map = nil
        note("Opened the Bigshot profile #{name} as a copy. Saving creates an EOHunter hunt; " \
             'the original is left alone.')
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
        note(error.message, error: true)
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

      # Room roles, and the colour each is drawn in. Five roles is more than
      # the contract's four TONES, so these are RGBA. A region carrying no
      # colour is drawn as a plain hit area, which is what an unpatched Lich
      # does with all of them.
      ROLE_COLOURS = {
        'hunting'            => { 'r' => 46, 'g' => 160, 'b' => 67, 'a' => 0.45 },
        'hunting_boundaries' => { 'r' => 214, 'g' => 158, 'b' => 46, 'a' => 0.45 },
        'hunting_room_id'    => { 'r' => 47, 'g' => 109, 'b' => 214, 'a' => 0.55 },
        'field_rest_room_id' => { 'r' => 138, 'g' => 79, 'b' => 201, 'a' => 0.45 },
        'resting_room_id'    => { 'r' => 201, 'g' => 70, 'b' => 120, 'a' => 0.45 }
      }.freeze

      # What each role is called on the map legend.
      ROLE_LABELS = {
        'hunting' => 'Hunting room', 'hunting_boundaries' => 'Boundary',
        'hunting_room_id' => 'Starting room', 'field_rest_room_id' => 'Field rest',
        'resting_room_id' => 'Town rest'
      }.freeze

      # @return [String, nil] the map sheet being looked at
      attr_reader :sheet

      # Whether the map is drawn. Off by default, and deliberately: the
      # client renders every tab panel and hides the inactive ones, so a
      # 496-layer sheet costs ~60 ms on *every* render -- including a keystroke
      # on an unrelated page. Drawing it on request keeps the rest of the
      # editor at ~25 ms.
      def map_open? = @map_open == true

      # Show or hide the map.
      # @return [Boolean] whether to re-render
      def on_toggle_map
        @map_open = !map_open?
        @map = nil unless @map_open
        true
      end

      # @return [String] the role a left-click on the map assigns
      def assign_role = @assign_role ||= 'hunting_room_id'

      # Choose what a left-click assigns.
      # @param role [String] one of ROLE_COLOURS' keys
      # @return [Boolean] whether to re-render
      def on_assign_role(role)
        return note("#{role} is not a room role.", error: true) unless ROLE_COLOURS.key?(role.to_s)

        @assign_role = role.to_s
        true
      end

      # A click on the map. Left assigns the selected role, right clears
      # whatever role the room holds -- so a room can be taken out of the hunt
      # without first selecting the role it happens to be in.
      # @param region [String, nil] the clicked region key, "room-<id>"
      # @param button [String] primary or secondary
      # @return [Boolean] whether to re-render
      def on_map_click(region, button)
        id = region.to_s[/\Aroom-(\d+)\z/, 1]
        # A click on the sheet between rooms is not an error; it just misses.
        return false unless id

        id = id.to_i
        return on_assign_room(assign_role, id) unless button.to_s == 'secondary'

        role = role_for(id)
        return note("Room #{id} has no role to clear.") unless role && role != 'hunting'

        on_assign_room(role, id)
      end

      # The draft's rooms, laid out on an installed map sheet. Recomputed from
      # the draft rather than cached, so it always describes what is loaded.
      # @return [Hash, nil] markers, rooms and diagnostics, or nil if unavailable
      def map
        @map ||= @app.call('action' => 'profile_map', 'settings' => settings, 'sheet' => @sheet)
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

      # Which role a room is drawn as, if any.
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
      # @param role [String] one of ROLE_COLOURS' keys
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

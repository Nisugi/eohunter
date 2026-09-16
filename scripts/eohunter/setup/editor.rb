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
      TITLES = {
        'area' => 'Area & creatures', 'hunting' => 'Hunting behavior',
        'rest' => 'Rest & services', 'recovery' => 'Recovery & emergencies',
        'monitoring' => 'Monitoring & limits', 'combat' => 'Combat Plans',
        'equipment' => 'Equipment', 'buffs' => 'Buffs',
        'preparations' => 'Item preparations', 'team' => 'Multi-Account Team'
      }.freeze

      # Settings pages, in the schema's own order.
      SETTINGS_PAGES = Schema::PAGES.keys.freeze

      # Every tab: the landing page, each settings page, then review.
      PAGES = ([%w[manage Profiles]] +
               SETTINGS_PAGES.map { |page| [page, TITLES[page] || page.split('_').map(&:capitalize).join(' ')] } +
               [['review', 'Review & save']]).freeze

      attr_reader :app, :boot, :draft, :name, :kind, :revision, :validation, :status, :status_error

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
        @status = nil
        @status_error = false
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

      # @return [Array<String>] native profile names, hidden ones excluded
      def profiles = Array(@boot[:profiles] || @boot['profiles'])

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
        true
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
        note('Reverted to the last saved version.')
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

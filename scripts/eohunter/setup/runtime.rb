# frozen_string_literal: true

module EO
  module HunterSetup
    # Native script adapter: loads policy definitions, snapshots read-only game
    # data, and owns this script's WebUI page without starting or altering a
    # hunt.
    module Runtime
      # Setup's own modules, in dependency order; shared readers load first.
      SETUP_PARTS = %w[
        store composition schema society_abilities area_catalog_data
        area_catalog area_zones geography hazards app editor page
      ].freeze

      # The engine part list, read out of engine.rb without executing it.
      #
      # engine.rb ends in a bare `EO::Engine.load_parts`, so requiring it to
      # reach PARTS would reload every policy under a running hunt. Scraping
      # the literal keeps one authoritative list -- a part added to the engine
      # is picked up here -- without that side effect.
      PARTS_PATTERN = /PARTS\s*=\s*%w\[(.*?)\]/m

      module_function

      # Policy classes the editor reads metadata from. Loading these files
      # defines classes only.
      # @param script_dir [String] Lich script directory
      # @return [Array<String>] the part names loaded
      def profile_parts(script_dir)
        source = File.read(File.join(script_dir, 'eohunter', 'engine.rb'))
        match = source.match(PARTS_PATTERN)
        raise "cannot read EO::Engine::PARTS from engine.rb" unless match

        match[1].split
      end

      # Reuse the running hunt's policy classes, if present, without reloading.
      # @param script_dir [String] Lich script directory
      # @return [void]
      def load_support(script_dir)
        dir = File.join(script_dir, 'eohunter')
        unless defined?(::EO::Engine::Profile)
          ::EO.const_set(:Engine, Module.new) unless defined?(::EO::Engine)
          profile_parts(script_dir).each { |part| load File.join(dir, "#{part}.rb") }
        end
        SETUP_PARTS.each do |part|
          name = part.split('_').map(&:capitalize).join
          require File.join(dir, 'setup', "#{part}.rb") unless HunterSetup.const_defined?(name, false)
        end
      end

      # Build the editor's operations against this character's native storage
      # and read-only map and recovery inputs.
      #
      # @param data_dir [String] Lich data directory
      # @param game [String] active game instance
      # @param character [String] active character name
      # @param char_settings [Hash] read-only compatibility defaults
      # @param templates [Enumerable] native creature records
      # @param rooms [Enumerable] native map records
      # @param uid_resolver [#call] native UID lookup, without travel
      # @return [App] transport-independent editor operations
      def app(data_dir:, game:, character:, char_settings:, templates:, rooms:, uid_resolver:)
        root = File.join(data_dir, game, character)
        store = Store.new(root: File.join(root, 'eohunter'), legacy_root: File.join(root, 'bigshot_profiles'))
        schema = Schema.new(profile_class: EO::Engine::Profile, cleanse_policy_class: EO::Engine::Cleanse::Policy)
        room_list = rooms.to_a.compact
        room_index = room_list.to_h { |room| [room.id.to_i, room] }
        geography = Geography.new(templates: templates, rooms: room_list, uid_resolver: uid_resolver)
        recovery_path = File.join(root, 'ecleanse.yaml')
        recovery = EO::Engine::Cleanse::Policy.load(recovery_path, char_settings: char_settings)
        # Resolving a hunt's *effective* recovery needs Profile#recovery_policy,
        # which not every engine has. App treats a nil resolver as "cannot
        # resolve" and simply omits the resolved policy, so offer one only when
        # the installed engine can answer.
        recovery_resolver = if EO::Engine::Profile.method_defined?(:recovery_policy)
                              lambda do |raw|
                                EO::Engine::Profile.new(raw, uid_ids: uid_resolver)
                                                   .recovery_policy(path: recovery_path, char_settings: char_settings).to_h
                              end
                            end
        App.new(store: store, schema: schema, geography: geography,
                context: { character: character, game: game }, recovery_fallback: recovery.to_h,
                uid_ids: uid_resolver, room_lookup: ->(id) { room_index[id.to_i] },
                hazards: Hazards.new(profile_class: EO::Engine::Profile),
                recovery_resolver: recovery_resolver,
                society_abilities: SocietyAbilities.capture)
      end
    end
  end
end

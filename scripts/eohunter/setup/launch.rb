# frozen_string_literal: true

module EO
  module HunterSetup
    # One run of the editor: reads what the character has, opens the window
    # and waits for it to close.
    #
    # The only part of setup that reaches into Lich. Everything it reads is
    # captured here and handed to Runtime.app, so the rest stays testable
    # without a game.
    module Launch
      # Weapon categories a character cannot pick up and hold: `natural` is
      # bite, claw, pincer and stinger. Excluded rather than the others
      # listed, so a category added to Lich later is offered by default.
      NON_ITEM_CATEGORIES = %i[natural].freeze

      module_function

      # Open the editor and block until the viewer closes it.
      #
      # @param script_dir [String] Lich script directory
      # @param context [Binding] where the hunt evaluates its Ruby conditions
      #   (eohunter.lic's top level), so Test now runs them the same way
      # @return [void]
      def run(script_dir:, context:)
        raise 'the editor needs GTK, and this Lich was started without it' unless defined?(Gtk.queue)

        load File.join(script_dir, 'eohunter', 'setup', 'window.rb')
        editor = Editor.new(app: app)
        closed = Queue.new
        window = nil
        # Killing the script closes the window. Registered against the script
        # this runs on, as Lich's before_dying does.
        Script.at_exit { Gtk.queue { window&.close } }
        Gtk.queue do
          window = Window.new(editor: editor, title: "eohunter setup - #{Char.name}",
                              on_close: -> { closed << true },
                              evaluate: ->(code) { eval(code, context) }) # -- Test now, on the viewer's own condition
          window.show
        rescue StandardError => error
          closed << error
        end
        result = closed.pop
        raise result if result.is_a?(Exception)
      end

      # @return [App] editor operations bound to this character
      def app
        Runtime.app(
          data_dir: DATA_DIR, game: XMLData.game, character: Char.name,
          char_settings: CharSettings.to_hash,
          templates: templates,
          rooms: Map.list, uid_resolver: ->(uid) { Map.ids_from_uid(uid) },
          # The creature finder opens on a band around the character's level.
          level: (XMLData.level.to_i rescue 0),
          ready_list: ready_list,
          inventory: inventory,
          armaments: armaments
        )
      end

      # Lich namespaces this as Lich::Gemstone::CreatureTemplate; testing the
      # short name alone would hand the editor an empty creature list.
      def templates
        if defined?(Lich::Gemstone::CreatureTemplate)
          Lich::Gemstone::CreatureTemplate.all
        elsif defined?(CreatureTemplate)
          CreatureTemplate.all
        else
          []
        end
      end

      # What the character has readied, from what Lich already knows. Asking
      # the game would block the editor on roundtime and a reply, and an
      # unchecked list reports stale entries, so it is passed as empty
      # rather than believed.
      def ready_list
        list = Lich::Gemstone::ReadyList
        list.checked? ? list.ready_list.transform_keys(&:to_s) : {}
      rescue StandardError
        {}
      end

      # What the character carries. `GameObj.inv` holds the containers worn,
      # not what is in them, so the contents come from the inventory
      # snapshot when Lich has one.
      def inventory
        snapshot = Lich::Common::Inventory.current
        items = snapshot ? snapshot.all : (GameObj.inv.to_a + GameObj.containers.values.flatten)
        items.compact.map do |item|
          { noun: item.noun, name: item.name, types: item.type,
            container: item.respond_to?(:container?) ? item.container? : nil }
        end
      rescue StandardError
        []
      end

      # The words that make an item a weapon or a shield, from Lich's
      # armament tables: gameobj-data types almost nothing as a weapon and
      # has no shield type at all.
      def armaments
        stats = Lich::Gemstone::Armaments::WeaponStats
        categories = stats.categories - NON_ITEM_CATEGORIES
        {
          weapons: categories.flat_map { |category| stats.list(category) }
                             .flat_map { |weapon| Array(weapon[:all_names]) }
                             .compact.uniq,
          shields: Lich::Gemstone::Armaments::ShieldStats.names
        }
      rescue StandardError
        {}
      end
    end
  end
end

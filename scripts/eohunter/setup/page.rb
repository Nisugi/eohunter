# frozen_string_literal: true

require 'digest'

module EO
  module HunterSetup
    # Renders the editor as a Lich WebUI component tree.
    #
    # The tree is a pure function of an Editor: every event handler mutates the
    # Editor and asks for a re-render, and nothing here holds state of its own.
    # That is the inversion from the browser editor, where the draft lived in
    # JavaScript and was POSTed back.
    #
    # Field controls are generated from Schema#fields rather than written out
    # one by one, so a setting added to the engine appears here without a
    # change to this file.
    module Page
      # Field keys longer than this get a textarea instead of a single line.
      LONG_VALUE = 60
      # How many characters of help text to show before it is worth collapsing.
      MAX_HELP = 240

      module_function

      # Draw the whole editor.
      # @param builder [Lich::WebUI::TreeBuilder] the render builder
      # @param editor [Editor] the editing session
      # @param on [Hash] event handlers, by name
      # @return [void]
      def render(builder, editor, on:)
        Page.header(builder, editor, on: on)
        Page.status(builder, editor)
        # The editor is taller than any window, and a `bare` page does not
        # scroll on its own: the stylesheet sets `overflow: hidden` on the body
        # and gives the height to a `.webui-scroll` child
        # (assets/app.css:66-69). Without this node the draft bar is all you
        # can reach -- the tabs and every control below sit off-screen with no
        # way to get to them.
        builder.scroll(key: 'content') do
          Page.body(builder, editor, on: on)
        end
      end

      # Name, dirty state, and the actions that apply to the whole draft.
      def header(builder, editor, on:)
        builder.group(key: 'draft', label: 'Current draft') do
          builder.columns(count: 2, weights: [3, 2]) do
            builder.stack(key: 'identity', slot: '0') do
              builder.text_input(key: 'name', label: 'Hunt name', value: editor.name,
                                 placeholder: 'Untitled hunt',
                                 on: { change: on[:rename] })
              builder.text(key: 'state', emphasis: 'subtle',
                           content: editor.dirty? ? 'Unsaved changes' : 'No unsaved changes')
            end
            builder.stack(key: 'actions', slot: '1') do
              builder.button(key: 'validate', label: 'Check settings', on: { activate: on[:validate] })
              builder.button(key: 'save', label: 'Save', on: { activate: on[:save] })
              builder.button(key: 'revert', label: 'Revert', disabled: !editor.dirty?,
                             on: { activate: on[:revert] })
            end
          end
        end
      end

      # The last thing that happened, and why.
      def status(builder, editor)
        return unless editor.status

        builder.text(key: 'status', content: editor.status,
                     tone: editor.status_error ? 'danger' : 'neutral')
      end

      # Navigation and the page under it.
      def body(builder, editor, on:)
        names = Editor::PAGES.map(&:last)
        # Not `vertical: true`. The contract accepts the property but the
        # client never reads it (no `props.vertical` anywhere in app.js), so a
        # sidebar is not actually available -- the tabs render as one
        # horizontal strip either way, and asking for a sidebar we do not get
        # only hides that the titles have to be short enough to fit.
        builder.tabs(key: 'nav', names: names, on: { select: on[:select_page] }) do
          builder.collection(Editor::PAGES) do |(identity, title), _index|
            builder.stack(key: identity, slot: title) do
              case identity
              when 'manage' then Page.manage(builder, editor, on: on)
              when 'review' then Page.review(builder, editor)
              else
                Page.area_map(builder, editor, on: on) if identity == 'area'
                Page.settings(builder, editor, identity, on: on)
              end
            end
          end
        end
      end

      # The landing page: what exists, which one a bare ;eohunter starts, and
      # what is loaded now.
      def manage(builder, editor, on:)
        builder.text(key: 'intro',
                     content: 'Choose a hunt to edit. Selecting one, or setting it as the default, ' \
                              'never starts it.')
        Page.active_summary(builder, editor, on: on)
        builder.button(key: 'new', label: 'New hunt', on: { activate: on[:new] })
        Page.native_list(builder, editor, on: on)
        Page.legacy_list(builder, editor, on: on)
        Page.delete_dialog(builder, editor, on: on)
      end

      # Which hunt an argument-free ;eohunter starts.
      def active_summary(builder, editor, on:)
        active = editor.active_profile
        builder.group(key: 'active', label: 'Default hunt') do
          builder.text(key: 'value', content: active || 'None selected. `;eohunter` needs a name until one is set.')
          builder.button(key: 'clear', label: 'Clear default', disabled: active.nil?,
                         on: { activate: on[:set_active].curry[nil] })
        end
      end

      # EOHunter's own hunts: the only ones setup will write or delete.
      def native_list(builder, editor, on:)
        profiles = editor.profiles
        builder.group(key: 'native', label: "EOHunter hunts (#{profiles.size})") do
          if profiles.empty?
            builder.text(key: 'empty', emphasis: 'subtle',
                         content: 'None yet. Name this draft and save it to create one.')
            next
          end
          builder.collection(profiles) do |name, _index|
            Page.native_row(builder, editor, name, on: on)
          end
        end
      end

      def native_row(builder, editor, name, on:)
        active = editor.active_profile == name
        hidden = editor.hidden?(name)
        builder.columns(key: Page.row_key('row', name), count: 5, weights: [4, 2, 2, 2, 2]) do
          label = name.dup
          label << ' - default' if active
          label << ' - hidden' if hidden
          builder.text(key: 'name', slot: '0', content: label,
                       emphasis: hidden ? 'subtle' : 'normal')
          builder.button(key: 'open', slot: '1', label: 'Edit',
                         on: { activate: on[:load].curry[name] })
          builder.button(key: 'active', slot: '2', label: active ? 'Default' : 'Set default',
                         disabled: active, on: { activate: on[:set_active].curry[name] })
          builder.button(key: 'hide', slot: '3', label: hidden ? 'Show' : 'Hide',
                         on: { activate: on[:set_hidden].curry[name][!hidden] })
          # Deleting the active hunt is refused by the store; say so here
          # rather than offering a button that always fails.
          # A nil tooltip is not the same as no tooltip: the contract refuses
          # the property rather than treating nil as absent.
          explain = active ? { tooltip: 'Clear the default before deleting this hunt.' } : {}
          builder.button(key: 'delete', slot: '4', label: 'Delete', variant: 'danger',
                         disabled: active, **explain,
                         on: { activate: on[:request_delete].curry[name] })
        end
      end

      # Bigshot profiles. Read-only on purpose: setup opens a copy and never
      # writes or deletes the original.
      def legacy_list(builder, editor, on:)
        legacy = editor.legacy_profiles
        return if legacy.empty?

        builder.expander(key: 'legacy', label: "Bigshot profiles, read-only (#{legacy.size})") do
          builder.text(key: 'note', emphasis: 'subtle',
                       content: 'Opening one copies it into a new EOHunter hunt. The original is never changed.')
          builder.collection(legacy) do |name, _index|
            builder.columns(key: Page.row_key('legacy', name), count: 2, weights: [4, 2]) do
              builder.text(key: 'name', slot: '0', content: name)
              builder.button(key: 'copy', slot: '1', label: 'Open a copy',
                             on: { activate: on[:copy_legacy].curry[name] })
            end
          end
        end
      end

      # Shown only while a delete is awaiting confirmation. The revision came
      # from the preview, so a document edited in between is refused rather
      # than silently deleted.
      def delete_dialog(builder, editor, on:)
        pending = editor.pending_delete
        return unless pending

        dependents = Array(pending[:dependents])
        body = +"Delete #{pending[:name]}? A recoverable backup is kept."
        body << " Still referenced by: #{dependents.join(', ')}." unless dependents.empty?
        body << ' A Bigshot profile of the same name remains and would be used instead.' if pending[:legacy_fallback]
        builder.dialog(key: 'confirm-delete', title: "Delete #{pending[:name]}", body: body,
                       no_viewer: 'abort',
                       buttons: [{ 'id' => 'cancel', 'label' => 'Keep it' },
                                 { 'id' => 'delete', 'label' => 'Delete', 'variant' => 'danger' }],
                       on: { response: on[:delete_response] })
      end

      # The hunting area drawn on the installed map sheet.
      #
      # One region per room, taken from the native image_coords, so a click
      # lands on the room it looks like. Left-click puts a room in the role
      # the picker names; right-click clears whatever role it holds.
      def area_map(builder, editor, on:)
        # Only built when asked for: see Editor#map_open?.
        unless editor.map_open?
          builder.button(key: 'show-map', label: 'Show the map',
                         on: { activate: on[:toggle_map] })
          return
        end

        current = editor.map
        builder.expander(key: 'map', label: 'Map', open: true) do
          builder.button(key: 'hide-map', label: 'Hide the map',
                         on: { activate: on[:toggle_map] })
          if current.nil?
            builder.text(key: 'unavailable', tone: 'caution',
                         content: editor.map_error || 'The installed map is unavailable.')
            next
          end
          Page.map_diagnostics(builder, current)
          Page.map_legend(builder)
          Page.sheet_picker(builder, editor, current, on: on)
          Page.role_picker(builder, editor, on: on)
          Page.map_surface(builder, editor, current, on: on)
        end
      end

      # Anything setup could not resolve about the draft's rooms. Shown before
      # the map, because an unresolved reference means the picture is
      # incomplete rather than wrong.
      def map_diagnostics(builder, current)
        notes = Array(current[:diagnostics])
        return if notes.empty?

        builder.collection(notes) do |note, index|
          builder.text(key: "d#{index}", tone: 'caution', content: note)
        end
      end

      def map_legend(builder)
        builder.text(key: 'legend', emphasis: 'subtle',
                     content: "Left-click assigns the selected role; right-click clears a room. " \
                              "Roles: #{Editor::ROLE_LABELS.values.join(', ')}.")
      end

      # Which sheet is being looked at. Changing it does not change the draft.
      def sheet_picker(builder, editor, current, on:)
        sheets = Array(current[:sheets])
        return if sheets.empty?

        labels = current[:sheet_labels] || {}
        options = sheets.map { |name| { 'value' => name, 'label' => (labels[name] || name).to_s } }
        builder.select(key: 'sheet', label: 'Map sheet', options: options,
                       value: editor.sheet || sheets.first.to_s,
                       on: { change: on[:sheet] })
      end

      # The role a left-click assigns. A picker rather than a modifier, so the
      # same gesture works without a keyboard.
      def role_picker(builder, editor, on:)
        options = Editor::ROLE_LABELS.reject { |role, _| role == 'hunting' }
                                     .map { |role, label| { 'value' => role, 'label' => label } }
        builder.select(key: 'role', label: 'Left-click assigns', options: options,
                       value: editor.assign_role, on: { change: on[:assign_role] })
      end

      # The sheet, with one region per room on it.
      def map_surface(builder, editor, current, on:)
        sheet = editor.sheet || Array(current[:sheets]).first
        rooms = Array(current[:rooms]).select do |room|
          room[:image].to_s == sheet.to_s && room[:image_coords]
        end
        if rooms.empty?
          builder.text(key: 'no-rooms', emphasis: 'subtle',
                       content: 'No rooms on this sheet carry map coordinates.')
          return
        end

        # No route means the sheets are not being served, so the image layer
        # is left out entirely rather than pointing at a path the runtime will
        # refuse. The regions still draw and still click; only the artwork is
        # missing.
        route = Page.map_route
        unless route
          builder.text(key: 'no-art', tone: 'caution',
                       content: 'The installed map artwork is not being served, so the sheet is ' \
                                'not shown. Room selection below still works.')
        end
        layers = []
        layers << { 'kind' => 'image', 'x' => 0, 'y' => 0, 'src' => "#{route}#{sheet}" } if route
        rooms.each do |room|
          x1, y1, x2, y2 = room[:image_coords]
          role = editor.role_for(room[:id])
          layer = { 'kind' => 'region', 'key' => "room-#{room[:id]}",
                    'x1' => x1.to_i, 'y1' => y1.to_i, 'x2' => x2.to_i, 'y2' => y2.to_i,
                    'label' => Page.room_label(room, role), 'activates' => true }
          # An unpatched Lich has no tone on a region and refuses the property,
          # so the colour is offered only where the contract accepts it.
          layer['tone'] = Editor::ROLE_COLOURS[role] if role && Page.region_tones?
          layers << layer
        end
        builder.composite(key: 'surface', width: 1200, height: 900, surface_events: true,
                          layers: layers, on: { surface_activate: on[:map_click] })
      end

      def room_label(room, role)
        base = "#{room[:title]} (#{room[:id]})"
        role ? "#{base} - #{Editor::ROLE_LABELS.fetch(role, role)}" : base
      end

      # Whether the installed contract lets a region carry a colour. Without
      # it every room is an invisible hit area: the map still works, the roles
      # just are not visible on it.
      def region_tones?
        return @region_tones unless @region_tones.nil?

        @region_tones = begin
          Lich::WebUI::Validator.new.validate_component!(
            :composite, { width: 10, height: 10,
                          layers: [{ kind: 'region', key: 'probe', x1: 0, y1: 0, x2: 1, y2: 1,
                                     tone: { r: 1, g: 1, b: 1, a: 0.5 } }] },
            owner: 'eohunter-setup', page_id: 'probe', cid: 'probe'
          )
          true
        rescue StandardError
          false
        end
      end

      # Where the map sheets are served from, or nil when nothing registered
      # them.
      #
      # Deliberately not defaulted to a plausible-looking path. The runtime
      # refuses any image src that does not resolve to a registered file, and
      # it refuses it during *attach* -- so one unserved sheet does not degrade
      # the map, it stops the whole page from rendering. A guessed route is
      # therefore worse than none.
      def map_route = @map_route

      # @param route [String, nil] the /files/ prefix register_files returned
      def map_route=(route)
        @map_route = route
      end

      # Every setting the schema puts on this page.
      def settings(builder, editor, page, on:)
        fields = editor.fields_for(page)
        if fields.empty?
          builder.text(key: 'empty', emphasis: 'subtle', content: 'No settings on this page.')
          return
        end
        ordinary, advanced = fields.partition { |field| field['advanced'] != true }
        builder.collection(ordinary) do |field, _index|
          Page.field_control(builder, editor, field, on: on)
        end
        return if advanced.empty?

        builder.expander(key: 'advanced', label: "Advanced (#{advanced.size})") do
          builder.collection(advanced) do |field, _index|
            Page.field_control(builder, editor, field, on: on)
          end
        end
      end

      # One setting: its control, then what setup knows about it.
      def field_control(builder, editor, field, on:)
        key = field['key']
        builder.group(key: "f-#{key}", label: field['label'].to_s) do
          Page.control(builder, editor, field, on: on)
          Page.help(builder, field)
          Page.provenance(builder, editor, field)
          Page.field_errors(builder, editor, key)
        end
      end

      # The editor for one field, chosen from the schema's own type metadata.
      def control(builder, editor, field, on:)
        key = field['key']
        value = editor.settings[key]
        handler = on[:change].curry[key]
        options = Array(field['options'])

        if field['type'] == 'boolean'
          builder.checkbox(key: 'v', label: field['label'].to_s, checked: value == true,
                           on: { change: handler })
        elsif options.any?
          builder.select(key: 'v', label: field['label'].to_s,
                         options: Page.select_options(options, value),
                         value: value.nil? ? '' : value.to_s,
                         on: { change: handler })
        elsif %w[integer number].include?(field['type'])
          # A numeric setting left unset must stay unset, and number_input has
          # no empty state -- so it is edited as text and cleaned on the way in.
          builder.text_input(key: 'v', label: Page.units_label(field), value: value.nil? ? '' : value.to_s,
                             placeholder: 'unset', on: { change: handler })
        elsif Page.list_field?(field)
          Page.list_editor(builder, editor, field, on: on)
        elsif Page.structured?(field, value)
          # Structured settings have no guided editor yet, so they are edited
          # as the YAML the engine stores. Round-trips exactly; just not
          # friendly.
          builder.textarea(key: 'v', label: field['label'].to_s, rows: 6,
                           value: Page.render_value(value), on: { change: handler })
        else
          builder.text_input(key: 'v', label: Page.units_label(field), value: Page.render_value(value),
                             placeholder: 'unset', on: { change: handler })
        end
      end

      # Settings the engine splits on commas. Stored as text -- an Array is
      # stringified by the cleaner, not split -- but edited as ordered entries,
      # because order matters for scripts and commands.
      LIST_CLEANERS = %w[split split_xx list rooms strict_rooms].freeze

      # @param field [Hash] a schema field descriptor
      # @return [Boolean] whether it holds a comma list
      def list_field?(field)
        LIST_CLEANERS.include?(field['cleaner'].to_s) && Array(field['options']).empty?
      end

      # One row per entry, with the reordering the engine's order-sensitive
      # settings need, plus a blank row to add another.
      def list_editor(builder, editor, field, on:)
        key = field['key']
        entries = Page.list_entries(editor.settings[key])
        builder.text(key: 'units', emphasis: 'subtle', content: Page.list_hint(field))
        builder.collection(entries.each_with_index.to_a) do |(entry, index), _position|
          builder.columns(key: "e#{index}", count: 4, weights: [6, 1, 1, 1]) do
            builder.text_input(key: 'v', slot: '0', value: entry,
                               on: { change: on[:list_set].curry[key][index] })
            builder.button(key: 'up', slot: '1', label: 'Up', disabled: index.zero?,
                           on: { activate: on[:list_move].curry[key][index][-1] })
            builder.button(key: 'down', slot: '2', label: 'Down',
                           disabled: index == entries.size - 1,
                           on: { activate: on[:list_move].curry[key][index][1] })
            builder.button(key: 'rm', slot: '3', label: 'Remove',
                           on: { activate: on[:list_remove].curry[key][index] })
          end
        end
        builder.text_input(key: 'add', label: entries.empty? ? 'First entry' : 'Add another',
                           value: '', placeholder: 'type and press Enter',
                           on: { change: on[:list_add].curry[key] })
      end

      # @param value [Object] a stored list setting
      # @return [Array<String>] its entries
      def list_entries(value)
        return [] if value.nil?
        return value.map(&:to_s) if value.is_a?(Array)

        value.to_s.split(',').map(&:strip).reject(&:empty?)
      end

      def list_hint(field)
        units = field['units'].to_s
        base = 'Order is kept.'
        units.empty? ? base : "#{base} #{units}"
      end

      # A component key derived from a document name.
      #
      # Profile names are free-form player text -- "Boreal Forest" is a real
      # one -- and a component key must match Contract::IDENTIFIER, which
      # allows no spaces. Interpolating the name directly fails the whole page
      # render, not just that row. Unsafe characters become '_', and a short
      # digest keeps two names that differ only in those characters apart.
      def row_key(prefix, name)
        text = name.to_s
        safe = text.gsub(/[^A-Za-z0-9_.:-]/, '_')
        digest = Digest::SHA256.hexdigest(text)[0, 8]
        "#{prefix}-#{safe}-#{digest}"[0, 128]
      end

      # Options always carry an explicit "unset" entry: clearing a setting is
      # how a hunt falls back to its inherited or engine default, and a select
      # with no empty choice cannot express that.
      def select_options(options, _value)
        entries = [{ 'value' => '', 'label' => '(unset)' }]
        entries + options.map do |option|
          option.is_a?(Hash) ? option : { 'value' => option.to_s, 'label' => option.to_s }
        end.reject { |option| option['value'].to_s.empty? }
      end

      def help(builder, field)
        text = field['help'].to_s
        return if text.empty?

        builder.text(key: 'help', emphasis: 'subtle', content: Page.truncate(text))
      end

      # Where this value actually comes from -- an explicit setting here, an
      # inherited default, or the engine's own. Worth saying out loud: an empty
      # control does not mean the hunt has no value for the setting.
      def provenance(builder, editor, field)
        key = field['key']
        source = if editor.settings.key?(key)
                   'Explicit setting in this draft'
                 elsif (from = editor.provenance_for(key))
                   "From #{from.is_a?(String) ? from : from.inspect}"
                 else
                   'Engine or compatibility default'
                 end
        builder.text(key: 'prov', emphasis: 'subtle', content: source)
      end

      def field_errors(builder, editor, key)
        messages = editor.errors.select { |error| Page.error_key(error) == key }
        return if messages.empty?

        builder.collection(messages) do |error, index|
          builder.text(key: "e#{index}", tone: 'danger', content: Page.error_message(error))
        end
      end

      # The whole draft, and everything the last check said about it.
      def review(builder, editor)
        builder.text(key: 'intro',
                     content: 'Check the whole plan before saving. Validation does not prove ' \
                              'combat effectiveness or area safety.')
        Page.summary(builder, 'errors', 'Errors', editor.errors, 'danger')
        Page.summary(builder, 'warnings', 'Warnings', editor.warnings, 'caution')
        builder.expander(key: 'raw', label: 'Raw configuration') do
          builder.textarea(key: 'yaml', rows: 18, disabled: true, value: Page.render_value(editor.draft))
        end
      end

      def summary(builder, key, title, entries, tone)
        return if entries.empty?

        builder.group(key: key, label: "#{title} (#{entries.size})") do
          builder.collection(entries) do |entry, index|
            builder.text(key: "i#{index}", tone: tone, content: Page.error_message(entry))
          end
        end
      end

      def structured?(field, value)
        field['type'] == 'structured' || value.is_a?(Hash) || value.is_a?(Array) ||
          Page.render_value(value).length > LONG_VALUE
      end

      def units_label(field)
        units = field['units']
        units.to_s.empty? ? field['label'].to_s : "#{field['label']} (#{units})"
      end

      def render_value(value)
        case value
        when nil then ''
        when String then value
        when Hash, Array then YAML.dump(value)
        else value.to_s
        end
      end

      def error_key(error)
        error.is_a?(Hash) ? (error['key'] || error[:key]) : nil
      end

      def error_message(error)
        return error unless error.is_a?(Hash)

        error['message'] || error[:message] || error.inspect
      end

      def truncate(text)
        text.length > MAX_HELP ? "#{text[0, MAX_HELP].rstrip}..." : text
      end
    end
  end
end

# frozen_string_literal: true

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
        Page.body(builder, editor, on: on)
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
        builder.tabs(key: 'nav', names: names, vertical: true, on: { select: on[:select_page] }) do
          builder.collection(Editor::PAGES) do |(identity, title), _index|
            builder.stack(key: identity, slot: title) do
              case identity
              when 'manage' then Page.manage(builder, editor, on: on)
              when 'review' then Page.review(builder, editor)
              else Page.settings(builder, editor, identity, on: on)
              end
            end
          end
        end
      end

      # The landing page: what exists, and what is loaded.
      def manage(builder, editor, on:)
        builder.text(key: 'intro', content: 'Choose a hunt to edit. Selecting one never starts it.')
        profiles = editor.profiles
        if profiles.empty?
          builder.text(key: 'empty', emphasis: 'subtle',
                       content: 'No EOHunter hunts saved yet. Name this draft and save it to create one.')
          return
        end
        builder.collection(profiles) do |name, _index|
          builder.columns(key: "row-#{name}", count: 2, weights: [4, 1]) do
            builder.text(key: 'name', slot: '0', content: name)
            builder.button(key: 'open', slot: '1', label: 'Edit', on: { activate: on[:load].curry[name] })
          end
        end
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
        elsif Page.structured?(field, value)
          builder.textarea(key: 'v', label: field['label'].to_s, rows: 6,
                           value: Page.render_value(value), on: { change: handler })
        else
          builder.text_input(key: 'v', label: Page.units_label(field), value: Page.render_value(value),
                             placeholder: 'unset', on: { change: handler })
        end
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

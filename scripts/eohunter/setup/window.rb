# frozen_string_literal: true

module EO
  module HunterSetup
    # The editor, drawn in GTK3 -- what stock Lich ships.
    #
    # A thin view over Editor: every control hands its text to an +on_*+
    # method and the page is rebuilt from the editor's state whenever that
    # state changes underneath it (load, new, revert, save). Which control a
    # setting gets, and how its text becomes a value, is Form's business.
    #
    # Everything here runs on the GTK thread, so it must be built inside
    # Gtk.queue.
    class Window
      # Pages the window draws. The editor's landing page is left out: the
      # toolbar does what it did.
      PAGES = Editor::NAV_ITEMS.reject { |item| item[:id] == 'manage' }.freeze

      # Colour of a setting's validation message.
      MESSAGE_MARKUP = "<span foreground='#c0392b'>%s</span>"

      # @param editor [Editor] the editing session
      # @param title [String] the window title
      # @param on_close [#call] called once the window is gone
      # @param evaluate [#call, nil] runs a Ruby condition where the hunt
      #   would, for Test now; nil leaves the button out
      def initialize(editor:, title:, on_close:, evaluate: nil)
        @evaluate = evaluate
        @editor = editor
        @on_close = on_close
        @page = PAGES.find { |item| item[:id] == 'area' }&.fetch(:id) || PAGES.first[:id]
        @window = Gtk::Window.new(title)
        @window.set_default_size(1100, 720)
        @window.signal_connect('delete-event') { !confirm_discard('Close the editor') }
        @window.signal_connect('destroy') do
          @closed = true
          @on_close.call
        end

        root = Gtk::Box.new(:vertical, 6)
        root.border_width = 8
        root.pack_start(toolbar, expand: false, fill: false)
        @status = Gtk::Label.new('')
        @status.xalign = 0
        @status.selectable = true
        root.pack_start(@status, expand: false, fill: false)

        paned = Gtk::Paned.new(:horizontal)
        paned.pack1(sidebar, resize: false, shrink: false)
        @content = Gtk::ScrolledWindow.new
        @content.set_policy(:never, :automatic)
        paned.pack2(@content, resize: true, shrink: false)
        paned.position = 210
        root.pack_start(paned, expand: true, fill: true)

        @window.add(root)
        refresh
      end

      # @return [void]
      def show = @window.show_all

      # @return [void]
      # Safe to call after the viewer has closed it: the script's exit runs
      # this too, and destroying a destroyed window raises.
      def close
        @window.destroy unless @closed
      end

      private

      def toolbar
        bar = Gtk::Box.new(:horizontal, 6)

        bar.pack_start(Gtk::Label.new('Hunt:'), expand: false, fill: false)
        @profiles = Gtk::ComboBoxText.new
        @profiles.tooltip_text = 'Hunts saved by eohunter'
        bar.pack_start(@profiles, expand: false, fill: false)
        bar.pack_start(button('Open') { open_selected(@profiles) { |name| @editor.on_load(name) } }, expand: false, fill: false)

        bar.pack_start(Gtk::Label.new('Bigshot:'), expand: false, fill: false)
        @legacy = Gtk::ComboBoxText.new
        @legacy.tooltip_text = 'Bigshot profiles, opened as an unsaved copy; the original is never written'
        bar.pack_start(@legacy, expand: false, fill: false)
        bar.pack_start(button('Import') { open_selected(@legacy) { |name| @editor.on_copy_legacy(name) } }, expand: false, fill: false)

        bar.pack_start(button('New') { act('Start a new hunt') { @editor.on_new } }, expand: false, fill: false)
        bar.pack_start(Gtk::Separator.new(:vertical), expand: false, fill: false)

        bar.pack_start(Gtk::Label.new('Name:'), expand: false, fill: false)
        @name = Gtk::Entry.new
        @name.width_chars = 18
        @name.signal_connect('changed') { @editor.on_rename(@name.text) unless @refreshing }
        bar.pack_start(@name, expand: false, fill: false)

        bar.pack_start(button('Validate') { act { @editor.on_validate } }, expand: false, fill: false)
        bar.pack_start(button('Save') { act { @editor.on_save } }, expand: false, fill: false)
        bar.pack_start(button('Revert') { act('Revert') { @editor.on_revert } }, expand: false, fill: false)
        bar
      end

      def sidebar
        list = Gtk::ListBox.new
        list.selection_mode = :single
        section = nil
        PAGES.each do |item|
          if item[:section] != section
            section = item[:section]
            header = Gtk::Label.new
            header.set_markup("<b>#{escape(section)}</b>")
            header.xalign = 0
            header.margin_top = 8
            row = Gtk::ListBoxRow.new
            row.add(header)
            row.selectable = false
            row.activatable = false
            list.add(row)
          end
          label = Gtk::Label.new(item[:label])
          label.xalign = 0
          label.margin_start = 12
          row = Gtk::ListBoxRow.new
          row.add(label)
          row.name = item[:id]
          list.add(row)
          list.select_row(row) if item[:id] == @page
        end
        list.signal_connect('row-selected') do |_, row|
          next if row.nil? || @refreshing

          @page = row.name
          render_page
        end
        scroll = Gtk::ScrolledWindow.new
        scroll.set_policy(:never, :automatic)
        scroll.add(list)
        scroll
      end

      def button(label, &block)
        widget = Gtk::Button.new(label: label)
        widget.signal_connect('clicked') { block.call }
        widget
      end

      # Run an editor action, asking first when it would throw away edits.
      def act(discarding = nil)
        return if discarding && !confirm_discard(discarding)

        # A box being typed in hands its text over on losing focus; take it
        # now, so Save and Validate see what is on screen.
        @window.focus = nil
        yield
        refresh
      end

      def open_selected(combo, &block)
        name = combo.active_text
        return if name.nil? || name.empty?

        act('Open another hunt') { block.call(name) }
      end

      def confirm_discard(what)
        return true unless @editor.dirty?

        dialog = Gtk::MessageDialog.new(parent: @window, flags: :modal, type: :question, buttons: :yes_no,
                                        message: "#{what} and lose the unsaved changes?")
        answer = dialog.run
        dialog.destroy
        answer == Gtk::ResponseType::YES
      end

      # Redraw everything from the editor's state.
      def refresh
        @refreshing = true
        fill(@profiles, @editor.profiles.map { |entry| entry_name(entry) }, @editor.name)
        fill(@legacy, @editor.legacy_profiles.map { |entry| entry_name(entry) }, @legacy.active_text)
        @name.text = @editor.name.to_s
        status = escape(@editor.status.to_s)
        @status.set_markup(@editor.status_error ? format(MESSAGE_MARKUP, status) : status)
        @refreshing = false
        render_page
      end

      def entry_name(entry)
        entry.is_a?(Hash) ? (entry[:name] || entry['name']).to_s : entry.to_s
      end

      def fill(combo, names, selected)
        combo.remove_all
        names.each { |name| combo.append_text(name) }
        index = names.index(selected)
        combo.active = index if index
      end

      def render_page
        @content.children.each { |child| @content.remove(child) }
        box = Gtk::Box.new(:vertical, 10)
        box.border_width = 12
        @page == 'review' ? review(box) : settings(box)
        @content.add(box)
        @content.show_all
      end

      def settings(box)
        fields = @editor.fields_for(@page)
        common, advanced = fields.partition { |field| !field['advanced'] }
        box.pack_start(grid(common), expand: false, fill: false) if common.any?
        return if advanced.empty?

        expander = Gtk::Expander.new("Advanced (#{advanced.size})")
        expander.add(grid(advanced))
        box.pack_start(expander, expand: false, fill: false)
      end

      def grid(fields)
        table = Gtk::Grid.new
        table.row_spacing = 6
        table.column_spacing = 12
        row = 0
        fields.each do |field|
          tip = Form.tooltip(@editor, field)
          kind = Form.kind(@editor, field)
          unless kind == :check
            label = Gtk::Label.new(Form.label(field))
            label.xalign = 0
            label.yalign = 0
            label.tooltip_text = tip
            table.attach(label, 0, row, 1, 1)
          end
          widget = control(field, kind)
          widget.tooltip_text = tip
          widget.hexpand = true
          table.attach(widget, kind == :check ? 0 : 1, row, kind == :check ? 2 : 1, 1)
          row += 1
          Form.messages(@editor, field['key']).each do |message|
            note = Gtk::Label.new
            note.set_markup(format(MESSAGE_MARKUP, escape(message)))
            note.xalign = 0
            note.wrap = true
            table.attach(note, 1, row, 1, 1)
            row += 1
          end
        end
        table
      end

      def control(field, kind)
        key = field['key']
        value = @editor.settings[key]
        case kind
        when :check then check(field, value)
        when :ruby then ruby(field, value)
        when :choice then choice(field, value)
        when :equipment then equipment(key, value)
        when :list then lines(key)
        when :text_block then text_block(field, value)
        else entry(field, value)
        end
      end

      def check(field, value)
        widget = Gtk::CheckButton.new(field['label'].to_s)
        widget.active = value == true
        widget.signal_connect('toggled') { @editor.on_change(field['key'], widget.active?) }
        widget
      end

      def choice(field, value)
        widget = Gtk::ComboBoxText.new
        options = Form.choices(field, value)
        options.each { |(id, label)| widget.append(id, label) }
        widget.active_id = Form.chosen(options, value) || ''
        widget.signal_connect('changed') { @editor.on_change(field['key'], widget.active_id.to_s) }
        widget
      end

      # The character's own equipment to pick from, or any item name typed.
      def equipment(key, value)
        widget = Gtk::ComboBoxText.new(entry: true)
        @editor.equipment_options(key).each do |option|
          text = option['value'].to_s
          widget.append_text(text) unless text.empty?
        end
        widget.child.text = value.to_s
        widget.child.placeholder_text = 'as it appears in your inventory'
        widget.child.signal_connect('changed') { @editor.on_change(key, widget.child.text) }
        widget
      end

      # A Ruby condition, with a button that runs it where the hunt would.
      #
      # Run off the GTK thread with a time limit: the condition is arbitrary
      # code, and one that waits on the game must not freeze the window.
      def ruby(field, value)
        input = entry(field, value)
        return input unless @evaluate

        result = Gtk::Label.new('')
        result.xalign = 0
        result.selectable = true
        test = Gtk::Button.new(label: 'Test now')
        test.tooltip_text = 'Run this condition now, as the hunt would, and show what it says. ' \
                            'It reads your character as they are at this moment.'
        test.signal_connect('clicked') do
          result.text = 'Running...'
          code = input.text
          Thread.new do
            answer = run_condition(code)
            on_gtk { result.text = answer unless result.destroyed? }
          end
        end
        row = Gtk::Box.new(:horizontal, 6)
        row.pack_start(input, expand: true, fill: true)
        row.pack_start(test, expand: false, fill: false)
        box = Gtk::Box.new(:vertical, 2)
        box.pack_start(row, expand: false, fill: false)
        box.pack_start(result, expand: false, fill: false)
        box
      end

      # Seconds a condition may run before Test now gives up on it.
      TEST_LIMIT = 5

      # @param code [String] the condition
      # @return [String] what it said, in a line
      def run_condition(code)
        return 'Nothing to test.' if code.strip.empty?

        # Parsed first, as Validate does: Ruby's own SyntaxError is a
        # multi-line source excerpt that will not fit on a line.
        require 'prism'
        broken = Prism.parse(code).errors.first
        return "Not valid Ruby: #{broken.message}" if broken

        outcome = nil
        worker = Thread.new do
          value = @evaluate.call(code)
          outcome = "#{value ? 'true' : 'false'} right now (#{value.inspect[0, 80]})"
        rescue Exception => error # rubocop:disable Lint/RescueException -- a SyntaxError or a script exit must be shown, not kill the window
          outcome = "Raised #{error.class}: #{error.message[0, 200]}"
        end
        return outcome if worker.join(TEST_LIMIT)

        worker.kill
        "Did not finish within #{TEST_LIMIT} seconds; stopped."
      end

      # Run a block on the GTK thread: Lich's queue inside Lich, an idle
      # callback outside it.
      def on_gtk(&block)
        return Gtk.queue(&block) if Gtk.respond_to?(:queue)

        GLib::Idle.add do
          block.call
          false
        end
      end

      def entry(field, value)
        widget = Gtk::Entry.new
        widget.text = Form.text(value)
        widget.placeholder_text = 'unset'
        widget.signal_connect('changed') { @editor.on_change(field['key'], Form.parse(field, widget.text)) }
        widget
      end

      # A comma list, one entry per line.
      def lines(key)
        view = text_view(@editor.list_entries(key).join("\n"))
        view.signal_connect('focus-out-event') do
          @editor.on_list_set_all(key, view.buffer.text.lines.map(&:strip).reject(&:empty?))
          false
        end
        framed(view, 'One per line')
      end

      def text_block(field, value)
        view = text_view(Form.text(value))
        view.monospace = true
        view.signal_connect('focus-out-event') do
          @editor.on_change(field['key'], Form.parse(field, view.buffer.text))
          false
        end
        framed(view, field['type'] == 'structured' ? 'YAML' : nil)
      end

      def text_view(text)
        view = Gtk::TextView.new
        view.buffer.text = text
        view.wrap_mode = :word_char
        view.set_size_request(-1, [text.lines.size + 1, 3].max.clamp(3, 14) * 18)
        view
      end

      def framed(view, caption)
        frame = Gtk::Frame.new(caption)
        frame.add(view)
        frame
      end

      def review(box)
        changes = @editor.changes
        box.pack_start(heading(changes.empty? ? 'No unsaved changes' : "Unsaved changes (#{changes.size})"),
                       expand: false, fill: false)
        changes.each do |change|
          line = "#{change['key']}:  #{Form.change_text(change['before'], 'unset')}  ->  " \
                 "#{Form.change_text(change['after'], 'removed')}"
          box.pack_start(plain(line), expand: false, fill: false)
        end

        if @editor.validation.nil?
          box.pack_start(plain('Not checked yet. Validate checks the draft against the installed engine.'),
                         expand: false, fill: false)
          return
        end
        { 'Errors' => @editor.errors, 'Warnings' => @editor.warnings }.each do |title, entries|
          next if entries.empty?

          box.pack_start(heading("#{title} (#{entries.size})"), expand: false, fill: false)
          entries.each { |entry| box.pack_start(plain(Form.message(entry)), expand: false, fill: false) }
        end
      end

      def heading(text)
        label = Gtk::Label.new
        label.set_markup("<b>#{escape(text)}</b>")
        label.xalign = 0
        label
      end

      # Text made safe to put in Pango markup.
      def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

      def plain(text)
        label = Gtk::Label.new(text)
        label.xalign = 0
        label.wrap = true
        label.selectable = true
        label
      end
    end
  end
end

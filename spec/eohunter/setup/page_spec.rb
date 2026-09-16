# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

# These render against the real Lich WebUI contract when it is installed: the
# point is that the tree validates, not that a stub accepts it. Without a Lich
# checkout there is nothing meaningful to assert, so they are skipped rather
# than faked.
webui = ENV.fetch('LICH_DIR', 'C:/Gemstone/lich-5')
webui_api = File.join(webui, 'lib', 'webui', 'page.rb')
if File.exist?(webui_api)
  # Only the render half of the WebUI: page -> tree_builder -> validator ->
  # contract. Requiring lib/webui.rb instead would drag in
  # window_presentation and Lich's frontend, and with them fiddle and os,
  # none of which a tree needs to be built and validated.
  require webui_api
  # Runtime too, for EventContext: the handler-contract examples below need
  # the real Data class, not a stand-in.
  require File.join(File.dirname(webui_api), 'runtime.rb')
else
  RSpec.describe('EO::HunterSetup::Page') do
    it 'renders against the Lich WebUI contract' do
      skip "Lich WebUI not found at #{webui_api}; set LICH_DIR to run these"
    end
  end
end

RSpec.describe EO::HunterSetup::Page, if: File.exist?(webui_api) do
  around do |example|
    Dir.mktmpdir('hunter-page') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:app) do
    EO::HunterSetup::Runtime.app(
      data_dir: @directory, game: 'GSIV', character: 'Example',
      char_settings: {}, templates: [], rooms: [], uid_resolver: ->(_uid) { [] }
    )
  end
  let(:editor) { EO::HunterSetup::Editor.new(app: app) }
  let(:noop) { ->(*_args) { true } }
  let(:handlers) do
    { rename: noop, validate: noop, save: noop, revert: noop, select_page: noop, new: noop,
      load: ->(_name, _event) { true }, change: ->(_key, _event) { true },
      set_active: ->(_name, _event) { true }, set_hidden: ->(_name, _hidden, _event) { true },
      copy_legacy: ->(_name, _event) { true }, request_delete: ->(_name, _event) { true },
      delete_response: noop, sheet: noop, assign_role: noop, map_click: noop, toggle_map: noop,
      list_set: ->(_k, _i, _e) { true }, list_add: ->(_k, _e) { true },
      list_remove: ->(_k, _i, _e) { true }, list_move: ->(_k, _i, _o, _e) { true } }
  end

  def render(session = editor, on: handlers)
    # The render block is instance_exec'd against the TreeBuilder, so
    # described_class would resolve there. Capture it first.
    renderer = described_class
    owner = Struct.new(:name).new('eohunter-setup')
    page = Lich::WebUI::Page.new(owner: owner, id: 'eohunter-setup',
                                 title: 'EOHunter setup', props: { bare: true }) do |builder|
      renderer.render(builder, session, on: on)
    end
    [page, page.render]
  end

  it 'renders a tree the contract validates, well inside the component budget' do
    _page, tree = render
    expect(tree.tree.each.count).to be < Lich::WebUI::Contract::BOUNDS[:components]
    expect(tree.bindings).not_to be_empty
  end

  it 'gives every schema field a control, so none is unreachable' do
    _page, tree = render
    rendered = tree.tree.each.filter_map { |node| node.cid[%r{group:f-([^/]+)}, 1] }.uniq
    expect(rendered).to match_array(editor.fields.map { |field| field['key'] })
  end

  it 'routes a change event to the setting it was drawn for' do
    session = EO::HunterSetup::Editor.new(app: app)
    on = handlers.merge(change: ->(key, event) { session.on_change(key, event[:value]) })
    _page, tree = render(session, on: on)
    cid, = tree.bindings.keys.find { |(candidate, event)| event == :change && candidate.include?('f-hunting_stance') }
    expect(cid).not_to be_nil
    tree.bindings[[cid, :change]].call({ value: 'defensive' })
    expect(session.settings).to include('hunting_stance' => 'defensive')
  end

  it 'redraws from the editor, so a change is visible in the next render' do
    session = EO::HunterSetup::Editor.new(app: app)
    session.on_rename('forest')
    page, first = render(session)
    session.on_rename('marsh')
    second = page.render
    expect(second.generation).to be > first.generation
    name = second.tree.each.find { |node| node.cid.end_with?('text_input:name') }
    expect(name.props[:value]).to eq('marsh')
  end

  it 'offers an explicit unset choice, since clearing a setting is meaningful' do
    _page, tree = render
    # A settings field's select, not the map's sheet or role pickers -- those
    # choose what you are looking at, which is never unset.
    select = tree.tree.each.find { |node| node.type == :select && node.cid.include?('group:f-') }
    expect(select).not_to be_nil
    expect(select.props[:options].first).to include(value: '', label: '(unset)')
  end

  it 'draws a validation error beside the field it names' do
    session = EO::HunterSetup::Editor.new(app: app)
    # The installed parser coerces most bad input rather than refusing it
    # (flee_count 'x' becomes 0), so drive the renderer from a validation
    # report directly: what is under test is that an error reaches the field
    # it names, not which inputs the engine happens to reject.
    allow(session).to receive(:errors)
      .and_return([{ 'key' => 'hunting_stance', 'message' => 'Unsupported stance.' }])
    _page, tree = render(session)
    stance = tree.tree.each.select { |node| node.cid.include?('f-hunting_stance') }
    expect(stance.any? { |node| node.props[:content] == 'Unsupported stance.' }).to be(true)
    expect(stance.any? { |node| node.props[:tone] == 'danger' }).to be(true)
  end

  describe 'with saved hunts' do
    # The earlier examples render an empty store, where the list rows never
    # run. These cover the rows themselves.
    let(:populated) do
      EO::HunterSetup::Editor.new(app: app).tap do |session|
        session.on_rename('forest')
        session.on_save
        session.on_new
        session.on_rename('marsh')
        session.on_save
        session.on_set_active('forest')
      end
    end

    it 'lists each hunt with its actions, and validates' do
      _page, tree = render(populated)
      labels = tree.tree.each.select { |node| node.type == :button }.map { |node| node.props[:label] }
      expect(labels).to include('Edit', 'Set default', 'Hide', 'Delete', 'New hunt')
    end

    it 'refuses to offer deletion of the default hunt, which the store would reject' do
      _page, tree = render(populated)
      active = tree.tree.each.find { |node| node.cid.include?('row-forest') && node.cid.end_with?('button:delete') }
      other = tree.tree.each.find { |node| node.cid.include?('row-marsh') && node.cid.end_with?('button:delete') }
      expect(active.props[:disabled]).to be(true)
      expect(other.props[:disabled]).to be(false)
    end

    it 'raises a confirmation before deleting, and nothing is deleted by asking' do
      populated.on_request_delete('marsh')
      _page, tree = render(populated)
      dialog = tree.tree.each.find { |node| node.type == :dialog }
      expect(dialog).not_to be_nil
      expect(dialog.props[:body]).to include('marsh', 'backup')
      expect(dialog.props[:buttons].map { |button| button[:id] }).to eq(%w[cancel delete])
      expect(populated.profiles).to include('marsh')
    end

    it 'drops the confirmation once it is answered' do
      populated.on_request_delete('marsh')
      populated.on_cancel_delete
      _page, tree = render(populated)
      expect(tree.tree.each.any? { |node| node.type == :dialog }).to be(false)
      expect(populated.profiles).to include('marsh')
    end
  end

  # A `bare` page does not scroll on its own: the stylesheet puts
  # `overflow: hidden` on the body and gives the height to a `.webui-scroll`
  # that is a DIRECT child of the page root (assets/app.css:66-69). The editor
  # is taller than any window, so without that node everything below the draft
  # bar is unreachable -- the page opens and nothing on it can be used.
  it 'puts the content in a scroll node directly under the page root' do
    _page, tree = render
    scrolls = tree.tree.children.select { |node| node.type == :scroll }
    expect(scrolls.size).to eq(1)
    expect(tree.tree.children.map(&:type)).to include(:scroll)
    # and the tabs live inside it, not beside it
    expect(scrolls.first.children.map(&:type)).to include(:tabs)
  end

  it 'keeps tab titles short enough for one horizontal strip' do
    # The client ignores `vertical` (no props.vertical in app.js), so these
    # are laid out in a row and a long title pushes the rest off the window.
    EO::HunterSetup::Editor::PAGES.each do |_identity, title|
      expect(title.length).to be <= 12, "#{title.inspect} is too long for a tab"
    end
  end

  # Document names are free-form player text. A component key must match
  # Contract::IDENTIFIER, which allows no spaces, and an invalid key fails the
  # WHOLE page render -- not just that row -- during attach. A real install had
  # a Bigshot profile called "Boreal Forest" and the editor would not open.
  describe 'document names that are not identifiers' do
    it 'derives a legal key from any name' do
      ['Boreal Forest', 'a/b', 'x' * 200, 'sp ace.and:colon', '%&*()'].each do |name|
        key = described_class.row_key('row', name)
        expect(key).to match(Lich::WebUI::Contract::IDENTIFIER),
                       "#{name.inspect} produced #{key.inspect}"
      end
    end

    it 'keeps names apart that differ only in the unsafe characters' do
      expect(described_class.row_key('row', 'a b')).not_to eq(described_class.row_key('row', 'a_b'))
    end

    it 'renders a hunt whose name contains a space' do
      session = EO::HunterSetup::Editor.new(app: app)
      session.on_rename('Boreal Forest')
      session.on_save
      expect(session.status_error).to be(false)
      expect { render(session) }.not_to raise_error
      _page, tree = render(session)
      expect(tree.tree.each.any? { |node| node.props[:content] == 'Boreal Forest' }).to be(true)
    end
  end

  # The runtime validates on attach, not only on render, so anything the
  # validator refuses stops the editor opening at all. This walks the tree the
  # way the runtime does.
  it 'produces a tree whose every key and cid the contract accepts' do
    session = EO::HunterSetup::Editor.new(app: app)
    session.on_rename('Boreal Forest')
    session.on_save
    _page, tree = render(session)
    tree.tree.each do |node|
      expect(node.cid).to match(Lich::WebUI::Contract::CID_PATTERN), "bad cid #{node.cid}"
      key = node.props[:key]
      next if key.nil?

      expect(key.to_s).to match(Lich::WebUI::Contract::IDENTIFIER), "bad key #{key.inspect}"
    end
  end

  # The handler contract, pinned because getting it wrong fails silently.
  #
  # A bound callback is invoked with a Lich::WebUI::Runtime::EventContext --
  # a Data object -- not a Hash. `event[:value]` raises NoMethodError on it,
  # the dispatcher catches and logs that, and the control simply does nothing.
  # Every input in the editor was inert this way.
  describe 'the event payload handlers receive' do
    it 'reads values through #payload, since a context is not a Hash' do
      context = Lich::WebUI::Runtime::EventContext.new(
        'viewer', nil, nil, :change, { value: 'forest' }, nil
      )
      expect { context[:value] }.to raise_error(NoMethodError)
      expect(context.payload[:value]).to eq('forest')
    end

    it 'drives the editor from a real context, the way the dispatcher does' do
      session = EO::HunterSetup::Editor.new(app: app)
      handler = ->(event) { session.on_rename(event.payload[:value]) }
      handler.call(Lich::WebUI::Runtime::EventContext.new('viewer', nil, nil, :change,
                                                          { value: 'forest' }, nil))
      expect(session.name).to eq('forest')
    end
  end

  it 'still renders when nothing is loaded and no hunts exist' do
    expect { render }.not_to raise_error
  end
end

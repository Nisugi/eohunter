# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../../../scripts/eohunter/setup/runtime'

# Load the engine policy classes and setup modules before the describe
# block names Editor.
EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::Editor do
  around do |example|
    Dir.mktmpdir('hunter-editor') do |directory|
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
  let(:editor) { described_class.new(app: app) }

  it 'exposes every schema field, and assigns each one to a rendered page' do
    expect(editor.fields).not_to be_empty
    placed = described_class::SETTINGS_PAGES.flat_map { |page| editor.fields_for(page) }
    # A field whose page has no tab would be unreachable in the editor.
    expect(placed.map { |field| field['key'] }).to match_array(editor.fields.map { |field| field['key'] })
  end

  it 'starts clean and reports unsaved edits' do
    expect(editor).not_to be_dirty
    editor.on_change('hunting_stance', 'offensive')
    expect(editor).to be_dirty
    expect(editor.settings).to include('hunting_stance' => 'offensive')
  end

  it 'removes a setting when it is cleared, so the hunt falls back to its default' do
    editor.on_change('hunting_stance', 'offensive')
    editor.on_change('hunting_stance', '')
    expect(editor.settings).not_to have_key('hunting_stance')
  end

  it 'saves, keeps the returned revision, and saves again without a conflict' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    expect(editor.on_save).to be(true)
    expect(editor.status_error).to be(false)
    first = editor.revision
    expect(first).to be_a(String)
    expect(editor).not_to be_dirty

    editor.on_change('hunting_stance', 'defensive')
    editor.on_save
    expect(editor.status_error).to be(false)
    expect(editor.revision).not_to eq(first)
    expect(editor.profiles).to include('forest')
  end

  it 'refuses to save an unnamed draft rather than writing one' do
    editor.on_change('hunting_stance', 'offensive')
    expect(editor.on_save).to be(true)
    expect(editor.status_error).to be(true)
    expect(editor.profiles).to be_empty
  end

  it 'reports a save conflict instead of overwriting a document edited elsewhere' do
    editor.on_rename('forest')
    editor.on_save
    other = described_class.new(app: app)
    other.on_load('forest')
    other.on_change('flee_count', '3')
    other.on_save
    expect(other.status_error).to be(false)

    editor.on_change('flee_count', '9')
    editor.on_save
    expect(editor.status_error).to be(true)
    expect(editor.status).to match(/reload/i)
  end

  it 'loads a saved hunt back into a clean draft' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    editor.on_save

    fresh = described_class.new(app: app)
    fresh.on_load('forest')
    expect(fresh.name).to eq('forest')
    expect(fresh.settings).to include('hunting_stance' => 'offensive')
    expect(fresh).not_to be_dirty
  end

  it 'reverts to the last saved state' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    editor.on_save
    editor.on_change('hunting_stance', 'defensive')
    editor.on_revert
    expect(editor.settings).to include('hunting_stance' => 'offensive')
    expect(editor).not_to be_dirty
  end

  it 'validates without saving and keeps the report' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    expect(editor.on_validate).to be(true)
    expect(editor.validation).not_to be_nil
    expect(editor.profiles).to be_empty
  end

  it 'surfaces a validation error rather than raising out of a handler' do
    editor.on_change('flee_count', 'not a number')
    editor.on_validate
    expect(editor.status).to be_a(String)
  end
end

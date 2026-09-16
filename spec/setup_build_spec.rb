# frozen_string_literal: true

require_relative '../tools/build_setup'

RSpec.describe EOHunter::SetupBuild do
  let(:root) { File.expand_path('..', __dir__) }
  let(:result) { described_class.build(root: root, sha: 'abc1234') }
  let(:built) { result.source }

  it 'is valid Ruby' do
    expect { RubyVM::InstructionSequence.compile(built, 'eohunter-setup.lic') }.not_to raise_error
  end

  it 'keeps the script header and the lifecycle around the inlined modules' do
    expect(built).to start_with("=begin\n")
    expect(built).to include("require File.join(LIB_DIR, 'api', 'webui.rb')")
    expect(built).to include('Lich::API.webui_terminate_owner(me)')
    expect(built).to end_with("closed.pop\n")
  end

  it 'resolves nothing from disk, since the built file ships alone' do
    expect(built).not_to match(/^require_relative /)
    expect(built).not_to match(/^load File\.join/)
  end

  it 'inlines every setup module and every engine part' do
    EO::HunterSetup::Runtime::SETUP_PARTS.each do |part|
      expect(result.sections).to have_key("eohunter/setup/#{part}.rb")
    end
    EO::HunterSetup::Runtime.profile_parts(File.join(root, 'scripts')).each do |part|
      expect(result.sections).to have_key("eohunter/#{part}.rb")
    end
  end

  it 'guards the engine and each setup module, so a loaded one is left alone' do
    expect(built).to include('unless defined?(::EO::Engine::Profile)')
    expect(built).to include('unless defined?(::EO::HunterSetup::Store)')
    expect(built).to include('unless defined?(::EO::HunterSetup::Page)')
  end

  it 'carries no bundled browser assets, because the UI is Ruby now' do
    expect(built).not_to include('HunterSetup::ASSETS')
    expect(built).not_to include('<!doctype html>')
  end

  it 'maps each section to the lines it occupies, so an error traces to its part' do
    lines = built.lines
    result.sections.each do |name, (first, last)|
      expect(first).to be <= last
      expect(last).to be <= lines.size
      # append_marked records the line after the marker as the first, so the
      # marker naming the part sits immediately above it.
      expect(lines[first - 2]).to include(name)
    end
  end
end

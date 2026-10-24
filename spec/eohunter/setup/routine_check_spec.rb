# frozen_string_literal: true

require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::RoutineCheck do
  def warnings(routine, scripts: nil)
    described_class.warnings({ 'hunting_commands' => routine }, scripts: scripts)
  end

  it 'passes the routine Bigshot profiles ordinarily carry' do
    routine = ['kweed(buff5)', 'script volley', 'coupdegrace(thp20 empowered30)', 'incant 611(!frozen)', 'fire(frozen)']
    expect(warnings(routine, scripts: %w[volley])).to be_empty
  end

  it 'leaves an unknown word alone, since the hunt sends it to the game as typed' do
    expect(warnings(['attack target', 'gesture at target'])).to be_empty
  end

  it 'warns of a word the hunt would take in a shape it skips' do
    messages = warnings(['curse sneeze', 'force smite', 'celerity']).map { |entry| entry['message'] }
    expect(messages).to contain_exactly(a_string_including("'curse sneeze'"), a_string_including("'force smite'"),
                                        a_string_including("'celerity'"))
    expect(warnings(['curse sneeze']).first).to include('key' => 'hunting_commands', 'kind' => 'routine')
  end

  it 'does not warn of the shapes the hunt does run' do
    expect(warnings(['curse hex', 'force smite till 3', 'celerity attack', '506'])).to be_empty
  end

  it 'finds a script the way Lich does, by name or by the start of one' do
    expect(warnings(['script volley'], scripts: %w[Volley])).to be_empty
    expect(warnings(['script vol'], scripts: %w[volley])).to be_empty
    expect(warnings(['script volley'], scripts: %w[eloot]).first['message']).to include('no script named volley')
  end

  it 'skips the script check when it does not know what is installed' do
    expect(warnings(['script volley'])).to be_empty
  end

  it 'checks every routine setting, and says each problem once' do
    found = described_class.warnings({ 'hunting_commands_e' => ['celerity', 'celerity'], 'quick_commands' => ['celerity'] })
    expect(found.map { |entry| entry['key'] }).to eq(%w[hunting_commands_e quick_commands])
  end
end

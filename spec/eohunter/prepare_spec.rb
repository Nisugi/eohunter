# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

# The word side of the item-preparation bridge (lich-5 #1608): a profile
# entry sends a command and awaits the player's own event.
RSpec.describe EO::Engine::Prepare do
  let(:raw) do
    { 'crystal' => { 'perform' => 'feed my crystal', 'result' => 'user_feed_result', 'expect' => { 'ok' => true }, 'timeout' => 6 },
      'orb'     => { 'perform' => 'tap my orb', 'result' => 'user_orb_charges' } }
  end

  describe '.parse' do
    it 'reads each entry, defaulting expect to nothing and timeout to the action default' do
      entries = described_class.parse(raw)
      expect(entries.keys).to eq(%w[crystal orb])
      expect(entries['crystal'].to_h).to eq(name: 'crystal', perform: 'feed my crystal', result: :user_feed_result,
                                            expect: { ok: true }, timeout: 6)
      expect(entries['orb'].expect).to eq({})
      expect(entries['orb'].timeout).to be_nil
      expect(described_class.parse(nil)).to eq({})
    end

    it 'rejects an entry that is not runnable, naming it' do
      expect { described_class.parse([]) }.to raise_error(ArgumentError, /mapping/)
      expect { described_class.parse('ward' => 'rub my ward') }.to raise_error(ArgumentError, /preparations.ward must be a mapping/)
      expect { described_class.parse('ward' => { 'result' => 'user_ward' }) }.to raise_error(ArgumentError, /preparations.ward needs a perform/)
      expect { described_class.parse('ward' => { 'perform' => 'rub my ward' }) }.to raise_error(ArgumentError, /preparations.ward needs a result/)
      expect { described_class.parse('ward' => { 'perform' => 'x', 'result' => 'y', 'expect' => 'active' }) }.to raise_error(ArgumentError, /expect must be a mapping/)
      expect { described_class.parse('ward' => { 'perform' => 'x', 'result' => 'y', 'timeout' => 0 }) }.to raise_error(ArgumentError, /timeout/)
    end
  end

  describe 'Entry#satisfied_by?' do
    let(:entry) { described_class.parse('c' => { 'perform' => 'x', 'result' => 'y', 'expect' => { 'ok' => true, 'what' => 'crystal' } })['c'] }

    it 'wants every expected key present and equal, a Symbol by its string form' do
      expect(entry.satisfied_by?(ok: true, what: 'crystal', raw: 'line')).to be true
      expect(entry.satisfied_by?(ok: true, what: :crystal)).to be true
      expect(entry.satisfied_by?(ok: false, what: 'crystal')).to be false
      expect(entry.satisfied_by?(ok: true)).to be false
      expect(described_class.parse('c' => { 'perform' => 'x', 'result' => 'y' })['c'].satisfied_by?({})).to be true
    end
  end

  describe 'the action' do
    let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false) }
    let(:world) { OpenStruct.new(me: me) }
    let(:entries) { described_class.parse(raw) }
    let(:sent) { [] }

    after { EO::Engine::Events.reset! }

    # The game: the send emits the event Lich's scanner would make of the
    # answer line, before the ladder returns.
    def answer_with(**payload)
      allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:game_send) do |_a, cmd|
        sent << cmd
        EO::Engine::Events.emit(payload.delete(:event) || :user_feed_result, payload) unless payload.empty?
        'a line'
      end
      allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:sleep)
      allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:live_target_ids).and_return(nil)
    end

    it 'confirms when the awaited event satisfies expect' do
      answer_with(ok: true, what: 'crystal', raw: 'You feed the crystal and it hums softly.')
      result = described_class.run(world, entries, 'crystal')
      expect(result).to be_success
      expect(result.reason).to eq(:confirmed)
      expect(result.event.data[:what]).to eq('crystal')
      expect(result).to be_acted
      expect(sent).to eq(['feed my crystal'])
    end

    it 'is denied, with the line, when the event arrives but says no' do
      answer_with(ok: false, raw: 'You feed the crystal and it does nothing.')
      result = described_class.run(world, entries, 'crystal')
      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:denied)
      expect(result.line).to eq('You feed the crystal and it does nothing.')
    end

    it 'confirms on the event alone when nothing is expected, and times out on silence' do
      answer_with(event: :user_orb_charges, charges: 2)
      expect(described_class.run(world, entries, 'orb').reason).to eq(:confirmed)

      answer_with
      tick = 0.0
      allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:clock_now) { tick += 1; Time.at(tick) }
      result = described_class.run(world, entries, 'orb')
      expect(result.status).to eq(:timeout)
      expect(result.reason).to eq(:no_confirmation)
    end

    it 'fails a name the profile does not define without sending' do
      answer_with(ok: true)
      result = described_class.run(world, entries, 'ward')
      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:unknown_preparation)
      expect(result.line).to eq('ward')
      expect(sent).to be_empty
    end

    it 'declines while dead' do
      me[:dead?] = true
      answer_with(ok: true)
      expect(described_class.run(world, entries, 'crystal').reason).to eq(:dead)
      expect(sent).to be_empty
    end
  end
end

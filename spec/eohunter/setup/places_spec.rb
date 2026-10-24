# frozen_string_literal: true

require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::Places do
  # Two villages joined by open country, shaped like the Hinterwilds: the
  # creatures spawn at scattered points inside each, the rooms between the
  # spawn points carry the village's name, and the country between the
  # villages carries another.
  #
  #   1-2-3 (Ojandhaart)  -  4-5 (Hinterwilds)  -  6-7-8 (Eldurhaart)
  #   spawns at 1 and 3                              spawns at 6 and 8
  let(:titles) do
    {
      1 => '[Ojandhaart, Approach]', 2 => '[Ojandhaart, Smithy]', 3 => '[Ojandhaart, Henge]',
      4 => '[Hinterwilds, Boreal Forest]', 5 => '[Hinterwilds, Snow]',
      6 => '[Eldurhaart, Arch]', 7 => '[Eldurhaart, Hall]', 8 => '[Eldurhaart, Henge]'
    }
  end
  let(:links) { { 1 => [2], 2 => [1, 3], 3 => [2, 4], 4 => [3, 5], 5 => [4, 6], 6 => [5, 7], 7 => [6, 8], 8 => [7] } }
  let(:neighbours) { ->(id) { links[id] || [] } }
  let(:creatures) do
    [{ name: 'gigas skald', room_ids: [1, 6] }, { name: 'gigas berserker', room_ids: [3, 8] }]
  end

  def find(places, name) = places.find { |place| place[:name] == name }

  # The whole point: creatures spawn at scattered points, not in a block. Of
  # the nineteen rooms the real Hinterwilds gigas spawn in, only two touch
  # another spawn room -- so walking spawn rooms alone finds nineteen places.
  it 'grows a place through the rooms between its spawn points' do
    places = described_class.within(creatures, titles, neighbours: neighbours)
    expect(find(places, 'Ojandhaart')[:room_ids]).to eq([1, 2, 3])
  end

  # Villages are joined by open country. A walk that ignored titles would
  # cross it and swallow the whole region as one place.
  it 'stops at the edge of a place, so neighbouring villages stay apart' do
    places = described_class.within(creatures, titles, neighbours: neighbours)
    expect(places.map { |place| place[:name] }).to contain_exactly('Ojandhaart', 'Eldurhaart')
    expect(find(places, 'Ojandhaart')[:room_ids]).not_to include(4, 5, 6)
  end

  it 'attributes each creature to the places it actually spawns in' do
    places = described_class.within(creatures, titles, neighbours: neighbours)
    expect(find(places, 'Ojandhaart')[:creature_names]).to contain_exactly('gigas berserker', 'gigas skald')
  end

  # A creature living in one village only must not be offered for another --
  # this is the flayed disciple, which is in Angargreft and nowhere else.
  it 'keeps a creature out of a place it does not live in' do
    only_here = [{ name: 'flayed disciple', room_ids: [1] }]
    places = described_class.within(only_here + creatures, titles, neighbours: neighbours)
    expect(find(places, 'Eldurhaart')[:creature_names]).not_to include('flayed disciple')
  end

  # One place reached from two spawn points through a room the walk will not
  # cross would otherwise be offered twice, meaning different things.
  it 'merges two groups that name the same place' do
    split_links = { 1 => [2], 2 => [1], 3 => [], 8 => [] }
    places = described_class.within(
      [{ name: 'gigas', room_ids: [1, 3] }],
      { 1 => '[Ojandhaart, Approach]', 2 => '[Ojandhaart, Smithy]', 3 => '[Ojandhaart, Henge]' },
      neighbours: ->(id) { split_links[id] || [] }
    )
    expect(places.map { |place| place[:name] }).to eq(['Ojandhaart'])
    expect(find(places, 'Ojandhaart')[:room_ids]).to contain_exactly(1, 2, 3)
  end

  it 'reads the place out of a bracketed room title' do
    expect(described_class.place_of('[Ojandhaart, Mid Street]')).to eq('Ojandhaart')
    expect(described_class.place_of('The Long Snow')).to eq('The Long Snow')
    expect(described_class.place_of('')).to be_nil
  end

  # An undivided area is one choice, not two identical ones.
  it 'offers places only when they say more than the habitat did' do
    expect(described_class.useful?([{ name: 'Only' }])).to be(false)
    expect(described_class.useful?([{ name: 'One' }, { name: 'Two' }])).to be(true)
  end

  it 'searches places and creatures as well as the habitat name' do
    haystack = described_class.haystack(
      name: 'Hinterwilds', places: [{ name: 'Ojandhaart' }], creatures: [{ name: 'gigas skald' }]
    )
    expect(haystack).to include('hinterwilds', 'ojandhaart', 'gigas skald')
  end

  # A room title is [location, area-or-room], and which of the two the second
  # part is shows in how many rooms share it. "[Angargreft, Sanguine Grove]"
  # covers 17 rooms and is a hunting ground; "[Ojandhaart, Smithy]" covers one
  # and is a room in a village. So a big suffix splits and a small one does
  # not -- otherwise choosing Angargreft means all 98 of its rooms at once.
  describe 'a location whose second part names areas' do
    let(:complex) do
      titles = {}
      links = Hash.new { |hash, key| hash[key] = [] }
      ids = (1..24).to_a
      ids.each_cons(2) { |a, b| links[a] << b; links[b] << a }
      (1..10).each { |id| titles[id] = '[Angargreft, Sanguine Grove]' }
      (11..20).each { |id| titles[id] = '[Angargreft, Pits of the Dead]' }
      (21..24).each { |id| titles[id] = '[Angargreft, Greatchamber]' }
      [titles, ->(id) { links[id] }]
    end

    it 'splits the areas apart and leaves the rooms together' do
      titles, neighbours = complex
      places = described_class.within(
        [{ name: 'disciple', room_ids: [2, 12, 22] }], titles, neighbours: neighbours
      )
      names = places.map { |place| place[:name] }
      expect(names).to include('Angargreft, Sanguine Grove', 'Angargreft, Pits of the Dead')
      # Greatchamber is four rooms: a room in the complex, not an area of it.
      expect(names).not_to include('Angargreft, Greatchamber')
    end

    it 'offers no subdivision that nothing spawns in' do
      titles, neighbours = complex
      places = described_class.within(
        [{ name: 'disciple', room_ids: [2] }], titles, neighbours: neighbours
      )
      expect(places.map { |place| place[:name] }).to eq(['Angargreft, Sanguine Grove'])
    end
  end

  it 'reads the room or area out of the second part of a title' do
    expect(described_class.suffix_of('[Angargreft, Sanguine Grove]')).to eq('Sanguine Grove')
    expect(described_class.suffix_of('[Ojandhaart]')).to be_nil
  end
end

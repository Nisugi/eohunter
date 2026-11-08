# frozen_string_literal: true

require 'ostruct'
require_relative '../../../scripts/eohunter/setup/geography'
require_relative '../engine_helper'

RSpec.describe EO::HunterSetup::Geography, 'finding a place to look at' do
  let(:rooms) do
    [OpenStruct.new(id: 1, uid: [101], title: ['[Town Square, Centre]'], location: 'Town', image: 'town.png', image_coords: [0, 0, 10, 10],
                    wayto: {}, tags: ['meta:mapname:Wehnimer\'s Landing']),
     OpenStruct.new(id: 2, uid: [102], title: ['[Town Square, East]'], location: 'Town', image: 'town.png', image_coords: [20, 0, 30, 10], wayto: {}),
     OpenStruct.new(id: 3, uid: [103], title: ['[Mead Hall]'], location: 'Far Village', image: 'far.png', image_coords: [0, 0, 10, 10], wayto: {}),
     OpenStruct.new(id: 4, uid: [104], title: ['[Mead Hall, Kitchen]'], location: 'Far Village', image: 'far.png', image_coords: [20, 0, 30, 10], wayto: {}),
     OpenStruct.new(id: 5, uid: [105], title: ['[Nowhere, Undrawn]'], location: 'Far Village', wayto: {}),
     OpenStruct.new(id: 6, uid: [106], title: ['[Crossing]'], location: 'Far Village', image: 'town.png', image_coords: [40, 0, 50, 10], wayto: {})]
  end
  let(:geography) do
    described_class.new(templates: [], rooms: rooms, uid_resolver: ->(uid) { rooms.select { |room| room.uid.include?(uid) }.map(&:id) })
  end

  it 'names every sheet and every location, each with the sheet most of it is drawn on' do
    names = geography.area_names
    expect(names.map { |entry| entry[:name] }).to eq(['Far Village', 'Town', "Wehnimer's Landing"])
    expect(names.find { |entry| entry[:name] == 'Far Village' }[:image]).to eq('far.png')
    expect(names.find { |entry| entry[:name] == "Wehnimer's Landing" }[:image]).to eq('town.png')
  end

  it 'finds drawn rooms by part of a title, titles before locations, and never an undrawn one' do
    found = geography.room_search(query: 'mead hall')
    expect(found.map { |room| room[:id] }).to eq([3, 4])
    expect(found.first).to include(image: 'far.png', sheet_label: 'far.png', title: '[Mead Hall]')
    expect(geography.room_search(query: 'far village').map { |room| room[:id] }).to eq([3, 4, 6])
    expect(geography.room_search(query: 'nowhere')).to be_empty
    expect(geography.room_search(query: '   ')).to be_empty
  end

  it 'names the sheets a creature lives on from its rooms, whatever its areas are called' do
    beast = OpenStruct.new(name: 'Beast', areas: [{ name: 'Not A Map Name', uids: [101..102] }, { name: 'Elsewhere', uids: [104] }])
    gnat = OpenStruct.new(name: 'gnat', areas: [{ name: 'Nowhere', uids: [105, 900] }])
    with_creatures = described_class.new(templates: [beast, gnat], rooms: rooms,
                                         uid_resolver: ->(uid) { rooms.select { |room| room.uid.include?(uid) }.map(&:id) })
    expect(with_creatures.creature_sheets('beast')).to eq([{ id: 'far.png', name: 'far.png' }, { id: 'town.png', name: "Wehnimer's Landing" }])
    expect(with_creatures.creature_sheets('gnat')).to be_empty
    expect(with_creatures.creature_sheets('nobody')).to be_empty
  end

  it 'takes a room id or a UID as well' do
    expect(geography.room_search(query: '2').map { |room| room[:id] }).to eq([2])
    expect(geography.room_search(query: 'u103').map { |room| room[:id] }).to eq([3])
    expect(geography.room_search(query: 'u105')).to be_empty
  end
end

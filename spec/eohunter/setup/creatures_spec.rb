# frozen_string_literal: true

require_relative '../../../scripts/eohunter/setup/creatures'

RSpec.describe EO::HunterSetup::Creatures do
  # Shaped like the installed templates, including the nils: the Elemental
  # Confluence creatures really do carry sleepable: nil, blood: nil and
  # witherable: nil, and that is the case the sparse filters exist for.
  def template(name, level, family, type, **rest)
    defaults = { undead: false, boss: false, bcs: true, max_hp: 300, otherclass: [],
                 areas: [{ name: 'Somewhere', uids: [1] }],
                 sleepable: nil, witherable: nil, sympathy: nil, muggable: nil,
                 blood: nil, bones: nil, limbs: nil }
    Struct.new(*(%i[name level family type] + defaults.keys), keyword_init: true)
          .new(**defaults.merge(rest).merge(name: name, level: level, family: family, type: type))
  end

  let(:templates) do
    [template('huge air elemental', 95, 'Elemental', 'Elemental',
              otherclass: %w[Extraplanar Magical],
              areas: [{ name: 'Elemental Confluence', uids: [580_001] }]),
     template('gigas skald', 105, 'Giant', 'Biped', sleepable: true, blood: true,
              areas: [{ name: 'Hinterwilds', uids: [1] }]),
     template('flayed gigas disciple', 113, 'Giant', 'Biped', undead: true, sleepable: false,
              otherclass: ['Corporeal undead'],
              areas: [{ name: 'Hinterwilds', uids: [2] }]),
     template('forest troll', 12, 'Troll', 'Biped', sleepable: true, blood: true)]
  end
  let(:entries) { described_class.catalogue(templates) }

  describe 'the level range it opens with' do
    it 'looks a little below and further above the character' do
      expect(described_class.default_range(100)).to eq(low: 95, high: 110)
    end

    it 'never asks for a level below one' do
      expect(described_class.default_range(3)[:low]).to eq(1)
    end

    it 'offers the whole span when the level is unknown' do
      expect(described_class.default_range(nil)).to eq(low: 1, high: 100)
    end
  end

  describe 'the catalogue' do
    it 'is ordered by level, then by name' do
      expect(entries.map { |entry| entry[:name] })
        .to eq(['forest troll', 'huge air elemental', 'gigas skald', 'flayed gigas disciple'])
    end

    # nil is "nobody has checked", and flattening it to false is the whole
    # trap the sparse filters exist to avoid.
    it 'keeps an uncatalogued trait as unknown rather than as a no' do
      air = entries.find { |entry| entry[:name] == 'huge air elemental' }
      expect(air[:traits][:sleepable]).to be_nil
      expect(air[:traits][:blood]).to be_nil
    end
  end

  # An installed CreatureTemplate spells its traits as predicates, three of
  # them with a `has_` prefix (creature.rb:237-286). Reading a bare
  # `sleepable` off one finds no method and answers nil -- which is a wrong
  # answer that looks exactly like the right one, because nil IS the unknown
  # value. Every filter reported the whole band uncatalogued and nothing
  # looked broken.
  describe 'reading a real template' do
    let(:lich_like) do
      Class.new do
        def name = 'gigas skald'
        def level = 105
        def family = 'Giant'
        def type = 'Biped'
        def undead = false
        def boss = false
        def bcs = true
        def max_hp = 300
        def otherclass = []
        def areas = [{ name: 'Hinterwilds', uids: [1] }]
        def sleepable? = true
        def has_blood? = false
        def witherable? = nil
      end.new
    end

    it 'reads a trait through the predicate the template actually defines' do
      traits = described_class.describe(lich_like)[:traits]
      expect(traits[:sleepable]).to be(true)
      expect(traits[:blood]).to be(false)
    end

    it 'still reports a trait the template does not answer as unknown' do
      expect(described_class.describe(lich_like)[:traits][:witherable]).to be_nil
      expect(described_class.describe(lich_like)[:traits][:bones]).to be_nil
    end
  end

  describe 'searching' do
    it 'narrows to a level range' do
      found = described_class.search(entries, low: 95, high: 110)
      expect(found.map { |entry| entry[:name] }).to contain_exactly('huge air elemental', 'gigas skald')
    end

    it 'matches part of a name, whatever the case' do
      expect(described_class.search(entries, name: 'GIGAS').size).to eq(2)
    end

    it 'narrows to a family' do
      expect(described_class.search(entries, families: ['Giant']).size).to eq(2)
    end

    it 'narrows to an other-class' do
      found = described_class.search(entries, classes: ['Corporeal undead'])
      expect(found.map { |entry| entry[:name] }).to eq(['flayed gigas disciple'])
    end

    it 'separates the undead from the living' do
      expect(described_class.search(entries, undead: true).size).to eq(1)
      expect(described_class.search(entries, undead: false).size).to eq(3)
    end

    # The filter that would have quietly lied. Asking for sleepable creatures
    # must not hide the ones nobody has checked -- an uncatalogued creature is
    # a gap in the wiki, not an answer.
    it 'keeps a creature whose trait is unknown when asking for that trait' do
      found = described_class.search(entries, traits: { sleepable: true })
      expect(found.map { |entry| entry[:name] })
        .to include('gigas skald', 'huge air elemental')
      # ...and still drops the one known NOT to be.
      expect(found.map { |entry| entry[:name] }).not_to include('flayed gigas disciple')
    end

    it 'drops the unknowns when asked to' do
      found = described_class.search(entries, traits: { sleepable: true }, unknown_traits: false)
      expect(found.map { |entry| entry[:name] }).to eq(['forest troll', 'gigas skald'])
    end

    # 5% of the installed templates have no level, and hiding them for a
    # missing field is the same mistake as treating an unknown trait as a no.
    it 'keeps a creature with no level recorded' do
      unlevelled = described_class.catalogue([template('mystery', nil, 'Unknown', 'Biped')])
      expect(described_class.search(unlevelled, low: 90, high: 100).size).to eq(1)
    end
  end

  describe 'what the filters can offer' do
    it 'reads the families from the creatures themselves' do
      expect(described_class.values_for(entries, :family)).to eq(%w[Elemental Giant Troll])
    end

    it 'reads the other-classes the same way' do
      expect(described_class.classes_for(entries)).to eq(['Corporeal undead', 'Extraplanar', 'Magical'])
    end

    # An empty result has two quite different causes, and a player cannot act
    # on the difference unless they are told it.
    it 'says how many creatures a trait is actually known for' do
      expect(described_class.trait_tally(entries, :sleepable)).to eq(yes: 2, no: 1, unknown: 1)
    end
  end

  describe 'where those creatures live' do
    it 'names the areas, the one with most of them first' do
      areas = described_class.areas_for(entries)
      expect(areas.first[:name]).to eq('Hinterwilds')
      expect(areas.first[:creatures]).to eq(['flayed gigas disciple', 'gigas skald'])
    end

    it 'counts a creature once in an area however many rooms it uses' do
      twice = [template('wanderer', 50, 'Humanoid', 'Biped',
                        areas: [{ name: 'Here', uids: [1] }, { name: 'Here', uids: [2] }])]
      areas = described_class.areas_for(described_class.catalogue(twice))
      expect(areas.size).to eq(1)
      expect(areas.first[:creatures]).to eq(['wanderer'])
    end
  end
end

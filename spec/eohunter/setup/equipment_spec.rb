# frozen_string_literal: true

require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::Equipment do
  # Shaped like a real ready list: some slots hold something, some are empty,
  # and the empty ones are reported as nil rather than omitted.
  let(:ready) do
    {
      'shield'           => nil,
      'weapon'           => { noun: 'bow', name: 'a scorched glowbark long bow' },
      'secondary_weapon' => { noun: 'longbow', name: 'a darkened ruic longbow etched with thorns' },
      'ranged_weapon'    => nil,
      'ammo_bundle'      => { noun: 'arrows', name: 'a bundle of faewood arrows' },
      'ammo2_bundle'     => nil,
      'sheath'           => { noun: 'bandolier', name: 'a quilled iron boar hide bandolier' }
    }
  end
  let(:inventory) do
    [
      { noun: 'bow', name: 'a yew long bow', types: 'weapon' },
      { noun: 'knife', name: 'a narrow vultite knife', types: 'weapon' },
      { noun: 'longbow', name: 'a darkened ruic longbow etched with thorns', types: 'weapon' },
      { noun: 'hammer', name: 'a heavy iron hammer', types: 'weapon' },
      { noun: 'pouch', name: 'a silk pouch', types: 'container' },
      { noun: 'wand', name: 'an ivory wand', types: 'wand' }
    ]
  end

  def values(options) = options.map { |option| option['value'] }
  def labels(options) = options.map { |option| option['label'] }

  describe 'the hands' do
    it 'offers keep and empty first, since they are what most hunts want' do
      options = described_class.hand_options('right', ready: ready, inventory: inventory)
      expect(values(options).first(2)).to eq(%w[keep empty])
    end

    # An empty slot is a line that cannot be chosen usefully, and a list of
    # them buries the entries that can -- which is what the picker looked like
    # before: seven slots, six of them saying "nothing readied".
    it 'skips a slot with nothing in it' do
      options = described_class.hand_options('right', ready: ready, inventory: inventory)
      expect(values(options)).not_to include('ready:ranged_weapon')
      expect(labels(options).join(' ')).not_to include('nothing readied')
    end

    # The tag says which slot, the name says which item. "Weapon" alone did
    # not tell two bows apart.
    it 'labels a readied slot with its tag and the item itself' do
      options = described_class.hand_options('right', ready: ready, inventory: inventory)
      weapon = options.find { |option| option['value'] == 'ready:weapon' }
      expect(weapon['label']).to eq('[W] scorched glowbark long bow')
      second = options.find { |option| option['value'] == 'ready:secondary_weapon' }
      expect(second['label']).to eq('[W2] darkened ruic longbow etched with thorns')
    end

    it 'offers ready slots before loose inventory, since the engine resolves them without a search' do
      options = values(described_class.hand_options('right', ready: ready,
                                                            inventory: inventory, armaments: armaments))
      last_slot = options.rindex { |value| value.start_with?('ready:') }
      first_item = options.index('narrow vultite knife')
      expect(first_item).not_to be_nil
      expect(last_slot).to be < first_item
    end

    # Stash resolves a wanted item by whole name first, then by part of it,
    # then by noun (match_specificity scores an exact name 0), so the name is
    # the most precise thing a saved hunt can carry -- and the thing that
    # tells a yew long bow from a glowbark one. The noun made them one choice.
    it 'stores the name, which is what tells two of a kind apart' do
      carried = [
        { noun: 'bow', name: 'a yew long bow', types: 'weapon' },
        { noun: 'bow', name: 'a scorched glowbark long bow', types: 'weapon' }
      ]
      shown = values(described_class.hand_options('right', ready: {},
                                                           inventory: carried, armaments: armaments))
      expect(shown).to include('yew long bow', 'scorched glowbark long bow')
    end

    # The same longbow is in the ready list and the pack; offering it twice
    # makes the list longer without making it more useful.
    it 'does not repeat an item already reachable through a slot' do
      shown = labels(described_class.hand_options('right', ready: ready, inventory: inventory))
      expect(shown.count { |label| label.include?('darkened ruic longbow') }).to eq(1)
    end

    it 'offers a shield slot to the left hand only' do
      left = values(described_class.hand_options('left', ready: ready, inventory: inventory))
      right = values(described_class.hand_options('right', ready: ready, inventory: inventory))
      # nothing is readied in the shield slot here, so neither offers it...
      expect(left).not_to include('ready:shield')
      expect(right).not_to include('ready:shield')
      # ...but with a shield readied, only the left hand does
      armed = ready.merge('shield' => { noun: 'shield', name: 'a tower shield' })
      expect(values(described_class.hand_options('left', ready: armed, inventory: inventory)))
        .to include('ready:shield')
      expect(values(described_class.hand_options('right', ready: armed, inventory: inventory)))
        .not_to include('ready:shield')
    end

    # Lich's own armament tables, which carry combat statistics for every
    # weapon and shield in the game. They are the only way to recognise most
    # of them: gameobj-data.xml's weapon pattern matches bows and a handful of
    # exotics, so a knife, a falchion and a runestaff are all untyped, and
    # there is no shield type at all.
    let(:armaments) do
      { weapons: ['knife', 'runestaff', 'long bow', 'falchion', 'war hammer', 'leather whip', 'shortsword'],
        shields: ['tower shield', 'buckler', 'kite shield'] }
    end

    it 'finds weapons the type data does not name' do
      shown = labels(described_class.hand_options('right', ready: ready,
                                                           inventory: inventory, armaments: armaments))
      expect(shown).to include('narrow vultite knife')
    end

    it 'finds a shield in the pack that has not been readied, and only for the off hand' do
      carried = inventory + [{ noun: 'shield', name: 'a tower shield', types: 'armor' }]
      left = labels(described_class.hand_options('left', ready: ready,
                                                         inventory: carried, armaments: armaments))
      expect(left).to include('tower shield')
      right = labels(described_class.hand_options('right', ready: ready,
                                                           inventory: carried, armaments: armaments))
      expect(right).not_to include('tower shield')
    end

    it 'does not offer a carried shield twice when it is also readied' do
      carried = inventory + [{ noun: 'shield', name: 'a tower shield', types: 'armor' }]
      armed = ready.merge('shield' => { noun: 'shield', name: 'a tower shield' })
      shown = labels(described_class.hand_options('left', ready: armed,
                                                          inventory: carried, armaments: armaments))
      expect(shown.count { |label| label.include?('tower shield') }).to eq(1)
    end

    # WeaponStats covers everything that computes a damage factor, creatures
    # included -- its `natural` category is bite, claw, pincer and stinger.
    # The script excludes that category when it captures the tables, so a
    # severed claw in a pack is not offered as something to hunt with. This
    # holds the other half: whatever is handed in is all that is matched.
    it 'offers only what it was given names for' do
      carried = [
        { noun: 'claw', name: 'a severed rolton claw', types: nil },
        { noun: 'knife', name: 'a narrow vultite knife', types: nil }
      ]
      shown = labels(described_class.hand_options('right', ready: {},
                                                           inventory: carried, armaments: armaments))
      expect(shown).to include('narrow vultite knife')
      expect(shown).not_to include('severed rolton claw')
    end

    # "disc" is a real thrown weapon in the armament tables and also what a
    # player's inventory disc is called, and nothing in either name says
    # which. The inventory feed settles it: a container has contents or
    # advertises a weight cap, and nothing a hand is told to hold does.
    it 'offers a throwing disc but not the disc things are carried on' do
      carried = [
        { noun: 'disc', name: 'a weathered bronze disc', types: 'uncommon', container: true },
        { noun: 'disc', name: 'a bladed throwing disc', types: nil, container: false }
      ]
      tables = { weapons: ['disc'], shields: [] }
      shown = labels(described_class.hand_options('right', ready: {},
                                                           inventory: carried, armaments: tables))
      expect(shown).to include('bladed throwing disc')
      expect(shown).not_to include('weathered bronze disc')
    end

    # The tables file "arrow" under edged, because a swung arrow really is an
    # edged weapon -- their own comment says "when swung, not when fired".
    # True, and not what a player means by what should be in their hands.
    it 'keeps ammunition out of the hands and in the ammunition picker' do
      carried = [
        { noun: 'arrow', name: 'a glowbark arrow', types: nil, container: false },
        { noun: 'arrows', name: 'a bundle of faewood arrows', types: 'ammo', container: false },
        { noun: 'knife', name: 'a narrow vultite knife', types: nil, container: false }
      ]
      tables = { weapons: %w[arrow knife], shields: [] }
      hands = labels(described_class.hand_options('right', ready: {},
                                                           inventory: carried, armaments: tables))
      expect(hands).to include('narrow vultite knife')
      # "narrow" contains "arrow", so match the entries rather than the text.
      expect(hands).not_to include('glowbark arrow', 'bundle of faewood arrows')
      ammo = labels(described_class.ammo_options(ready: {}, inventory: carried))
      expect(ammo).to include('bundle of faewood arrows')
    end

    # A table name is matched as a phrase, not as loose words. Matching single
    # words made "a leather backpack" a weapon, because some weapon in the
    # tables is made of leather.
    it 'does not mistake an ordinary item for a weapon' do
      carried = [
        { noun: 'backpack', name: 'a leather backpack', types: 'container' },
        { noun: 'pouch', name: 'a silk pouch', types: 'container' },
        { noun: 'diamond', name: 'a bloodjewel diamond', types: 'gem' }
      ]
      shown = labels(described_class.hand_options('left', ready: {},
                                                          inventory: carried, armaments: armaments))
      expect(shown).to contain_exactly('Leave the hand alone', 'Empty the hand')
    end

    it 'matches a qualified weapon name inside a longer one' do
      carried = [{ noun: 'hammer', name: 'a vultite war hammer', types: nil }]
      shown = labels(described_class.hand_options('right', ready: {},
                                                           inventory: carried, armaments: armaments))
      expect(shown).to include('vultite war hammer')
    end

    # Without the tables the pickers fall back to type matching, which finds
    # the bows and misses the rest -- thin, but not a guessed list that would
    # drift from the game's own.
    it 'still offers what the type data does name when the tables are absent' do
      carried = [{ noun: 'crossbow', name: 'a heavy crossbow', types: 'weapon' }]
      shown = labels(described_class.hand_options('right', ready: {}, inventory: carried))
      expect(shown).to include('heavy crossbow')
    end

    it 'offers the weapons it is carrying, named as they appear' do
      options = described_class.hand_options('right', ready: ready,
                                                      inventory: inventory, armaments: armaments)
      expect(labels(options)).to include('narrow vultite knife', 'heavy iron hammer')
    end

    # The readied bow is also sitting in the pack -- the ready list and the
    # container both report it -- and it should be one choice, reached through
    # its slot, which is what the engine resolves without a search.
    #
    # Two items that merely share a NOUN are still two choices: a yew long bow
    # and a glowbark one are different bows. Stash agrees -- it deduplicates
    # its own matches by id and then by name, never by noun.
    it 'collapses the readied item and its pack entry into one choice' do
      carried = inventory + [{ noun: 'bow', name: 'a scorched glowbark long bow', types: 'weapon' }]
      options = described_class.hand_options('right', ready: ready,
                                                      inventory: carried, armaments: armaments)
      bows = labels(options).select { |label| label.include?('glowbark') }
      expect(bows).to eq(['[W] scorched glowbark long bow'])
      expect(labels(options)).to include('yew long bow')
    end

    # Two of a kind are one choice, and the cases work out:
    #
    # If which hand each sword goes in matters, they are in the ready list,
    # and the slot resolves them however their ids churn. If it does not
    # matter, they are interchangeable and one choice is the whole truth.
    # If it matters and they are still identically named, that is for the
    # player to distinguish -- no stored value could do it for them, since
    # the name is all the engine matches on.
    #
    # Stash agrees: "items with identical names are interchangeable and
    # collapse to the first", ranked by where the item is, so asking for the
    # name gets the most reachable copy.
    it 'offers one choice for two items of the same name' do
      carried = [
        { noun: 'shortsword', name: 'a vultite shortsword', types: nil },
        { noun: 'shortsword', name: 'a vultite shortsword', types: nil }
      ]
      shown = values(described_class.hand_options('right', ready: {},
                                                           inventory: carried, armaments: armaments))
      expect(shown.count('vultite shortsword')).to eq(1)
    end

    # A select whose options repeat a value cannot tell them apart. Two items sharing a noun is ordinary, so this is the rule, not a net.
    it 'never repeats a value, however the lists overlap' do
      carried = inventory + [
        { noun: 'knife', name: 'a curved bone knife', types: nil },
        { noun: 'shield', name: 'a tower shield', types: nil },
        { noun: 'shield', name: 'an oak buckler', types: nil }
      ]
      %w[right left].each do |hand|
        values = values(described_class.hand_options(hand, ready: ready,
                                                           inventory: carried, armaments: armaments))
        expect(values.size).to eq(values.uniq.size), "#{hand} hand repeats a value"
      end
    end

    it 'offers nothing a hand cannot hold' do
      shown = labels(described_class.hand_options('right', ready: ready, inventory: inventory))
      expect(shown.join(' ')).not_to include('silk pouch')
    end

    # A wand is a hand item, but not one most hunts mean by "what should be in
    # your hands", so it is asked for rather than assumed.
    it 'offers wands only when asked' do
      without = labels(described_class.hand_options('right', ready: ready, inventory: inventory))
      with = labels(described_class.hand_options('right', ready: ready, inventory: inventory, wands: true))
      expect(without.join(' ')).not_to include('ivory wand')
      expect(with.join(' ')).to include('ivory wand')
    end
  end

  describe 'ammunition' do
    it 'offers the readied ammo before loose ammunition, and skips the empty slot' do
      options = described_class.ammo_options(ready: ready, inventory: inventory)
      expect(values(options).first).to eq('')
      expect(values(options)).to include('ready:ammo_bundle')
      expect(values(options)).not_to include('ready:ammo2_bundle')
      expect(labels(options)).to include('[A] bundle of faewood arrows')
    end

    it 'offers no weapons, since they are not ammunition' do
      shown = labels(described_class.ammo_options(ready: ready, inventory: inventory))
      expect(shown.join(' ')).not_to include('knife')
      expect(shown.join(' ')).not_to include('long bow')
    end
  end

  # The captured records are Hashes, but a live GameObj answers the same
  # questions as methods. Reading either keeps the harness honest.
  it 'reads a record that answers with methods rather than keys' do
    item = Struct.new(:noun, :name, :type).new('halberd', 'a rusted halberd', 'weapon')
    options = described_class.hand_options('right', ready: {}, inventory: [item])
    expect(labels(options)).to include('rusted halberd')
  end

  it 'drops the article, which is noise in a list' do
    expect(described_class.display_name(noun: 'bow', name: 'a scorched glowbark long bow'))
      .to eq('scorched glowbark long bow')
    expect(described_class.display_name(noun: 'arrows', name: 'some faewood arrows'))
      .to eq('faewood arrows')
  end
end

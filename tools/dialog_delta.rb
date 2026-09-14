# frozen_string_literal: true

# Mines a Lich XML session log for what a creature ability actually did.
#
# The bestiary's `abilities:` block (lich-5/lib/gemstone/creatures) wants
# the spell number, the display name and the duration of an effect a
# creature put on us. All three are already in the session log: Simutronics
# pushes a `dialogData` for Buffs / Debuffs / Active Spells / Cooldowns
# whenever one changes, and each entry carries the spell number as the
# progressBar id, the name as its text and the remaining time as `time=`.
#
#   <progressBar id='1708' value='50' text="Mystic Impedance" time='00:00:30'/>
#
# Finding that by hand means grepping a multi-megabyte XML for a line, then
# eyeballing which dialog entry is new. This does the diff: give it a log
# and something to look for, and it prints the effects that appeared, with
# the surrounding game text.
#
#   ruby tools/dialog_delta.rb LOG --match "golden runes"
#   ruby tools/dialog_delta.rb LOG --line 25963
#   ruby tools/dialog_delta.rb LOG --match "flicks a finger" --context 6
#
# Written for the 2026-09-13 Mystic Impedance (1708) investigation, where
# the engine re-sent a blocked `incant 515` 48 times because nothing knew
# the debuff existed. See docs/creature-abilities-proposal.md.
#
# Pure Ruby, no Lich: runs anywhere a log is readable.
module EOHunter
  # One pass over a log, tracking what each dialog holds as it goes.
  class DialogDelta
    # The dialogs worth diffing. Cooldowns is ours, not a creature's, but
    # an ability can put us on one, so it is watched too.
    DIALOGS = %w[Buffs Debuffs Active\ Spells Cooldowns].freeze

    # A dialogData block, with its id and body.
    DIALOG = /<dialogData id='([^']*)'([^>]*)>(.*?)(?=<dialogData|\z)/m
    # One effect inside a dialog body.
    BAR = /<progressBar id='([^']*)'[^>]*?text="([^"]*)"([^>]*)\/>/
    # `time=` trails the layout attributes, so it is pulled from the rest.
    TIME = /time='([^']*)'/
    # A dialogData that clears the dialog before repopulating it.
    CLEAR = /clear='t'/

    Effect = Struct.new(:dialog, :id, :name, :time, :line, keyword_init: true)

    # @param path [String] the .xml session log
    def initialize(path)
      @path = path
    end

    # Every effect that appeared within `window` lines after the anchor.
    #
    # @param anchor [Integer] the 1-based line the effect landed on
    # @param window [Integer] how many lines after the anchor to watch
    # @return [Array<Effect>] the effects that were not present before
    def appeared(anchor:, window: 400)
      before = {}
      after  = []
      each_dialog do |dialog, body, lineno|
        next unless DIALOGS.include?(dialog)

        body.scan(BAR) do |id, name, rest|
          time = rest[TIME, 1]
          effect = Effect.new(dialog: dialog, id: id, name: name, time: time, line: lineno)
          if lineno < anchor
            before[[dialog, id]] = true
          elsif lineno <= anchor + window
            after << effect
          end
        end
      end
      # First sighting only: a countdown re-pushes the same bar every tick,
      # so an effect that was absent before the anchor still appears once
      # per push afterwards. Keep the earliest, which carries the full
      # duration in `time=`.
      seen = {}
      after.each_with_object([]) do |effect, kept|
        key = [effect.dialog, effect.id]
        next if before[key] || seen[key]

        seen[key] = true
        kept << effect
      end
    end

    # The lines matching a pattern, as anchors.
    #
    # @param pattern [Regexp]
    # @return [Array<Integer>] 1-based line numbers
    def find(pattern)
      hits = []
      File.foreach(@path).with_index(1) { |line, n| hits << n if line =~ pattern }
      hits
    end

    # Game text around a line, tags stripped, for reading what happened.
    #
    # @param anchor [Integer]
    # @param context [Integer] lines either side
    # @return [Array<Array(Integer, String)>] line number and text
    def prose(anchor:, context: 3)
      out = []
      File.foreach(@path).with_index(1) do |line, n|
        next if n < anchor - context || n > anchor + context

        text = line.gsub(/<[^>]*>/, '').gsub(/&gt;/, '>').gsub(/&lt;/, '<').gsub(/&amp;/, '&').strip
        out << [n, text] unless text.empty?
      end
      out
    end

    private

    # Each dialogData block with the line it started on. Blocks can span
    # lines, so the file is read whole and offsets mapped back to lines.
    def each_dialog
      body = File.read(@path)
      starts = line_starts(body)
      body.scan(DIALOG) do
        match = Regexp.last_match
        next if match[2] =~ CLEAR && match[3].strip.empty?

        yield match[1], match[3], line_for(starts, match.begin(0))
      end
    end

    def line_starts(body)
      offsets = [0]
      body.each_char.with_index { |c, i| offsets << i + 1 if c == "\n" }
      offsets
    end

    # Binary search the offset back to a 1-based line number.
    def line_for(starts, offset)
      lo = 0
      hi = starts.length - 1
      while lo < hi
        mid = (lo + hi + 1) / 2
        starts[mid] <= offset ? lo = mid : hi = mid - 1
      end
      lo + 1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  path = ARGV.shift
  abort <<~USAGE if path.nil? || !File.exist?(path.to_s)
    usage: ruby tools/dialog_delta.rb LOG [--match TEXT | --line N] [--context N] [--window N]

      --match TEXT   find lines containing TEXT and diff after each
      --line N       diff after line N
      --context N    lines of game text to show around the anchor (default 3)
      --window N     lines after the anchor to watch for new effects (default 400)
  USAGE

  opts = {}
  until ARGV.empty?
    case (flag = ARGV.shift)
    when '--match'   then opts[:match] = ARGV.shift
    when '--line'    then opts[:line] = ARGV.shift.to_i
    when '--context' then opts[:context] = ARGV.shift.to_i
    when '--window'  then opts[:window] = ARGV.shift.to_i
    else abort "unknown option: #{flag}"
    end
  end

  delta = EOHunter::DialogDelta.new(path)
  anchors = opts[:line] ? [opts[:line]] : delta.find(/#{Regexp.escape(opts[:match].to_s)}/i)
  abort 'no anchor: pass --match TEXT or --line N' if anchors.empty?

  puts "#{anchors.length} anchor(s) in #{File.basename(path)}"
  anchors.first(10).each do |anchor|
    puts "\n#{'=' * 70}\nline #{anchor}"
    delta.prose(anchor: anchor, context: opts.fetch(:context, 3)).each do |n, text|
      puts "  #{n == anchor ? '>' : ' '} #{n}: #{text[0, 150]}"
    end
    effects = delta.appeared(anchor: anchor, window: opts.fetch(:window, 400))
    if effects.empty?
      puts '  -- no new dialog effects in window --'
    else
      puts '  -- appeared --'
      effects.each { |e| puts format('  %-14s id=%-10s %-28s %s', e.dialog, e.id, e.name, e.time) }
    end
  end
end

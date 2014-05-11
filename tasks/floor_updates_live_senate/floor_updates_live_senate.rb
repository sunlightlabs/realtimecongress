# encoding: utf-8

require 'nokogiri'

class FloorUpdatesLiveSenate

  def self.run(options = {})

    count = 0
    failures = []

    html = nil
    begin
      url = "http://www.periodicalpress.senate.gov/"
      url << "?break_cache=#{Time.now.to_i}" unless allow_cache?
      html = Utils.curl url
    rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ENETUNREACH
      Report.note self, "Network error on fetching the floor log, can't go on."
      return
    end

    doc = Nokogiri::HTML html

    unless container = doc.css("div.entry-content").first
      Report.note self, "Can't locate title of the floor log, can't go on.", {html: html}
      return
    end

    # accumulate results in hash, keyed by date string, values are array of text updates
    updates = {}
    current_date = nil

    warnings = []

    (container.parent / :p).each do |item|
      # ignore headers and footer
      next if ["senate floor proceedings", "today's senate floor log", "\302\240"].include?(item.text.strip.downcase)
      next if [/archived floor logs/i, /floor lof is for reference only/i].find {|r| item.text.strip =~ r}

      if (item['style'] =~ /text-align: center/i) or (item['align'] == 'center')
        if Time.zone.parse(item.text)
          current_date = Utils.utc_parse(item.text).strftime "%Y-%m-%d"
          updates[current_date] ||= []
        else
          puts "Skipping center-aligned p with text #{item.text}" if options[:debug]
        end

      else # item['align'] == 'left' or item['align'].nil?
        if current_date.nil?
          warnings << {message: "Unexpected HTML, got to an update without a date, skipping", html: item.text}
          next
        end

        updates[current_date] << clean_text(item.text)
      end
    end

    # We'll run this every 5 minutes, so we'll assign a timestamp to an item as soon we find it, if it doesn't exist already
    # If it does exist...we leave it alone.
    # This is *not* an archival script, and the timestamps will also be inaccurate at first - we must accept this.

    session = Utils.current_session

    today = Time.now.midnight

    updates.keys.sort.each do |legislative_day|
      # skip unless it's within a day of today
      this = Time.parse(legislative_day).midnight
      if (this > (today + 1.day)) or (this < (today - 1.day))
        next
      end

      todays = FloorUpdate.where(legislative_day: legislative_day).all.map {|u| u['events']}.flatten
      items = updates[legislative_day]

      # puts legislative_day

      items.each do |item|

        # leave existing items alone
        if todays.include?(item)
          puts "Found a dupe, ignoring" if options[:debug]
          next
        end

        floor_update = FloorUpdate.new(
          chamber: "senate",
          session: session,
          legislative_day: legislative_day,
          timestamp: Time.now,
          events: [item],
          bill_ids: extract_bills(item),
          roll_ids: extract_rolls(item),
          legislator_ids: extract_legislators(item)
        )

        if floor_update.save
          count += 1
          puts "[#{floor_update.timestamp.strftime("%Y-%m-%d %H:%M:%S")}] New floor update on leg. day #{legislative_day}" if options[:debug]

          # sleep for a second so that if we discover multiple things at once on the same day it doesn't get the same timestamp
          sleep 1 unless options[:no_sleep]
        else
          failures << floor_update.attributes
          puts "Failed to save floor update, will file report"
        end
      end
    end

    if failures.any?
      Report.failure self, "Failed to save #{failures.size} floor updates, attributes attached", :failures => failures
    end

    if warnings.any?
      Report.warning self, "Warnings while scanning floor", warnings: warnings
    end

    Report.success self, "Saved #{count} new floor updates"
  end

  def self.extract_bills(text)
    session = Utils.current_session
    matches = text.scan(/((S\.|H\.)(\s?J\.|\s?R\.|\s?Con\.| ?)(\s?Res\.?)*\s?\d+)/i).map {|r| r.first}.uniq.compact
    matches.map {|code| "#{code.gsub(/con/i, "c").tr(" ", "").tr('.', '').downcase}-#{session}" }
  end

  def self.extract_rolls(text)
    [] # unsure how to do this, they never use the roll number that I can see!
  end

  def self.extract_legislators(text)
    []
  end

  def self.clean_text(text)
    text.
      gsub("\342\200\231", "'").
      gsub("\302\240", " ").
      gsub("\342\200\234", "\"").
      gsub("\342\200\235", "\"").
      gsub(/[ \t]+/, ' ').
      gsub("\n", "\n\n").
      strip
  end

  # Senate Periodical Press Gallery goes down from precisely 12am to 1am EST,
  # but can be reached via their CDN/cache/whatever.
  # so, allow caching from 11:55pm to 1:05am EST.
  # also, this stinks, and this should be reported (done) and removed later.
  def self.allow_cache?
    hour = Time.zone.now.hour
    minute = Time.zone.now.min
    (hour == 0) or
      (hour == 11 and minute > 5) or
      (hour == 1 and minute < 5)
  end

end
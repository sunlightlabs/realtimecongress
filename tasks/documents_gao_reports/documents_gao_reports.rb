# encoding: utf-8

require 'nokogiri'
require 'docsplit'

class DocumentsGaoReports

  # Fetches and indexes GAO reports. Can fetch entire years; by default, asks for the last 7 days.
  # options:
  #   gao_id: specify a single report by its GAO ID.
  #   year: fetch a whole year's reports.
  #   limit: a number, limit the number of reports found.
  #   cache: fetch everything from the disk, no network requests.

  def self.run(options = {})

    if options[:gao_id]
      gao_ids = [options[:gao_id]]
    else
      if options[:year]
        beginning = Time.parse("#{options[:year]}-01-01").midnight
        ending = Time.parse("#{options[:year]}-12-31").midnight
      else
        ending = Time.now.midnight
        beginning = ending - 7.days
      end

      gao_ids = gao_ids_for beginning, ending, options

      if options[:limit]
        gao_ids = gao_ids.first options[:limit].to_i
      end
    end

    count = 0
    failures = []
    warnings = []

    puts "Going to fetch #{gao_ids.size} GAO reports..." if options[:debug]

    gao_ids.each do |gao_id|
      
      url = "http://gao.gov/api/id/#{gao_id}"
      cache = cache_path_for gao_id, "report.json"
      unless details = Utils.download(url, options.merge(destination: cache, json: true))
        failures << {gao_id: gao_id, url: url, message: "Couldn't download JSON of report"}
        next
      end

      details = details.first # it's an array of one item for some reason

      # details directly from JSON
      categories = details['topics'] || []
      categories += [details['bucket_term']] if details['bucket_term']
      published_at = Utils.noon_utc_for details['docdate']
      posted_at = Time.parse details['actual_release_date']
      report_number = details['rptno']
      title = details['title']
      gao_type = details['document_type']
      description = strip_tags(details['description']) if details['description'].present?

      # urls
      landing_url = details['url']
      text_url = details['text_url']
      pdf_url = details['pdf_url']
      
      # seen a mixup - http://gao.gov/api/id/586393
      if pdf_url and (pdf_url =~ /\.txt$/)
        text_url = pdf_url
        pdf_url = nil
      # seen it - http://gao.gov/api/id/586175
      elsif pdf_url and (pdf_url !~ /\.pdf$/)
        pdf_url = nil
      end


      unless landing_url or pdf_url
        puts "[#{gao_id}] No landing URL or PDF, skipping..." if options[:debug]
        next
      end

      document_id = "GAO-#{gao_id}"

      attributes = {
        document_id: document_id,
        title: title,
        posted_at: posted_at,
        document_type: 'gao_report',
        document_type_name: "GAO Report",
        url: (landing_url || pdf_url),
        
        source_url: pdf_url,
        published_at: published_at,

        description: description,
        gao_id: gao_id,
        report_number: report_number,
        categories: categories,

        # bonus
        supplement_url: details['supplement_url'],
        youtube_id: details['youtube_id'],
        links: (details['additional_links'] if details['additional_links'].present?)
      }

      puts "[#{gao_id}] Saving report information..." if options[:debug]
      document = Document.find_or_initialize_by document_id: document_id
      document.attributes = attributes

      document.save!

      puts "[#{gao_id}] Successfully saved report"

      count += 1
    end

    if failures.any?
      Report.failure self, "Failed to process #{failures.size} reports, attached", {failures: failures}
    end

    if warnings.any?
      Report.warning self, "Failed to process text for #{warnings.size} reports, attached", {warnings: warnings}
    end

    Report.success self, "Created or updated #{count} GAO Reports"
  end

  # fetch search results for date range, return GAO IDs for every report in the list
  def self.gao_ids_for(beginning, ending, options)
    url = "http://gao.gov/browse/date/custom"
    url << "?adv_begin_date=#{beginning.strftime("%m/%d/%Y")}"
    url << "&adv_end_date=#{ending.strftime("%m/%d/%Y")}"
    url << "&rows=15000" # 2011 had 835, 2010 had 794

    cache = "data/gao/#{beginning.strftime("%Y%m%d")}-#{ending.strftime("%Y%m%d")}.html"
    body = Utils.download(url, options.merge(destination: cache))
    return nil unless body

    Nokogiri::HTML(body).css("div.listing").map do |div|
      div['content_id']
    end
  end

  def self.cache_path_for(gao_id, filename)
    "data/gao/#{gao_id}/#{filename}"
  end

  def self.strip_tags(text)
    text = text.gsub(/<\/?(p|div)>/i, "\n\n").strip
    # text.gsub! /<\/?h2>/, "*"
    text.gsub! /<[^>]+?>/, '' # don't yell at me
    text.gsub! /\n{3,}\s*/, "\n\n"
    text.strip
    # doc = Nokogiri::HTML text
    # (doc/"//*/text()").map do |text| 
    #   puts text.inner_text
    #   text.inner_text.strip
    # end.select {|text| text.present?}.join " "
  end
end
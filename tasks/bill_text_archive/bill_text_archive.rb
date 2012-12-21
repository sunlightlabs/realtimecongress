require 'nokogiri'

class BillTextArchive

  # Indexes full text of versions of bills into ElasticSearch.
  # 
  # options:
  #   session: which session (e.g. 111, 112) of Congress to load
  #   limit: number of bills to stop at (useful for development)
  #   bill_id: index only a specific bill.
  
  def self.run(options = {})
    session = options[:session] ? options[:session].to_i : Utils.current_session

    bill_count = 0
    version_count = 0

    if options[:bill_id]
      targets = Bill.where bill_id: options[:bill_id]
    else
      # only index unabbreviated bills from the specified session
      targets = Bill.where abbreviated: false, session: session
      
      if options[:limit]
        targets = targets.limit options[:limit].to_i
      end
    end

    warnings = []
    notes = []

    # used to keep batches of indexes
    batcher = []
    
    targets.to_a.each do |bill|
      type = bill.bill_type
      
      # find all the versions of text for that bill
      version_files = Dir.glob("data/gpo/BILLS/#{session}/#{type}/#{type}#{bill.number}-#{session}-[a-z]*.htm")
      
      if version_files.empty?
        # warnings << {message: "Skipping bill, GPO has no version information for it (yet)", bill_id: bill.bill_id}
        next
      end
      
      
      # accumulate an array of version objects
      bill_versions = [] 
      
      
      version_files.each do |file|
        # strip off the version code
        bill_version_id = File.basename file, File.extname(file)
        code = bill_version_id.match(/\-(\w+)$/)[1]
        
        # standard GPO version name
        version_name = Utils.bill_version_name_for code
        
        # metadata from associated GPO MODS file
        # -- MODS file is a constant reasonable size no matter how big the bill is
        
        mods_file = "data/gpo/BILLS/#{session}/#{type}/#{bill_version_id}.mods.xml"
        mods_doc = nil
        if File.exists?(mods_file)
          mods_doc = Nokogiri::XML open(mods_file)
        end
        
        issued_on = nil # will get filled in
        urls = nil # may not...
        if mods_doc
          issued_on = issued_on_for mods_doc

          urls = urls_for mods_doc

          if issued_on.blank?
            warnings << {message: "Had MODS data but no date available for #{bill_version_id}, SKIPPING"}
            next
          end

        else
          puts "[#{bill.bill_id}][#{code}] No MODS data, skipping!" if options[:debug]
          
          # hr81-112-enr is known to trigger this, but that looks like a mistake on GPO's part (HR 81 was never voted on)
          # So if any other bill triggers this, send me a warning so I can check it out.
          if bill_version_id != "hr81-112-enr"
            warnings << {message: "No MODS data available for #{bill_version_id}, SKIPPING"}
          end
          
          # either way, skip over the bill version, it's probably invalid
          next
        end
        
        
        # read in full text
        full_doc = Nokogiri::HTML File.read(file)
        full_text = full_doc.at("pre").text
        full_text = clean_text full_text
        

        # put up top here because it's the first line of debug output for a bill
        puts "[#{bill.bill_id}][#{code}] Processing..." if options[:debug]


        # archive text in MongoDB for use later (this is dumb)
        version_archive = BillVersion.find_or_initialize_by bill_version_id: bill_version_id
        version_archive.attributes = {full_text: full_text}
        version_archive.save!
        
        version_count += 1
        
        bill_versions << {
          version_code: code,
          issued_on: issued_on,
          version_name: version_name,
          bill_version_id: bill_version_id,
          urls: urls,

          # only the last version's text will ultimately be saved in ES
          text: full_text
        }
      end
      
      if bill_versions.size == 0
        warnings << {message: "No versions with a valid date found for bill #{bill.bill_id}, SKIPPING update of the bill entirely in ES and Mongo", bill_id: bill.bill_id}
        next
      end
      
      bill_versions = bill_versions.sort_by {|v| v[:issued_on]}
      
      last_version = bill_versions.last
      last_version_text = last_version[:text].dup
      last_version_on = last_version[:issued_on]

      # don't store the full text (except the last version's text  we preserved, in ES only)
      bill_versions.each {|v| v.delete :text}

      versions_count = bill_versions.size
      bill_version_codes = bill_versions.map {|v| v[:version_code]}
      

      # Update bill in Mongo
      bill.attributes = {
        version_info: bill_versions,
        
        version_codes: bill_version_codes,
        versions_count: versions_count,
        last_version: last_version,
        last_version_on: last_version_on
      }
      bill.save!

      puts "[#{bill.bill_id}] Updated bill with version codes." if options[:debug]


      # Update bill in ES
      puts "[#{bill.bill_id}] Indexing..." if options[:debug]

      # special subset of fields for ES
      bill_fields = Utils.bill_for(bill).merge(
        sponsor: bill['sponsor'],
        summary: bill['summary'],
        keywords: bill['keywords'],
        last_action: bill['last_action']
      )

      Utils.es_batch!('bills', bill.bill_id,
        bill_fields.merge(
          versions: last_version_text,
          updated_at: Time.now,

          version_codes: bill_version_codes,
          versions_count: versions_count,
          last_version: last_version,
          last_version_on: last_version_on
        ),
        batcher, options
      )
      
      puts "[#{bill.bill_id}] Indexed." if options[:debug]
      

      bill_count += 1
    end
    
    # index any leftover docs
    Utils.es_flush! 'bills', batcher

    if warnings.any?
      Report.warning self, "Warnings found while parsing bill text and metadata", warnings: warnings
    end

    if notes.any?
      Report.note self, "Notes found while parsing bill text and metadata", notes: notes
    end
    
    Report.success self, "Loaded in full text of #{bill_count} bills (#{version_count} versions) for session ##{session}."
  end
  
  def self.clean_text(text)
    # weird artifact at end
    text.gsub! '<all>', ''
    
    # remove unneeded whitespace
    text.gsub! "\n", " "
    text.gsub! "\t", " "
    text.gsub! /\s{2,}/, ' '

    # get rid of dumb smart quotes
    text.gsub! '``', '"'
    text.gsub! "''", '"'

    # remove underscore lines
    text.gsub! /_{2,}/, ''

    # de-hyphenate words broken up over multiple lines
    text.gsub!(/(\w)\-\s+(\w)/) {$1 + $2}
    
    text.strip
  end
  
  # expects the bill version's associated MODS XML
  def self.issued_on_for(doc)
    elem = doc.at("dateIssued")
    timestamp = elem ? elem.text : nil
    if timestamp.present?
      Utils.utc_parse(timestamp).strftime "%Y-%m-%d"
    else
      nil
    end
  end
  
  # expects the bill version's XML
  def self.backup_issued_on_for(doc)
    timestamp = doc.xpath("//dc:date", "dc" => "http://purl.org/dc/elements/1.1/").text
    if timestamp.present?
      Utils.utc_parse(timestamp).strftime "%Y-%m-%d"
    else
      nil
    end
  end
  
  # expects the bill version's associated MODS XML
  def self.urls_for(doc)
    urls = {}
    
    (doc / "url").each do |elem|
      label = elem['displayLabel']
      if label =~ /HTML/i
        urls['html'] = elem.text
      elsif label =~ /XML/i
        urls['xml'] = elem.text
      elsif label =~ /PDF/i
        urls['pdf'] = elem.text
      end
    end
    
    urls
  end
end
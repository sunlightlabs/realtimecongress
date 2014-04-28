#!/usr/bin/env ruby

require './config/environment'

set :logging, false

# disable XSS check, this is an API and it's okay to use it with JSONP
disable :protection

# backwards compatibility - 'sections' will still work
before do
  if request.get?
    unless ApiKey.allowed? api_key
      halt 403, 'API key required, you can obtain one from http://services.sunlightlabs.com/accounts/register/'
    end
  end

  if params[:sections].present?
    params[:fields] = params[:sections]
  elsif params[:fields].present?
    params[:sections] = params[:fields]
  end
end

get queryable_route do
  model = params[:captures][0].singularize.camelize.constantize
  format = params[:captures][1]

  fields = Queryable.fields_for model, params
  conditions = Queryable.conditions_for model, params
  order = Queryable.order_for model, params
  pagination = Queryable.pagination_for params

  if params[:explain] == 'true'
    results = Queryable.explain_for model, conditions, fields, order, pagination
  else
    criteria = Queryable.criteria_for model, conditions, fields, order, pagination
    documents = Queryable.documents_for model, criteria, fields
    results = Queryable.results_for model, criteria, documents, pagination
  end

  if format == 'json'
    json results
  elsif format == 'xml'
    xml results
  end
end


helpers do

  def error(status, message)
    format = params[:captures][1]

    results = {
      error: message,
      status: status
    }

    if format == "json"
      halt 200, json(results)
    else
      halt 200, xml(results)
    end
  end

  def json(results)
    response['Content-Type'] = 'application/json'
    json = Oj.dump results, mode: :compat, time_format: :ruby
    if params[:callback].present? and params[:callback] =~ /^[\.a-zA-Z0-9\$_]+$/
      "#{params[:callback]}(#{json});"
    else
      json
    end
  end

  def xml(results)
    xml_exceptions results
    response['Content-Type'] = 'application/xml'
    results.to_xml root: 'results', dasherize: false
  end

  # a hard-coded XML exception for vote names, which I foolishly made as keys
  # this will be fixed in v2
  def xml_exceptions(results)
    if results['votes']
      results['votes'].each do |vote|
        if vote['vote_breakdown']
          vote['vote_breakdown'] = dasherize_hash vote['vote_breakdown']
        end
      end
    end
  end

  def dasherize_hash(original)
    hash = original.dup

    hash.keys.each do |key|
      value = hash.delete key
      key = key.tr(' ', '-')
      if value.is_a?(Hash)
        hash[key] = dasherize_hash(value)
      else
        hash[key] = value
      end
    end

    hash
  end

  def api_key
    params[:apikey] || request.env['HTTP_X_APIKEY']
  end

  def process_query_hash(hash)
    new_hash = {}
    hash.each do |key, value|
      bits = key.split '.'
      break_out new_hash, bits, value
    end
    new_hash
  end

  # helper function to recursively rewrite a hash to break out dot-separated fields into sub-documents
  def break_out(hash, keys, final_value)
    if keys.size > 1
      first = keys.first
      rest = keys[1..-1]

      # default to on
      hash[first] ||= {}

      break_out hash[first], rest, final_value
    else
      hash[keys.first] = final_value
    end
  end

end

after queryable_route do
  query_hash = request.env['rack.request.query_hash']

  # kept separately, don't need reproduced
  query_hash.delete 'sections'
  query_hash.delete 'apikey'

  # don't care about keeping pagination info
  query_hash.delete 'per_page'
  query_hash.delete 'page'

  query_hash = process_query_hash query_hash

  hit = Hit.create!(
    key: api_key,

    method: params[:captures][0],
    format: params[:captures][1],

    query_hash: query_hash,
    sections: (params[:sections] || '').split(','),

    user_agent: request.env['HTTP_USER_AGENT'],
    app_version: request.env['HTTP_X_APP_VERSION'],
    os_version: request.env['HTTP_X_OS_VERSION'],
    app_channel: request.env['HTTP_X_APP_CHANNEL'],

    created_at: Time.now.utc # don't need updated_at
  )

  HitReport.log! Time.zone.now.strftime("%Y-%m-%d"), api_key, params[:captures][0]
end
#!/usr/bin/env ruby

require './config/environment'

require './analytics/api_key'
require './analytics/hits'

set :logging, false

# disable XSS check, this is an API and it's okay to use it with JSONP
disable :protection

# backwards compatibility - 'sections' will still work
before do
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

end
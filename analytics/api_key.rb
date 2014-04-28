require './analytics/sunlight_services'

# Require an API key

before do
  if request.get?
    unless ApiKey.allowed? api_key
      halt 403, 'API key required, you can obtain one from http://services.sunlightlabs.com/accounts/register/'
    end
  end
end


# Accept the API key through the query string or the x-apikey header

def api_key
  params[:apikey] || request.env['HTTP_X_APIKEY']
end
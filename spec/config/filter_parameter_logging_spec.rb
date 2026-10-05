require 'rails_helper'

RSpec.describe 'Request log parameter filtering' do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it 'keeps the text typed into a search box out of the log' do
    filtered = filter.filter('q' => '+7 707 281 70 60', 'search' => 'Иван', 'query' => 'x', 'search_query' => 'y', 'page' => '2')

    expect(filtered).to eq('q' => '[FILTERED]', 'search' => '[FILTERED]', 'query' => '[FILTERED]', 'search_query' => '[FILTERED]', 'page' => '2')
  end

  it 'filters exact keys only, so that unrelated parameters stay readable' do
    params = { 'frequency' => '5', 'request_id' => '1', 'inbox_id' => '3', 'quantity' => '2', 'searching' => 'a', 'country_code' => 'KZ' }

    expect(filter.filter(params)).to eq(params)
  end

  it 'filters the search text nested in a payload' do
    expect(filter.filter('payload' => { 'q' => '8707' })).to eq('payload' => { 'q' => '[FILTERED]' })
  end

  it 'filters the search text in the logged path of a request' do
    request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/api/v1/accounts/1/contacts/search?q=87072817060&page=1'))
    request.set_header('action_dispatch.parameter_filter', Rails.application.config.filter_parameters)

    expect(request.filtered_path).to eq('/api/v1/accounts/1/contacts/search?q=[FILTERED]&page=1')
  end
end

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'session store config' do
  let(:session_options) { Rails.application.config.session_options }

  it 'uses hardened cookie options for dashboard sessions' do
    expect(session_options[:key]).to eq('_chatwoot_session')
    expect(session_options[:same_site]).to eq(:lax)
    expect(session_options[:httponly]).to be(true)
  end
end
# rubocop:enable RSpec/DescribeClass

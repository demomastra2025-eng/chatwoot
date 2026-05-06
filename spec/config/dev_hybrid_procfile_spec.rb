# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'dev hybrid Procfile' do
  let(:procfile) { Rails.root.join('Procfile.dev-hybrid').read }

  it 'starts a dedicated Captain runtime Sidekiq worker' do
    expect(procfile).to include('captain_runtime_worker:')
    expect(procfile).to include('bundle exec sidekiq -C config/sidekiq_captain_runtime.yml')
  end
end
# rubocop:enable RSpec/DescribeClass

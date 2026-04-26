# frozen_string_literal: true

require 'rails_helper'
require 'rack'
require 'rack-mini-profiler'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'rack profiler initializer' do
  around do |example|
    original_disable_mini_profiler = ENV.fetch('DISABLE_MINI_PROFILER', nil)

    ENV.delete('DISABLE_MINI_PROFILER')
    example.run
  ensure
    if original_disable_mini_profiler.nil?
      ENV.delete('DISABLE_MINI_PROFILER')
    else
      ENV['DISABLE_MINI_PROFILER'] = original_disable_mini_profiler
    end
  end

  it 'provides Rack::File compatibility for rack-mini-profiler on Rack 3' do
    hide_const('Rack::File')
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('development'))
    allow(Rack::MiniProfilerRails).to receive(:initialize!)

    load Rails.root.join('config/initializers/rack_profiler.rb')

    expect(Rack.const_defined?(:File, false)).to be(true)
    expect(Rack::File).to eq(Rack::Files)
  end
end
# rubocop:enable RSpec/DescribeClass

require 'spec_helper'
require_relative '../../app/helpers/application_helper'

RSpec.describe ApplicationHelper do
  describe '#onelink_favicon_path' do
    subject(:favicon_path) { helper_object.onelink_favicon_path('favicon.svg') }

    let(:helper_object) do
      request_host = host
      Object.new.extend(described_class).tap do |helper|
        helper.define_singleton_method(:request) { Struct.new(:host).new(request_host) }
      end
    end

    before do
      stub_const('Rails', double(env: double(development?: false)))
    end

    context 'when requested from the DEV domain' do
      let(:host) { 'dev.one-link.kz' }

      it 'returns the isolated DEV favicon' do
        expect(favicon_path).to eq('/dev-favicon.svg?v=onelink-dev-20260828')
      end
    end

    context 'when requested from the production domain' do
      let(:host) { 'app.one-link.kz' }

      it 'keeps the production favicon unchanged' do
        expect(favicon_path).to eq('/favicon.svg?v=onelink-brand')
      end
    end
  end
end

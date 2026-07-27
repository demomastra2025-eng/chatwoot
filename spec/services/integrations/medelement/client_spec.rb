require 'rails_helper'

RSpec.describe Integrations::Medelement::Client do
  subject(:client) { described_class.new(configuration: configuration) }

  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      company_login: 'clinic-login',
      password: 'secret',
      integrator_key: 'integrator-key'
    )
  end

  describe '#get_receptions' do
    it 'treats escaped-unicode 404 empty responses as an empty receptions set' do
      stub_request(:post, "#{described_class::BASE_URL}/v1/timetable/get_receptions")
        .to_return(
          status: 404,
          body: '{"message":"\u041f\u0440\u0438\u0435\u043c\u044b \u043d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d\u044b"}',
          headers: { 'Content-Type' => 'application/json' }
        )

      result = client.get_receptions(
        company_cabinet_code: 'cabinet-1',
        specialist_code: 'specialist-1',
        begin_datetime: '01.04.2026 00:00:00',
        end_datetime: '30.04.2026 23:59:59'
      )

      expect(result).to eq([])
    end
  end
end

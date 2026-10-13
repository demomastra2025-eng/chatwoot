require 'rails_helper'

RSpec.describe 'Native scheduling query error contracts' do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:from) { '2026-10-12T09:00:00+05:00' }
  let(:to) { '2026-10-12T12:00:00+05:00' }

  def error_payload(result)
    JSON.parse(result.delete_prefix('ERROR:').strip).fetch('data')
  end

  {
    Captain::Tools::Copilot::SearchAvailableSlotsService => { resource_ids: [] },
    Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService => {},
    Captain::Tools::Copilot::GetSchedulingResourceScheduleService => {}
  }.each do |tool_class, defaults|
    context tool_class.name do
      let(:tool) { tool_class.new(assistant, user: user) }
      let(:args) { { from: from, to: to }.merge(defaults.presence || { resource_id: resource.id }) }

      it 'rejects an impossible date before provider access with a repairable cause' do
        expect(Integrations::Medelement::Client).not_to receive(:new)
        payload = error_payload(tool.execute(**args.merge(from: '2026-02-30T09:00:00+05:00')))
        expect(payload).to include('code' => 'INVALID_DATE', 'reason' => 'invalid_date')
        expect(payload.dig('details', 'field')).to eq('from')
      end

      it 'distinguishes a reversed or too-long range from an internal failure' do
        expect(Integrations::Medelement::Client).not_to receive(:new)
        # A search for free times may name one exact moment (to == from); the other reads need a range.
        invalid_tos = ['2026-10-12T08:00:00+05:00', '2026-11-14T09:00:00+05:00']
        invalid_tos << from unless defaults.key?(:resource_ids)
        invalid_tos.each do |invalid_to|
          payload = error_payload(tool.execute(**args.merge(to: invalid_to)))
          expect(payload).to include('code' => 'INVALID_DATE_RANGE', 'reason' => 'invalid_date_range', 'error_class' => 'business')
        end
      end

      # The agent runtime ends a run at a technical failure and hands the conversation to staff (Captain::Runtime::ToolFailure). A
      # specialist the model got wrong is an answer it can fix by searching again, so the tool declares it.
      it 'declares a specialist that does not exist a business answer, and the runtime takes it for one' do
        missing = defaults.key?(:resource_ids) ? { resource_ids: [999_999_999] } : { resource_id: 999_999_999 }
        result = tool.execute(**args.merge(missing))

        expect(error_payload(result)).to include('error_class' => 'business')
        expect(Captain::Runtime::ToolFailure.classify(result)).to eq('business')
      end

      it 'declares a malformed date a business answer too' do
        result = tool.execute(**args.merge(from: '2026-02-30T09:00:00+05:00'))

        expect(error_payload(result)).to include('error_class' => 'business')
        expect(Captain::Runtime::ToolFailure.classify(result)).to eq('business')
      end
    end
  end

  [Captain::Tools::Copilot::SearchAvailableSlotsService, Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService].each do |tool_class|
    it "rejects foreign and malformed service IDs through #{tool_class.name} without a provider read" do
      other_service = create(:scheduling_service)
      tool = tool_class.new(assistant, user: user)
      args = { from: from, to: to }.merge(tool_class == Captain::Tools::Copilot::SearchAvailableSlotsService ?
                                        { resource_ids: [resource.id] } : { resource_id: resource.id })
      expect(Integrations::Medelement::Client).not_to receive(:new)

      expect(error_payload(tool.execute(**args.merge(service_id: other_service.id)))).to include(
        'code' => 'UNKNOWN_SERVICE', 'reason' => 'unknown_service'
      )
      expect(error_payload(tool.execute(**args.merge(service_id: 'not-an-id')))).to include(
        'code' => 'INVALID_SERVICE_ID', 'reason' => 'invalid_service_id'
      )
    end
  end

  it 'labels provider unavailability without pretending the requested day is empty' do
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
    expect(Integrations::Medelement::Client).not_to receive(:new)
    result = Captain::Tools::Copilot::SearchAvailableSlotsService.new(assistant, user: user)
                                                              .execute(from: from, to: to, resource_ids: [resource.id])
    payload = JSON.parse(result)

    expect(payload['slots']).to be_empty
    expect(payload['availability']).to include('status' => 'degraded', 'code' => 'PROVIDER_UNAVAILABLE', 'reason' => 'provider_unavailable')
  end

  it 'labels an internal failure without returning exception contents as validation guidance' do
    reader = instance_double(Scheduling::ResourceScheduleService)
    allow(reader).to receive(:perform).and_raise(ArgumentError, 'PRIVATE internal patient data')
    allow(Scheduling::ResourceScheduleService).to receive(:new).and_return(reader)
    result = Captain::Tools::Copilot::GetSchedulingResourceScheduleService.new(assistant, user: user)
                                                                      .execute(resource_id: resource.id, from: from, to: to)

    expect(error_payload(result)).to include('code' => 'INTERNAL_FAILURE', 'reason' => 'internal_failure', 'error_class' => 'technical')
    expect(Captain::Runtime::ToolFailure.classify(result)).to eq('technical')
    expect(result).not_to include('PRIVATE', 'patient data', 'ArgumentError')
  end
end

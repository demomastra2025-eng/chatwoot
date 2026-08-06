require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchAppointmentsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim') }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:appointment1) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, client_name: 'Aruzhan', status: 'scheduled',
                                    payment_status: 'awaiting_payment', conversation: conversation)
  end
  let!(:appointment2) { create(:scheduling_appointment, account: account, client_name: 'Dana', status: 'cancelled', payment_status: 'cancelled') }

  before do
    account.enable_features!('scheduling')
  end

  describe '#execute' do
    it 'returns normalized appointments with filters and total_count' do
      expect(Scheduling::PayloadBuilder).to receive(:appointment).with(
        satisfy do |appointment|
          appointment.association(:conversation).loaded? &&
            appointment.conversation.association(:inbox).loaded? &&
            appointment.conversation.association(:communication_thread).loaded?
        end
      ).and_call_original

      payload = JSON.parse(service.execute(client_name: 'Aruzhan', resource_id: resource.id, limit: 1))

      expect(payload['filters']).to include('client_name' => 'Aruzhan', 'resource_id' => resource.id)
      expect(payload['total_count']).to eq(1)
      expect(payload['appointments'].length).to eq(1)
      expect(payload['appointments'].first).to include(
        'id' => appointment1.id,
        'resource_id' => resource.id,
        'client_name' => 'Aruzhan',
        'status' => 'scheduled'
      )
    end

    it 'rejects unknown contact and specialist ids instead of returning a false empty success' do
      expect(service.execute(contact_id: 2_147_483_647)).to include('Unknown contact_id 2147483647 for this account')
      expect(service.execute(resource_id: 2_147_483_647)).to include('Unknown resource_id 2147483647 for this account')
    end

    it 'returns the newest appointments first and omits unrequested client identity fields' do
      appointment1.update!(
        starts_at: 2.days.ago,
        ends_at: 2.days.ago + 30.minutes,
        client_phone: '+77010000001',
        client_identifier: 'client-old',
        client_birth_date: Date.new(1990, 1, 1),
        client_gender: 'female',
        client_comment: 'Private note'
      )
      appointment2.update!(starts_at: 1.day.ago, ends_at: 1.day.ago + 30.minutes, client_identifier: 'client-new')

      payload = JSON.parse(service.execute(limit: 10))

      expect(payload['appointments'].map { |appointment| appointment['id'] }).to eq([appointment2.id, appointment1.id])
      expect(payload['appointments']).to all(satisfy do |appointment|
        appointment.keys.grep(/^client_/).empty?
      end)
    end
  end
end

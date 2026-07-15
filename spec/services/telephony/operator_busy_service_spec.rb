require 'rails_helper'

RSpec.describe Telephony::OperatorBusyService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:service) { described_class.new(account: account, user: user) }

  describe '#busy?' do
    it 'is false when the operator has no active call' do
      expect(service.busy?).to be(false)
    end

    it 'does not treat an unclaimed inbound routing candidate as busy' do
      create(
        :telephony_call_session,
        account: account,
        direction: 'inbound',
        status: 'ringing',
        metadata: { 'metadata' => { 'chatwoot_user_id' => user.id } }
      )

      expect(service.busy?).to be(false)
    end

    it 'detects an active telephony call claimed through metadata' do
      create(
        :telephony_call_session,
        account: account,
        status: 'in_progress',
        metadata: { 'operator_claim' => { 'user_id' => user.id } }
      )

      expect(service.busy?).to be(true)
      expect(service.busy_details).to include(channel: 'voice')
    end

    it 'detects an active WhatsApp call accepted by the operator' do
      create(:call, account: account, status: 'in_progress', accepted_by_agent_id: user.id, provider: :whatsapp)

      expect(service.busy?).to be(true)
      expect(service.busy_details).to include(channel: 'whatsapp')
    end

    it 'ignores explicitly excluded calls' do
      telephony_call = create(
        :telephony_call_session,
        account: account,
        status: 'in_progress',
        metadata: { 'operator_claim' => { 'user_id' => user.id } }
      )
      whatsapp_call = create(
        :call,
        account: account,
        status: 'in_progress',
        accepted_by_agent_id: user.id,
        provider: :whatsapp
      )

      availability = described_class.new(
        account: account,
        user: user,
        excluding_telephony_call: telephony_call,
        excluding_whatsapp_call: whatsapp_call
      )

      expect(availability.busy?).to be(false)
    end
  end

  describe '#with_lock' do
    it 'raises a controlled conflict before yielding when the operator is busy' do
      create(
        :telephony_call_session,
        account: account,
        direction: 'outbound',
        status: 'connecting',
        metadata: { 'operator_identity' => { 'user_id' => user.id } }
      )
      yielded = false

      expect do
        service.with_lock { yielded = true }
      end.to raise_error(Telephony::Error) { |error|
        expect(error.code).to eq('OPERATOR_BUSY')
        expect(error.status).to eq(:conflict)
      }
      expect(yielded).to be(false)
    end
  end
end

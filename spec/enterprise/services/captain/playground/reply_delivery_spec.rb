require 'rails_helper'

RSpec.describe Captain::Playground::ReplyDelivery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(assistant: assistant, account: account, user: user) }

  after { Current.reset }

  it 'keeps replies in the transcript with both real permissions off or on and never queues delivery' do
    expect(Messages::MessageBuilder).not_to receive(:new)
    session.with_lock do |workspace|
      [false, true].each do |enabled|
        workspace.set_permissions!(read: enabled, write: enabled)
        expect do
          expect(described_class.new(workspace).perform(response: 'Synthetic reply'))
            .to include(enabled: false, status: 'playground_only', delivered: false)
        end.not_to have_enqueued_job(SendReplyJob)
      end
      expect(workspace.conversation).to be_nil
    end
  end

  it 'closes the removed Live opt-in branch even for a stale legacy caller object' do
    legacy = double(live?: true, data: { 'delivery_enabled' => true })
    expect(Messages::MessageBuilder).not_to receive(:new)
    expect(legacy).not_to receive(:conversation)
    expect do
      expect(described_class.new(legacy).perform(response: 'Legacy queued reply'))
        .to include(enabled: false, status: 'playground_only', delivered: false)
    end.not_to have_enqueued_job(SendReplyJob)
  end
end

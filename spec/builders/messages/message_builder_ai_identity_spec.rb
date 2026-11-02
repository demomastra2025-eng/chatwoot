require 'rails_helper'

RSpec.describe Messages::MessageBuilder do
  include_context 'with active AI metering'
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: create(:channel_telegram, account: account).inbox) }
  let(:store) { Captain::ReplySuggestion::RequestStore }
  let(:request) do
    queued = store.create!('account_id' => account.id, 'user_id' => agent.id, 'conversation_id' => conversation.id)
    store.finish!(queued, status: 'draft', result: { 'message' => 'Synthetic generated draft' })
  end

  def send_draft(request_id = request['id'], user: agent, chat: conversation)
    described_class.new(user, chat, { content: 'Fully edited by employee', content_attributes: {
                          copilot: { assisted: true, action: 'reply_suggestion', suggestion_request_id: request_id }
                        } }).perform
  end

  def usage
    Accounts::MonthlyAiUsageService.new(account.reload).ai_dialogs_consumed
  end

  it 'persists generated ownership before publishing the draft and binds an edited send without Redis or feedback' do
    id = request['id']
    allow(store).to receive(:fetch_raw).and_raise(Redis::CannotConnectError, 'injected cache failure')
    message = send_draft(id)
    expect(message.reload.additional_attributes.dig('captain_ai_suggestion', 'request_id')).to eq(id)
    expect(usage).to eq(0)
    message.update!(source_id: 'ack-without-feedback')
    2.times { Accounts::DrainAiUsageJob.perform_now }
    expect(usage).to eq(1)
    expect(Accounts::AiUsageEvent.count).to eq(1)
  end

  [false, 'false', true, 'true'].each do |privacy|
    it "uses the same privacy and metering policy for an attachment with private=#{privacy.inspect}" do
      id = request['id']
      allow(store).to receive(:fetch_raw).and_raise(Redis::CannotConnectError, 'injected cache failure')
      params = ActionController::Parameters.new(
        content: 'Fully edited answer with a file', private: privacy,
        attachments: [Rack::Test::UploadedFile.new(Rails.root.join('spec/assets/sample.png'), 'image/png')],
        content_attributes: { copilot: { assisted: true, action: 'reply_suggestion', suggestion_request_id: id } }.to_json
      )
      message = described_class.new(agent, conversation, params).perform
      message.update!(source_id: 'attachment-provider-ack')
      2.times { Accounts::DrainAiUsageJob.perform_now }

      private_note = [true, 'true'].include?(privacy)
      expect(message.reload.private?).to eq(private_note)
      expect(message.attachments.count).to eq(1)
      expect(message.additional_attributes.dig('captain_ai_suggestion', 'request_id')).to eq(private_note ? nil : id)
      expect(usage).to eq(private_note ? 0 : 1)
      expect(Accounts::AiUsageEvent.where(account_id: account.id).count).to eq(private_note ? 0 : 1)
    end
  end

  it 'counts only the segment carrying the accepted suggestion for a split logical reply' do
    first = send_draft
    first.update!(source_id: 'first-segment-ack')
    6.times do |idx|
      segment = described_class.new(agent, conversation, { content: "Continuation #{idx}" }).perform
      segment.update!(source_id: "segment-#{idx}-ack")
    end
    expect(usage).to eq(1)
    expect(Accounts::AiUsageEvent.count).to eq(1)
    expect(Accounts::AiDialogState.find_by!(contact_id: conversation.contact_id).state['replies_count']).to eq(1)
  end

  it 'keeps an accepted draft used as a private note free without changing normal private-note sending' do
    message = described_class.new(agent, conversation, { content: 'Internal staff note', private: true, content_attributes: {
                                    copilot: { assisted: true, action: 'reply_suggestion', suggestion_request_id: request['id'] }
                                  } }).perform
    expect(message).to be_private
    expect(message.additional_attributes).not_to have_key('captain_ai_suggestion')
    expect(usage).to eq(0)
  end

  it 'rejects invented IDs and genuine requests belonging to a different user or conversation before saving a message' do
    id = request['id']
    stranger = create(:user, account: account)
    other_chat = create(:conversation, account: account)
    before = Message.count
    expect { send_draft('invented-request-id') }.to raise_error(Captain::ReplySuggestion::SentIdentity::OwnershipError)
    expect { send_draft(id, user: stranger) }.to raise_error(Captain::ReplySuggestion::SentIdentity::OwnershipError)
    expect { send_draft(id, chat: other_chat) }.to raise_error(Captain::ReplySuggestion::SentIdentity::OwnershipError)
    expect(Message.count).to eq(before)
    expect(usage).to eq(0)
  end

  it 'rejects a previously owned draft after the employee loses access to the conversation' do
    id = request['id']
    account.account_users.find_by!(user_id: agent.id).destroy!
    expect { send_draft(id) }.to raise_error(Captain::ReplySuggestion::SentIdentity::OwnershipError)
    expect(Accounts::AiUsageEvent.count).to eq(0)
  end

  it 'rejects a generated request from another account even for the same employee' do
    id = request['id']
    foreign = create(:conversation)
    expect { send_draft(id, chat: foreign) }.to raise_error(Captain::ReplySuggestion::SentIdentity::OwnershipError)
    expect(Accounts::AiUsageEvent.count).to eq(0)
  end

  it 'retains financial proof when optional feedback hits a Redis failure' do
    id = request['id']
    message = create(:message, account: account, conversation: conversation, sender: agent, message_type: :outgoing, source_id: 'acked-edited-draft')
    allow(store).to receive(:fetch_raw).with(id).and_raise(Redis::CannotConnectError, 'injected Redis unavailable')
    expect do
      Captain::ReplySuggestion::FeedbackService.new(
        account: account, user: agent, conversation: conversation, outcome: 'sent', copilot_action: 'reply_suggestion',
        requested_display_id: conversation.display_id, suggestion_request_id: id, message_id: message.id, edited_before_send: true
      ).perform
    end.to raise_error(Redis::CannotConnectError)
    2.times { Accounts::DrainAiUsageJob.perform_now }
    expect(message.reload.additional_attributes).to have_key('captain_ai_suggestion')
    expect(usage).to eq(1)
  end

  it 'does not attach financial provenance to a feedback request with an invented identity' do
    message = create(:message, account: account, conversation: conversation, sender: agent, message_type: :outgoing, source_id: 'ordinary-reply-ack')
    expect do
      Captain::ReplySuggestion::FeedbackService.new(
        account: account, user: agent, conversation: conversation, outcome: 'sent', copilot_action: 'reply_suggestion',
        requested_display_id: conversation.display_id, suggestion_request_id: 'invented-request-id', message_id: message.id
      ).perform
    end.to raise_error(Captain::ReplySuggestion::FeedbackService::NotFoundError)
    expect(message.reload.additional_attributes).not_to have_key('captain_ai_suggestion')
    expect(usage).to eq(0)
  end
end

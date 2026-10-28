require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::FeedbackService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: create(:inbox, account: account)) }
  let(:store) { Captain::ReplySuggestion::RequestStore }
  let(:suggestion_text) { 'Здравствуйте! Ближайшее окно к ЛОР-врачу завтра в 10:00.' }
  let(:record) do
    created = store.create!(
      'account_id' => account.id, 'user_id' => agent.id, 'conversation_id' => conversation.id, 'conversation_display_id' => conversation.display_id,
      'engine' => 'agent', 'assistant_id' => 1, 'based_on_message_id' => 77
    )
    store.finish!(created, status: 'draft', result: { 'message' => suggestion_text })
  end

  before { Llm::EventSubscriber.install! }

  def perform(outcome, options = {})
    described_class.new(
      account: account, user: agent, conversation: conversation, outcome: outcome, copilot_action: 'reply_suggestion',
      requested_display_id: conversation.display_id, suggestion_request_id: record['id'], **options
    ).perform
  end

  def event(status)
    LlmEvent.where(event_name: 'llm.copilot.feedback', status: status).sole
  end

  describe 'generated, applied, sent, dismissed: what the manager did with the suggestion' do
    it 'records applied with the preview of the inserted text' do
      perform('applied', generated_text: suggestion_text)

      expect(event('applied').request_id).to eq(record['id'])
      expect(event('applied').payload).to include('generated_reply_preview' => suggestion_text, 'engine' => 'agent', 'based_on_message_id' => 77)
    end

    it 'records sent with the text that was sent and the original text of the suggestion, both in full' do
      sent_text = 'Добрый день! Окно завтра в 10:30.'
      sent = create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: agent, content: sent_text)

      perform('sent', generated_text: suggestion_text, final_text: 'старый текст клиента', message_id: sent.id, edited_before_send: true)

      expect(event('sent').payload).to include(
        'suggestion_text' => suggestion_text, 'final_text' => sent_text, 'message_id' => sent.id, 'edited_before_send' => true
      )
      expect(event('sent').payload).not_to include('suggestion_text_truncated', 'final_text_truncated')
    end

    it 'falls back to the text the dashboard reports when the message cannot be found, and to the draft for the text of the suggestion' do
      perform('sent', final_text: 'Текст с клиента', message_id: 999_999)

      expect(event('sent').payload).to include('suggestion_text' => suggestion_text, 'final_text' => 'Текст с клиента')
    end

    it 'keeps the first draft too when the text worked with is a refinement of it' do
      perform('sent', generated_text: 'Короче: окно завтра в 10:00.', final_text: 'Окно завтра в 10:00.', follow_up_count: 1)

      expect(event('sent').payload).to include('suggestion_text' => 'Короче: окно завтра в 10:00.', 'initial_suggestion_text' => suggestion_text)
    end

    it 'records dismissed with the text of the suggestion, and arms the follow-up of the next message' do
      perform('dismissed')

      expect(event('dismissed').payload).to include('suggestion_text' => suggestion_text)
      expect(Redis::Alfred.get("#{store::PREFIX}:dismissed:#{account.id}:#{agent.id}:#{conversation.id}")).to include(record['id'])
    end

    it 'records the notice that was closed, with its reason' do
      created = store.create!(record.slice('account_id', 'user_id', 'conversation_id'))
      notice = store.finish!(created, status: 'human_needed', result: { 'reason' => 'Решает врач.' })

      described_class.new(
        account: account, user: agent, conversation: conversation, outcome: 'notice_dismissed', copilot_action: 'reply_suggestion',
        requested_display_id: conversation.display_id, suggestion_request_id: notice['id']
      ).perform

      expect(event('notice_dismissed').payload).to include('reason_preview' => 'Решает врач.')
      expect(Redis::Alfred.get("#{store::PREFIX}:dismissed:#{account.id}:#{agent.id}:#{conversation.id}")).to include(notice['id'])
    end

    it 'links the sent message immediately when the manager replies while the notice is still open' do
      created = store.create!(record.slice('account_id', 'user_id', 'conversation_id'))
      notice = store.finish!(created, status: 'human_needed', result: { 'reason' => 'Решает врач.' })
      sent = create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: agent, content: 'Ответила сама')

      described_class.new(
        account: account, user: agent, conversation: conversation, outcome: 'notice_dismissed', copilot_action: 'reply_suggestion',
        requested_display_id: conversation.display_id, suggestion_request_id: notice['id'], message_id: sent.id, final_text: sent.content
      ).perform

      expect(event('notice_dismissed').payload).to include(
        'reason_preview' => 'Решает врач.', 'next_message_id' => sent.id, 'next_message_delay_seconds' => 0, 'final_text' => 'Ответила сама'
      )
      expect(Redis::Alfred.get("#{store::PREFIX}:dismissed:#{account.id}:#{agent.id}:#{conversation.id}")).to be_nil
    end
  end

  describe 'what the suggestion becomes' do
    it 'is never offered again after it was inserted, dismissed or closed' do
      %w[applied dismissed notice_dismissed].each do |outcome|
        fresh = store.create!(record.slice('account_id', 'user_id', 'conversation_id'))
        described_class.new(
          account: account, user: agent, conversation: conversation, outcome: outcome, copilot_action: 'reply_suggestion',
          requested_display_id: conversation.display_id, suggestion_request_id: fresh['id']
        ).perform

        expect(store.consumed?(fresh['id'])).to be(true)
      end
    end

    it 'is not consumed by a sent message: it was already consumed when it was inserted' do
      perform('sent', final_text: 'Текст')

      expect(store.consumed?(record['id'])).to be(false)
    end
  end

  describe 'the sticky agent and the approval cards of the suggestion' do
    let(:record) do
      created = store.create!(
        'account_id' => account.id, 'user_id' => agent.id, 'conversation_id' => conversation.id,
        'conversation_display_id' => conversation.display_id, 'engine' => 'agent', 'assistant_id' => 1
      )
      store.finish!(created, status: 'draft', result: { 'message' => suggestion_text, 'agent' => { 'id' => 119, 'name' => 'Процедуры' } })
    end

    let(:sticky) { Captain::ReplySuggestion::StickyAgent }
    let(:approvals) { Captain::ReplySuggestion::ActionApprovalService }
    let(:card) { { 'account_id' => account.id, 'conversation_id' => conversation.id, 'status' => 'pending', 'tool_name' => 'create_appointment' } }

    after { sticky.clear!(conversation) }

    it 'confirms the agent of an inserted or sent draft as the sticky agent of the dialog for 24 hours' do
      perform('applied', generated_text: suggestion_text)
      expect(sticky.read(conversation)).to eq(119)
      key = sticky.keys_for(conversation, kinds: %w[confirmed]).first
      expect($alfred.with { |connection| connection.ttl(key) }).to be_within(5).of(24.hours.to_i) # rubocop:disable Style/GlobalVars

      sticky.confirm!(conversation, 84, request_id: 'other-request')
      perform('sent', final_text: suggestion_text)
      expect(sticky.read(conversation)).to eq(119)
    end

    it 'withdraws the agent of a dismissed draft (the agent before it leads again) and discards the cards of that suggestion only' do
      sticky.confirm!(conversation, 84, request_id: 'earlier-request')
      sticky.remember_provisional!(conversation, 119, request_id: record['id'])
      expect(sticky.read(conversation)).to eq(119)
      approvals.store_record!(card.merge('action_id' => 'own-card', 'digest' => 'd-1', 'suggestion_request_id' => record['id']))
      approvals.store_record!(card.merge('action_id' => 'other-card', 'digest' => 'd-2', 'suggestion_request_id' => 'other-request'))

      perform('dismissed')

      expect(sticky.read(conversation)).to eq(84)
      expect(approvals.fetch_record('own-card')).to include('status' => 'rejected', 'rejected_reason' => 'suggestion_dismissed')
      expect(approvals.fetch_record('other-card')).to include('status' => 'pending')
    end

    it 'keeps the approval cards of an inserted draft: the next suggestion neither discards them nor hides them' do
      approvals.store_record!(card.merge('action_id' => 'booking-card', 'digest' => 'd-3', 'suggestion_request_id' => record['id'],
                                         'user_id' => agent.id))

      perform('applied', generated_text: suggestion_text)
      approvals.discard_superseded!(account_id: account.id, conversation_id: conversation.id, user_id: agent.id, keep_request_id: 'next')

      expect(approvals.fetch_record('booking-card')).to include('status' => 'pending', 'kept_at' => be_present)
      expect(approvals.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: 'next').pluck('action_id'))
        .to eq(['booking-card'])
    end

    it 'makes nobody sticky for a draft of the anchor that answered only because no agent led the dialog' do
      routing = { 'decision_key' => 'route_agent_84', 'default_to' => 'anchor' }
      store.finish!(store.fetch_raw(record['id']), status: 'draft',
                                                   result: { 'message' => suggestion_text, 'agent' => { 'id' => 84 },
                                                             'suggestion_meta' => { 'routing' => routing } })

      perform('applied', generated_text: suggestion_text)

      expect(sticky.read(conversation)).to be_nil
    end
  end

  describe 'long texts' do
    let(:long_text) { 'Здравствуйте! ' * 200 }

    it 'cuts each text to the size that fits an llm event, says so, and the event keeps both texts' do
      perform('sent', generated_text: long_text, final_text: long_text)

      limit = Captain::CopilotFeedbackRecorder::FULL_TEXT_LIMIT
      expect(event('sent').payload).to include('suggestion_text_truncated' => true, 'final_text_truncated' => true)
      expect(event('sent').payload['suggestion_text'].length).to eq(limit)
      expect(event('sent')).to have_attributes(payload_truncated: false)
    end
  end

  describe 'the request has to be the manager\'s own' do
    it 'refuses a request that does not exist, that is another manager\'s, and that is in another conversation' do
      other = create(:user, account: account, role: :agent)
      theirs = store.create!('account_id' => account.id, 'user_id' => other.id, 'conversation_id' => conversation.id)
      elsewhere = store.create!('account_id' => account.id, 'user_id' => agent.id, 'conversation_id' => create(:conversation, account: account).id)

      ['nope', theirs['id'], elsewhere['id']].each do |id|
        expect { perform('applied', suggestion_request_id: id) }.to raise_error(described_class::NotFoundError)
      end
      expect(LlmEvent.where(event_name: 'llm.copilot.feedback')).to be_empty
    end

    it 'refuses a request of another account' do
      foreign = store.create!('account_id' => create(:account).id, 'user_id' => agent.id, 'conversation_id' => conversation.id)

      expect { perform('applied', suggestion_request_id: foreign['id']) }.to raise_error(described_class::NotFoundError)
    end
  end

  describe 'a request that expired while the manager edited the draft' do
    it 'still records what was sent, with the texts the dashboard reports' do
      perform('sent', suggestion_request_id: SecureRandom.uuid, generated_text: 'Текст подсказки', final_text: 'Отправленный текст')

      expect(event('sent').payload).to include('suggestion_text' => 'Текст подсказки', 'final_text' => 'Отправленный текст')
    end

    it 'does not record the other outcomes: there is nothing to act on any more' do
      expect { perform('dismissed', suggestion_request_id: SecureRandom.uuid) }.to raise_error(described_class::NotFoundError)
    end
  end

  describe 'without a request (older callers)' do
    it 'still records the feedback' do
      described_class.new(
        account: account, user: agent, conversation: conversation, outcome: 'sent', copilot_action: 'reply_suggestion',
        requested_display_id: conversation.display_id, request_id: 'legacy-1', generated_text: 'A', final_text: 'B'
      ).perform

      expect(event('sent')).to have_attributes(request_id: 'legacy-1')
      expect(event('sent').payload).to include('suggestion_text' => 'A', 'final_text' => 'B')
    end
  end
end

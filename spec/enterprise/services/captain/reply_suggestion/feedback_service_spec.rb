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

  describe 'the sticky agent of the suggestion' do
    let(:record) do
      created = store.create!(
        'account_id' => account.id, 'user_id' => agent.id, 'conversation_id' => conversation.id,
        'conversation_display_id' => conversation.display_id, 'engine' => 'agent', 'assistant_id' => 1
      )
      store.finish!(created, status: 'draft', result: { 'message' => suggestion_text, 'agent' => { 'id' => 119, 'name' => 'Процедуры' } })
    end

    after { Captain::ReplySuggestion::StickyAgent.keys_for(conversation).each { |key| Redis::Alfred.delete(key) } }

    it 'makes the agent of an inserted or sent draft the sticky agent of the dialog' do
      perform('applied', generated_text: suggestion_text)
      expect(Captain::ReplySuggestion::StickyAgent.read(conversation)).to eq(119)

      Captain::ReplySuggestion::StickyAgent.remember!(conversation, 84)
      perform('sent', final_text: suggestion_text)
      expect(Captain::ReplySuggestion::StickyAgent.read(conversation)).to eq(119)
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

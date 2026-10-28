require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::DismissalTracker do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: create(:inbox, account: account)) }
  let(:suggestion_id) { SecureRandom.uuid }

  before { Llm::EventSubscriber.install! }

  def record_dismissal(id = suggestion_id, **overrides)
    Captain::CopilotFeedbackRecorder.record!(
      account: account, user: agent, conversation: conversation, requested_display_id: conversation.display_id, outcome: 'dismissed',
      copilot_action: 'reply_suggestion', request_id: id, suggestion_request_id: id, generated_text: 'Текст подсказки',
      keep_full_text: true, **overrides
    )
  end

  def arm(id = suggestion_id, at: Time.current, user: agent)
    described_class.arm!(account_id: account.id, user_id: user.id, conversation_id: conversation.id, suggestion_request_id: id, now: at)
  end

  def manager_message(user: agent, **attributes)
    create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: user, content: 'Мой ответ', **attributes)
  end

  def dismissed_event(id = suggestion_id)
    LlmEvent.where(event_name: 'llm.copilot.feedback', request_id: id, status: 'dismissed').sole
  end

  describe 'the next message of the manager' do
    before do
      record_dismissal
      arm
    end

    it 'is recorded on the dismissed event with how long after the dismissal it came' do
      message = manager_message

      expect(described_class.message_created(message)).to eq(1)

      expect(dismissed_event.payload).to include('next_message_id' => message.id)
      expect(dismissed_event.payload['next_message_delay_seconds']).to be_between(0, 5)
      expect(dismissed_event.payload).to include('suggestion_text' => 'Текст подсказки')
    end

    it 'is only the first message: a later one does not rewrite it' do
      first = manager_message
      described_class.message_created(first)

      expect(described_class.message_created(manager_message)).to eq(0)
      expect(dismissed_event.payload['next_message_id']).to eq(first.id)
    end

    it 'is not a message of someone else, a customer message, a private note or a bot message' do
      other = create(:user, account: account, role: :agent)
      customer = create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'Спасибо')
      note = manager_message(private: true)
      assistant = create(:captain_assistant, account: account)
      bot = create(:message, conversation: conversation, account: account, message_type: :outgoing, sender: assistant)

      counts = [manager_message(user: other), customer, note, bot].map { |message| described_class.message_created(message) }

      expect(counts).to eq([0, 0, 0, 0])
      expect(dismissed_event.payload).not_to have_key('next_message_id')
    end

    it 'is not a message in another conversation' do
      elsewhere = create(:conversation, account: account, inbox: conversation.inbox)
      message = create(:message, conversation: elsewhere, account: account, message_type: :outgoing, sender: agent, content: 'Другой диалог')

      expect(described_class.message_created(message)).to eq(0)
    end
  end

  describe 'the window of 30 minutes' do
    it 'does not count a message that came later than that' do
      record_dismissal
      arm(at: 31.minutes.ago)

      expect(described_class.message_created(manager_message)).to eq(0)
      expect(dismissed_event.payload).not_to have_key('next_message_id')
    end

    it 'counts a message that came just inside it' do
      record_dismissal
      arm(at: 29.minutes.ago)

      expect(described_class.message_created(manager_message)).to eq(1)
    end

    it 'forgets the dismissal after the window' do
      allow(Redis::Alfred).to receive(:set).and_call_original

      arm

      expect(Redis::Alfred).to have_received(:set).with(/:dismissed:/, anything, ex: Captain::ReplySuggestion::DISMISSAL_WINDOW_SECONDS)
    end
  end

  describe 'several suggestions dismissed before the manager wrote' do
    it 'records the message on each of them' do
      second_id = SecureRandom.uuid
      record_dismissal
      record_dismissal(second_id)
      arm
      arm(second_id)

      message = manager_message

      expect(described_class.message_created(message)).to eq(2)
      expect(dismissed_event.payload['next_message_id']).to eq(message.id)
      expect(dismissed_event(second_id).payload['next_message_id']).to eq(message.id)
    end
  end

  describe 'notice_dismissed and cancelled events' do
    %w[notice_dismissed cancelled].each do |status|
      it "records the next message of the manager on a #{status} event too" do
        record_dismissal(suggestion_id, outcome: status)
        arm(suggestion_id)

        message = manager_message

        expect(described_class.message_created(message)).to eq(1)
        recorded = LlmEvent.where(event_name: 'llm.copilot.feedback', request_id: suggestion_id, status: status).sole
        expect(recorded.payload).to include('next_message_id' => message.id)
      end
    end
  end

  it 'costs nothing for a message when nothing was dismissed' do
    expect(described_class.message_created(manager_message)).to eq(0)
  end

  it 'skips a dismissal whose event was not recorded' do
    arm('no-such-event')

    expect(described_class.message_created(manager_message)).to eq(0)
  end

  describe 'the listener' do
    it 'is called for a created message and records it' do
      record_dismissal
      arm
      message = manager_message

      CaptainListener.instance.message_created(Events::Base.new('message.created', Time.zone.now, message: message))

      expect(dismissed_event.payload['next_message_id']).to eq(message.id)
    end

    it 'never fails the dispatch of a message' do
      allow(described_class).to receive(:message_created).and_raise(Redis::CannotConnectError)

      expect do
        CaptainListener.instance.message_created(Events::Base.new('message.created', Time.zone.now, message: manager_message))
      end.not_to raise_error
    end
  end
end

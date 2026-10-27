require 'rails_helper'

RSpec.describe Captain::AiActor do
  include ActiveJob::TestHelper

  it 'is the AI as a whole: it names the AI and no agent' do
    actor = described_class.instance

    expect(actor.name).to eq('AI')
    expect(actor.push_event_data).to eq(id: 0, name: 'AI', type: 'captain_assistant')
    expect(actor.webhook_data).to eq(actor.push_event_data)
  end

  it 'travels through ActiveJob as a reference and comes back as the same actor, as the typing events need' do
    serialized = ActiveJob::Arguments.serialize([{ user: described_class.instance, is_private: true }])
    restored = ActiveJob::Arguments.deserialize(serialized).first

    expect(restored[:user]).to equal(described_class.instance)
    expect(restored[:is_private]).to be(true)
  end

  it 'lets the typing indicator queue its event without a record behind the actor' do
    conversation = create(:conversation)

    expect { Captain::Conversation::TypingIndicatorService.turn_on(conversation: conversation) }
      .to have_enqueued_job(EventDispatcherJob).with('conversation.typing_on', anything, hash_including(conversation: conversation))
    expect { Captain::Conversation::TypingIndicatorService.turn_off(conversation: conversation) }
      .to have_enqueued_job(EventDispatcherJob).with('conversation.typing_off', anything, hash_including(conversation: conversation))
  end

  it 'is accepted by the dashboard typing broadcast, which shows «AI»' do
    conversation = create(:conversation)
    event = Events::Base.new('conversation.typing_on', Time.zone.now, conversation: conversation, user: described_class.instance, is_private: true)
    allow(ActionCableBroadcastJob).to receive(:perform_later)

    expect { ActionCableListener.instance.conversation_typing_on(event) }.not_to raise_error
  end
end

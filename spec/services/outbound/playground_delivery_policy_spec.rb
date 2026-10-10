require 'rails_helper'

RSpec.describe Outbound::PlaygroundDeliveryPolicy do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:attributes) do
    { mode: 'live', run_id: SecureRandom.uuid, session_id: SecureRandom.uuid, account_id: account.id,
      user_id: user.id, assistant_id: 1, caller_contact_id: contact.id, conversation_id: conversation.id,
      inbox_id: inbox.id, delivery_enabled: false, delivery_target: nil }
  end
  let(:policy) { described_class.issue(attributes) }

  after { Current.reset }

  it 'blocks disabled, invalid, expired, and cross-account policies' do
    expect { described_class.ensure!(conversation: conversation, policy: policy) }.to raise_error(described_class::Blocked)
    expect { described_class.ensure!(conversation: conversation, policy: { 'token' => 'forged' }) }.to raise_error(described_class::Blocked)
    travel 25.hours do
      expect { described_class.ensure!(conversation: conversation, policy: policy) }.to raise_error(described_class::Blocked)
    end
    other = create(:conversation)
    expect { described_class.ensure!(conversation: other, policy: described_class.issue(attributes.merge(delivery_enabled: true))) }
      .to raise_error(described_class::Blocked)
  end

  it 'stops outgoing creation at MessageBuilder without bypass via skip_delivery_policy' do
    described_class.with(policy) do
      expect do
        Messages::MessageBuilder.new(user, conversation, { content: 'Blocked' }, skip_delivery_policy: true).perform
      end.to raise_error(described_class::Blocked)
      expect(Message.where(conversation: conversation, content: 'Blocked')).not_to exist
    end
  end

  it 'persists a failed delivery state for direct outgoing records and prevents a later SendReplyJob dispatch' do
    message = nil
    described_class.with(policy) do
      expect { message = create(:message, message_type: :outgoing, conversation: conversation, account: account, inbox: inbox) }
        .not_to have_enqueued_job(SendReplyJob)
    end
    expect(message.reload).to be_failed
    expect(message.additional_attributes[described_class::ATTRIBUTE_KEY]).to eq(policy)
    expect(Messages::SendEmailNotificationService).not_to receive(:new)
    expect(SendReplyJob.perform_now(message.id)).to be(false)
    expect(message.reload.external_error).to eq(described_class::BLOCKED_MESSAGE)
  end

  it 'retains policy across serialized jobs, restores it for descendants, and does not leak into an ordinary job' do
    job = SendReplyJob.new(123)
    described_class.with(policy) { job.send(:capture_playground_run_policy) }
    restored = ActiveJob::Base.deserialize(job.serialize)
    expect(restored.serialize['captain_playground']).to eq(policy)
    restored.send(:restore_playground_run_policy) do
      expect(Current.playground_run_policy).to eq(policy)
      child = EventDispatcherJob.new('event', Time.current, {})
      child.send(:capture_playground_run_policy)
      expect(child.serialize['captain_playground']).to eq(policy)
    end
    expect(Current.playground_run_policy).to be_nil
    expect(SendReplyJob.new(124).serialize).not_to have_key('captain_playground')
  end

  it 'keeps invalid async policy as a blocking policy instead of dropping it' do
    job = SendReplyJob.new(123)
    payload = job.serialize.merge('captain_playground' => { 'token' => 'invalid' })
    restored = ActiveJob::Base.deserialize(payload)
    restored.send(:restore_playground_run_policy) do
      expect { Messages::MessageBuilder.new(user, conversation, { content: 'No delivery' }).perform }.to raise_error(described_class::Blocked)
    end
  end

  it 'keeps missing, null, and false persisted test policies blocking' do
    marker = attributes.slice(:session_id, :account_id, :user_id, :assistant_id).stringify_keys
    conversation.update!(additional_attributes: { 'captain_playground_source' => marker })
    [nil, false, {}].each do |invalid|
      conversation.update!(additional_attributes: { 'captain_playground_source' => marker, described_class::ATTRIBUTE_KEY => invalid })
      expect { described_class.ensure!(conversation: conversation) }.to raise_error(described_class::Blocked)
    end
    conversation.update!(additional_attributes: { 'captain_playground_source' => marker })
    expect { described_class.ensure!(conversation: conversation) }.to raise_error(described_class::Blocked)
    restored = ActiveJob::Base.deserialize(SendReplyJob.new(123).serialize.merge('captain_playground' => nil))
    restored.send(:restore_playground_run_policy) { expect(Current.playground_run_policy).to eq({}) }
  end

  it 'preserves ordinary deliveries when there is no Playground policy' do
    expect { described_class.ensure!(conversation: conversation) }.not_to raise_error
    expect { Messages::MessageBuilder.new(user, conversation, { content: 'Ordinary' }).perform }.to change(Message, :count).by(1)
  end

  it 'keeps a reminder created by a Live run blocked after its appointment policy is cleared' do
    reminder = nil
    described_class.with(policy) do
      reminder = create(:reminder, account: account, conversation: conversation, target_conversation: conversation,
                                   target_contact: contact, target_inbox: inbox, status: :processing)
    end
    expect(reminder.reload.metadata[described_class::ATTRIBUTE_KEY]).to eq(policy)
    expect(Reminders::ConversationResolver).not_to receive(:new)
    Reminders::ExecuteService.new(reminder: reminder).perform
    expect(reminder.reload).to be_failed
    expect(reminder.last_error).to eq(described_class::BLOCKED_MESSAGE)
  end

  it 'blocks a direct channel service and CSAT before a provider call' do
    sms_channel = create(:channel_sms, account: account)
    sms_conversation = create(:conversation, account: account, inbox: sms_channel.inbox)
    message = create(:message, message_type: :outgoing, account: account, inbox: sms_channel.inbox, conversation: sms_conversation)
    expect(HTTParty).not_to receive(:post)
    described_class.with(policy) do
      expect(Sms::SendOnSmsService.new(message: message).perform).to be(false)
      survey = CsatSurveyService.new(conversation: sms_conversation)
      allow(survey).to receive(:should_send_csat_survey?).and_return(true)
      expect(survey).not_to receive(:template_available_and_approved?)
      expect(survey.perform).to be(false)
    end
    expect(message.reload).to be_failed
  end

  it 'suppresses staff delivery for a serialized run regardless of a phone opt-in' do
    notification = create(:notification, account: account, user: user, primary_actor: conversation)
    described_class.with(policy) do
      expect(TelegramNotification::BotClient).not_to receive(:send_message)
      expect(WebPush).not_to receive(:payload_send)
      expect(AgentNotifications::ConversationNotificationsMailer).not_to receive(:with)
      Notification::TelegramNotificationService.new(notification: notification).perform
      Notification::PushNotificationService.new(notification: notification).perform
      Notification::EmailNotificationService.new(notification: notification).perform
    end
  end

  it 'suppresses direct staff mail even if the mailer resets its current account context' do
    described_class.with(policy) do
      expect do
        AgentNotifications::ConversationNotificationsMailer.with(account: account).conversation_assignment(conversation, user, nil).deliver_now
      end.not_to change(ActionMailer::Base.deliveries, :size)
      expect(Current.playground_run_policy).to eq(policy)
    end
  end

  context 'with an opted-in controlled phone source' do
    let(:inbox) { create(:channel_sms, account: account).inbox }
    let(:contact) { create(:contact, account: account, phone_number: '+77015551234') }
    let(:attributes) { super().merge(delivery_enabled: true, delivery_target: contact.phone_number) }

    before do
      marker = attributes.slice(:session_id, :account_id, :user_id, :assistant_id).stringify_keys
      contact.update!(additional_attributes: { 'captain_playground_source' => marker })
      conversation.contact_inbox.update!(source_id: contact.phone_number)
      conversation.update!(additional_attributes: { 'captain_playground_source' => marker, described_class::ATTRIBUTE_KEY => policy })
    end

    it 'permits only the exact account, inbox, dedicated conversation, caller, and test number' do
      expect { described_class.ensure!(conversation: conversation, policy: policy) }.not_to raise_error
      other = create(:conversation, account: account, inbox: inbox)
      expect { described_class.ensure!(conversation: other, policy: policy) }.to raise_error(described_class::Blocked)
      contact.update!(phone_number: '+77015559876')
      expect { described_class.ensure!(conversation: conversation, policy: policy) }.to raise_error(described_class::Blocked)
    end

    it 'revalidates administrator permission and rejects invalid job policy despite a valid record policy' do
      described_class.with('token' => 'invalid') do
        expect { described_class.ensure!(conversation: conversation, policy: policy) }.to raise_error(described_class::Blocked)
      end
      account.account_users.find_by!(user_id: user.id).update!(role: :agent)
      expect { described_class.ensure!(conversation: conversation, policy: policy) }.to raise_error(described_class::Blocked)
    end

    it 'queues the native caller reply without claiming that it has been delivered' do
      described_class.with(policy) do
        expect do
          Messages::MessageBuilder.new(user, conversation, { content: 'Controlled test reply' }).perform
        end.to have_enqueued_job(SendReplyJob)
      end
      message = conversation.messages.find_by!(content: 'Controlled test reply')
      expect(message.additional_attributes[described_class::ATTRIBUTE_KEY]).to eq(policy)
      expect(message).not_to be_failed
    end

    it 'keeps invalid inherited job context blocked despite an opted-in reminder stamp' do
      reminder = nil
      described_class.with(policy) do
        reminder = create(:reminder, account: account, conversation: conversation, target_conversation: conversation,
                                     target_contact: contact, target_inbox: inbox, status: :processing)
      end
      expect(Reminders::ConversationResolver).not_to receive(:new)
      inherited = { 'token' => 'invalid' }

      described_class.with(inherited) do
        Reminders::ExecuteReminderJob.perform_now(reminder.id)
        expect(Current.playground_run_policy).to eq(inherited)
      end

      expect(reminder.reload).to be_failed
      expect(reminder.last_error).to eq(described_class::BLOCKED_MESSAGE)
    end
  end
end

require 'rails_helper'

describe Notification::EmailNotificationService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, confirmed_at: Time.current) }
  let(:conversation) { create(:conversation, account: account) }
  let(:notification) do
    create(
      :notification,
      notification_type: :conversation_creation,
      user: agent,
      account: account,
      primary_actor: conversation
    )
  end
  let(:mailer) { double }
  let(:mailer_action) { double }

  before do
    notification_setting = agent.notification_settings.find_by(account_id: account.id)
    notification_setting.selected_email_flags = [:email_conversation_creation]
    notification_setting.save!
  end

  describe '#perform' do
    context 'when notification is read' do
      before do
        notification.update!(read_at: Time.current)
      end

      it 'does not send email' do
        expect(AgentNotifications::ConversationNotificationsMailer).not_to receive(:with)
        described_class.new(notification: notification).perform
      end
    end

    context 'when agent is not confirmed' do
      before do
        agent.update!(confirmed_at: nil)
      end

      it 'does not send email' do
        expect(AgentNotifications::ConversationNotificationsMailer).not_to receive(:with)
        described_class.new(notification: notification).perform
      end
    end

    context 'when agent is confirmed' do
      before do
        allow(AgentNotifications::ConversationNotificationsMailer).to receive(:with).and_return(mailer)
        allow(mailer).to receive(:public_send).and_return(mailer_action)
        allow(mailer_action).to receive(:deliver_later)
      end

      it 'sends email' do
        described_class.new(notification: notification).perform
        expect(mailer).to have_received(:public_send).with(
          'conversation_creation',
          conversation,
          agent,
          nil
        )
      end
    end

    context 'when user is not subscribed to notification type' do
      before do
        notification_setting = agent.notification_settings.find_by(account_id: account.id)
        notification_setting.selected_email_flags = []
        notification_setting.save!
      end

      it 'does not send email' do
        expect(AgentNotifications::ConversationNotificationsMailer).not_to receive(:with)
        described_class.new(notification: notification).perform
      end
    end

    context 'when the notification is generated from imported history' do
      let!(:imported_message) do
        create(
          :message,
          conversation: conversation,
          inbox: conversation.inbox,
          account: account,
          content_attributes: { imported_history: true }
        )
      end
      let(:notification) do
        create(
          :notification,
          notification_type: :conversation_assignment,
          user: agent,
          account: account,
          primary_actor: conversation
        )
      end

      before do
        notification_setting = agent.notification_settings.find_by(account_id: account.id)
        notification_setting.selected_email_flags = [:email_conversation_assignment]
        notification_setting.save!
      end

      it 'does not send email' do
        expect(AgentNotifications::ConversationNotificationsMailer).not_to receive(:with)
        described_class.new(notification: notification).perform
      end
    end
  end

  describe '#imported_history_notification?' do
    subject(:imported_history_notification?) { described_class.new(notification: notification).send(:imported_history_notification?) }

    context 'when the notification secondary actor is an imported history message' do
      let(:message) do
        create(
          :message,
          account: account,
          content_attributes: { imported_history: true }
        )
      end
      let(:notification) do
        create(
          :notification,
          account: account,
          user: agent,
          notification_type: 'assigned_conversation_new_message',
          primary_actor: message.conversation,
          secondary_actor: message
        )
      end

      it { is_expected.to be(true) }
    end

    context 'when the notification references a live message' do
      let(:message) { create(:message, account: account) }
      let(:notification) do
        create(
          :notification,
          account: account,
          user: agent,
          notification_type: 'assigned_conversation_new_message',
          primary_actor: message.conversation,
          secondary_actor: message
        )
      end

      it { is_expected.to be(false) }
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::DashboardLink do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:url_helpers) { Class.new { include Rails.application.routes.url_helpers }.new }

  context 'when the account does not use communication threads' do
    it 'points to the conversation' do
      link = described_class.for(conversation)

      expect(link.path).to eq("/app/accounts/#{account.id}/conversations/#{conversation.display_id}")
      expect(link.url(url_helpers)).to end_with("/app/accounts/#{account.id}/conversations/#{conversation.display_id}")
    end

    it 'has no thread id even when the conversation was linked to a thread earlier' do
      account.enable_features!('communication_threads')
      conversation.reload.refresh_communication_thread!
      account.disable_features!('communication_threads')

      expect(described_class.thread_display_id_for(conversation.reload)).to be_nil
    end
  end

  context 'when the account uses communication threads' do
    before { account.enable_features!('communication_threads') }

    it 'points to the dialog of the person' do
      thread = conversation.reload.communication_thread
      link = described_class.for(conversation)

      expect(thread).to be_present
      expect(link.path).to eq("/app/accounts/#{account.id}/communication_threads/#{thread.display_id}")
      expect(link.url(url_helpers)).to end_with("/app/accounts/#{account.id}/communication_threads/#{thread.display_id}")
    end

    it 'points to the conversation when it has no thread' do
      conversation.communication_thread_conversation&.destroy!

      link = described_class.for(conversation.reload)

      expect(link.path).to eq("/app/accounts/#{account.id}/conversations/#{conversation.display_id}")
    end

    it 'builds the dialog link of a notification' do
      notification = create(:notification, account: account, user: create(:user, account: account), primary_actor: conversation)
      thread = conversation.reload.communication_thread

      link = described_class.for_notification(notification)

      expect(link.path).to eq("/app/accounts/#{account.id}/communication_threads/#{thread.display_id}")
    end
  end
end

require 'rails_helper'

RSpec.describe ConversationParticipant do
  context 'with validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:conversation_id) }
    it { is_expected.to validate_presence_of(:user_id) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:conversation) }
    it { is_expected.to belong_to(:user) }
  end

  describe 'validations' do
    it 'ensure account is present' do
      conversation = create(:conversation)
      conversation_participant = build(:conversation_participant, conversation: conversation, account_id: nil)
      conversation_participant.valid?
      expect(conversation_participant.account_id).to eq(conversation.account_id)
    end

    it 'throws error if inbox member does not belongs to account' do
      conversation = create(:conversation)
      user = create(:user, account: conversation.account)
      participant = build(:conversation_participant, user: user, conversation: conversation)
      expect { participant.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(participant.errors.messages[:user]).to eq(['must have inbox access'])
    end
  end

  describe '.find_or_create_for!' do
    it 'returns the existing participant when a concurrent create hits the uniqueness validation' do
      conversation = create(:conversation)
      user = create(:user, account: conversation.account)
      create(:inbox_member, user: user, inbox: conversation.inbox)
      existing_participant = create(:conversation_participant, conversation: conversation, user: user)
      duplicate_participant = build(:conversation_participant, conversation: conversation, user: user)
      duplicate_participant.errors.add(:user_id, :taken)
      duplicate_error = ActiveRecord::RecordInvalid.new(duplicate_participant)

      participant_scope = conversation.conversation_participants
      allow(participant_scope).to receive(:find_by).with(user_id: user.id).and_return(nil, existing_participant)
      allow(participant_scope).to receive(:create!).with(user_id: user.id).and_raise(duplicate_error)

      expect(described_class.find_or_create_for!(conversation: conversation, user_id: user.id)).to eq(existing_participant)
    end

    it 'uses a savepoint before create so database uniqueness races remain retryable' do
      conversation = create(:conversation)
      user = create(:user, account: conversation.account)
      create(:inbox_member, user: user, inbox: conversation.inbox)
      existing_participant = create(:conversation_participant, conversation: conversation, user: user)
      duplicate_error = ActiveRecord::RecordNotUnique.new('duplicate participant')
      participant_scope = conversation.conversation_participants

      allow(participant_scope).to receive(:find_by).with(user_id: user.id).and_return(nil)
      allow(participant_scope).to receive(:create!).with(user_id: user.id).and_raise(duplicate_error)
      allow(participant_scope).to receive(:find_by!).with(user_id: user.id).and_return(existing_participant)
      expect(described_class).to receive(:transaction).with(requires_new: true).and_yield

      expect(described_class.find_or_create_for!(conversation: conversation, user_id: user.id)).to eq(existing_participant)
    end
  end
end

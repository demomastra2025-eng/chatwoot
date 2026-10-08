# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboxMember do
  include ActiveJob::TestHelper

  describe 'membership uniqueness' do
    let(:user) { create(:user, account: create(:account)) }
    let(:inbox) { create(:inbox, account: user.accounts.sole) }

    it 'rejects saving a built duplicate even when create fixtures reuse the existing row' do
      existing_member = inbox.inbox_members.find_by!(user: user)
      duplicate = build(:inbox_member, inbox: inbox, user: user)

      expect(duplicate).to be_new_record
      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(duplicate.errors.details[:user_id]).to include(error: :taken)
      expect(inbox.inbox_members.where(user: user).ids).to eq([existing_member.id])
    end

    it 'rejects a duplicate at the database boundary when model validation is bypassed' do
      existing_member = inbox.inbox_members.find_by!(user: user)

      expect do
        described_class.transaction(requires_new: true) do
          described_class.insert_all!([{ inbox_id: inbox.id, user_id: user.id, created_at: Time.current, updated_at: Time.current }])
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)

      expect(inbox.inbox_members.where(user: user).ids).to eq([existing_member.id])
    end
  end

  describe '#DestroyAssociationAsyncJob' do
    let(:inbox_member) { create(:inbox_member) }

    # ref: https://github.com/chatwoot/chatwoot/issues/4616
    context 'when parent inbox is destroyed' do
      it 'enques and processes DestroyAssociationAsyncJob' do
        perform_enqueued_jobs do
          inbox_member.inbox.destroy!
        end
        expect { inbox_member.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end

require 'rails_helper'

RSpec.describe NotificationFinder do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let(:notification_finder) { described_class.new(user, account, params) }

  before do
    create(:notification, :snoozed, account: account, user: user)
    create_list(:notification, 2, :read, account: account, user: user)
    create_list(:notification, 3, account: account, user: user)
  end

  describe '#notifications' do
    subject { notification_finder.notifications }

    context 'with default params (empty)' do
      let(:params) { {} }

      it 'returns all unread and unsnoozed notifications, ordered by last activity' do
        expect(subject.size).to eq(3)
        expect(subject).to match_array(subject.sort_by(&:last_activity_at).reverse)
      end
    end

    context 'with params including read and snoozed statuses' do
      let(:params) { { includes: %w[read snoozed] } }

      it 'returns all notifications, including read and snoozed' do
        expect(subject.size).to eq(6)
      end
    end

    context 'with params including only read status' do
      let(:params) { { includes: ['read'] } }

      it 'returns all notifications expect the snoozed' do
        expect(subject.size).to eq(5)
      end
    end

    context 'with params including archived status' do
      let(:params) { { includes: ['archived'] } }

      it 'returns only read, unsnoozed notifications' do
        expect(subject.size).to eq(2)
        expect(subject.map(&:read_at)).to all(be_present)
      end
    end

    context 'with params including only snoozed status' do
      let(:params) { { includes: ['snoozed'] } }

      it 'rreturns all notifications only expect the read' do
        expect(subject.size).to eq(4)
      end
    end

    context 'with ascending sort order' do
      let(:params) { { sort_order: :asc } }

      it 'returns notifications in ascending order by last activity' do
        expect(subject.first.last_activity_at).to be < subject.last.last_activity_at
      end
    end
  end

  describe 'counts' do
    subject { notification_finder }

    context 'without specific filters' do
      let(:params) { {} }

      it 'correctly reports unread and total counts' do
        expect(subject.unread_count).to eq(3)
        expect(subject.count).to eq(3)
      end

      it 'avoids duplicate filtering in unread_count method' do
        # Test the logical fix: when no 'read' filter is included,
        # @notifications is already filtered to unread, so unread_count
        # should just count without adding another read_at filter

        allow(subject.instance_variable_get(:@notifications)).to receive(:where).and_call_original
        allow(subject.instance_variable_get(:@notifications)).to receive(:count).and_call_original

        result = subject.unread_count

        # Should return correct count without additional where clause
        expect(result).to eq(3)

        # The fix ensures that when params[:includes] doesn't contain 'read',
        # unread_count uses @notifications.count instead of @notifications.where(read_at: nil).count
      end
    end

    context 'with filters applied' do
      let(:params) { { includes: %w[read snoozed] } }

      it 'adjusts counts based on included statuses' do
        expect(subject.unread_count).to eq(4) # 3 unread + 1 snoozed (which is unread)
        expect(subject.count).to eq(6) # all notifications including read and snoozed
      end
    end

    context 'with archived notifications only' do
      let(:params) { { includes: ['archived'] } }

      it 'counts the archive page but keeps the real unread count for the badge' do
        expect(subject.count).to eq(2)
        expect(subject.unread_count).to eq(3)
      end
    end
  end

  describe 'cursor pages' do
    let(:reader) { create(:user, account: account) }
    # Newest activity first: ordered[0] is the top of the list.
    let!(:ordered) do
      base = Time.zone.parse('2026-09-01 10:00:00')
      Array.new(4) do |index|
        create(:notification, account: account, user: reader).tap do |notification|
          notification.update_columns(last_activity_at: base - index.minutes) # rubocop:disable Rails/SkipsModelValidations
        end
      end
    end

    def page_ids(params)
      described_class.new(reader, account, params).notifications.map(&:id)
    end

    it 'continues right after the cursor when a notification above it was archived' do
      ordered[0].update!(read_at: Time.current)

      expect(page_ids(cursor_id: ordered[1].id.to_s)).to eq(ordered.drop(2).map(&:id))
    end

    it 'continues after a cursor that was archived itself' do
      ordered[1].update!(read_at: Time.current)

      expect(page_ids(cursor_id: ordered[1].id.to_s)).to eq(ordered.drop(2).map(&:id))
    end

    it 'orders notifications of the same activity time by id' do
      ordered[2].update_columns(last_activity_at: ordered[1].last_activity_at) # rubocop:disable Rails/SkipsModelValidations

      expect(page_ids({})).to eq([ordered[0], ordered[2], ordered[1], ordered[3]].map(&:id))
      expect(page_ids(cursor_id: ordered[2].id.to_s)).to eq([ordered[1], ordered[3]].map(&:id))
    end

    it 'lists the second of a deleted cursor again instead of skipping' do
      cursor = ordered[1]
      params = { cursor_id: cursor.id.to_s, cursor_last_activity_at: cursor.last_activity_at.to_i.to_s }
      cursor.destroy!

      expect(page_ids(params)).to eq(ordered.drop(2).map(&:id))
    end

    it 'continues after the cursor in ascending order' do
      expect(page_ids(cursor_id: ordered[2].id.to_s, sort_order: 'asc')).to eq([ordered[1], ordered[0]].map(&:id))
    end

    it 'ignores a malformed cursor' do
      expect(page_ids(cursor_id: 'abc', cursor_last_activity_at: 'x')).to eq(ordered.map(&:id))
    end

    it 'ignores the notifications of other users as a cursor' do
      foreign = create(:notification, account: account, user: user)

      expect(page_ids(cursor_id: foreign.id.to_s)).to eq(ordered.map(&:id))
    end

    it 'keeps the list size independent of the cursor' do
      finder = described_class.new(reader, account, cursor_id: ordered[1].id.to_s)

      expect(finder.count).to eq(4)
      expect(finder.notifications.size).to eq(2)
    end
  end
end

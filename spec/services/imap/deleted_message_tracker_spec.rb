require 'rails_helper'

RSpec.describe Imap::DeletedMessageTracker do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, :imap_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:source_id) { 'message-id@example.com' }
  let(:tracker) { described_class.new(inbox: inbox) }
  let(:redis_key) do
    format(
      Redis::RedisKeys::IMAP_DELETED_MESSAGE,
      inbox_id: inbox.id,
      message_id_digest: Digest::SHA256.hexdigest(source_id)
    )
  end

  after do
    Redis::Alfred.delete(redis_key)
  end

  describe '#record' do
    it 'stores a hashed marker for deleted IMAP message source ids' do
      tracker.record([source_id, nil, ''])

      expect(tracker.deleted?(source_id)).to be true
      expect(tracker.deleted?('other-message-id@example.com')).to be false
      # The Redis wrapper does not expose TTL, so use the test connection directly.
      # rubocop:disable Style/GlobalVars
      ttl = $alfred.with { |conn| conn.ttl(redis_key) }
      # rubocop:enable Style/GlobalVars
      expect(ttl).to be_between(1, described_class::TTL).inclusive
    end

    it 'canonicalizes null bytes before storing and looking up markers' do
      raw_source_id = "message\u0000id@example.com"
      sanitized_source_id = 'messageid@example.com'
      sanitized_key = format(
        Redis::RedisKeys::IMAP_DELETED_MESSAGE,
        inbox_id: inbox.id,
        message_id_digest: Digest::SHA256.hexdigest(sanitized_source_id)
      )

      tracker.record([raw_source_id, "\u0000"])

      expect(tracker.deleted?(raw_source_id)).to be true
      expect(tracker.deleted?(sanitized_source_id)).to be true
      expect(tracker.deleted?("\u0000")).to be false
    ensure
      Redis::Alfred.delete(sanitized_key) if sanitized_key
    end
  end
end

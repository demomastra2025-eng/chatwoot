# frozen_string_literal: true

module Telephony
  module Binotel
    class CallHistorySyncService
      DEFAULT_LOOKBACK = 6.hours
      MAX_PERIOD_WINDOW = 24.hours
      SYNC_OVERLAP = 10.minutes

      def initialize(channel:, api_client: nil, from: nil, to: nil, now: Time.current)
        @channel = channel
        @inbox = channel&.inbox || (channel.present? ? Inbox.find_by(channel: channel) : nil)
        @api_client = api_client
        @from = from
        @to = to
        @now = now
      end

      def perform
        return { ok: false, reason: 'invalid_channel' } unless valid_binotel_channel?
        return { ok: false, reason: 'sync_disabled' } if sync_explicitly_disabled?
        return { ok: false, reason: 'api_credentials_not_configured' } unless client.configured?

        stop_time = parse_timestamp(@to) || @now
        start_time = resolve_start_time(stop_time)

        response = client.list_of_calls_for_period(start_time: start_time, stop_time: stop_time)
        rows = extract_call_details(response)

        ingested = 0
        skipped = 0

        rows.each do |detail|
          outcome = ingest_call_detail(detail)
          if outcome == :ingested
            ingested += 1
          else
            skipped += 1
          end
        end

        update_channel_config!('binotel_last_synced_at' => @now.iso8601)

        {
          ok: true,
          fetched: rows.size,
          ingested: ingested,
          skipped: skipped,
          synced_at: @now.iso8601
        }
      rescue ApiClient::ApiError => e
        Rails.logger.warn(
          "TELEPHONY_BINOTEL_CDR_SYNC_API_ERROR channel_id=#{@channel&.id} " \
          "status=#{e.status} message=#{e.message}"
        )
        { ok: false, reason: 'api_error', error: e.message, status: e.status }
      rescue StandardError => e
        Rails.logger.warn(
          "TELEPHONY_BINOTEL_CDR_SYNC_ERROR channel_id=#{@channel&.id} " \
          "error=#{e.class.name}: #{e.message}"
        )
        { ok: false, reason: 'unexpected_error', error: e.message }
      end

      alias call perform

  private

      def client
        @client ||= @api_client || ApiClient.for_channel(@channel)
      end

      def valid_binotel_channel?
        @channel.present? && @channel.is_a?(Channel::Voice) && @channel.provider == 'binotel' && @inbox.present?
      end

      def sync_explicitly_disabled?
        cfg = @channel.provider_config_hash
        cfg.key?('binotel_sync_enabled') && !ActiveModel::Type::Boolean.new.cast(cfg['binotel_sync_enabled'])
      end

      def resolve_start_time(stop_time)
        explicit_from = parse_timestamp(@from)
        return explicit_from if explicit_from.present?

        last_synced = parse_timestamp(@channel.provider_config_hash['binotel_last_synced_at'])
        candidate = last_synced.present? ? (last_synced - SYNC_OVERLAP) : (stop_time - DEFAULT_LOOKBACK)
        [candidate, stop_time - MAX_PERIOD_WINDOW].max
      end

      def extract_call_details(response)
        raw_details = response.is_a?(Hash) ? (response['callDetails'] || response['call_details'] || response['data']) : nil
        list = case raw_details
               when Hash
                 raw_details.values
               when Array
                 raw_details
               else
                 []
               end

        list
          .select { |item| item.is_a?(Hash) }
          .map(&:deep_stringify_keys)
          .sort_by { |item| item['startTime'].to_i }
      end

      def ingest_call_detail(detail)
        config = @channel.provider_config_hash
        adapter = Telephony::Binotel::EventAdapter.new(
          'requestType' => 'apiCallCompleted',
          'callDetails' => detail,
          'chatwoot_account_id' => @channel.account_id,
          'chatwoot_inbox_id' => @inbox.id,
          'number_ref' => config['number_ref'],
          'ingress_number' => config['ingress_number'].presence || @channel.phone_number,
          'received_at' => @now.iso8601
        )
        payload = adapter.payload
        return :skipped if payload.blank?

        if @channel.account.telephony_events.exists?(event_key: payload[:event_key], status: 'processed')
          return :skipped
        end

        payload[:metadata] = (payload[:metadata] || {}).merge(sync_source: 'binotel_cdr_sync')
        Telephony::EventsIngestionService.new(payload: payload).perform
        :ingested
      end

      def parse_timestamp(raw)
        return nil if raw.blank?
        return raw if raw.is_a?(Time) || raw.is_a?(ActiveSupport::TimeWithZone)

        str = raw.to_s.strip
        return Time.zone.at(str.to_i) if str.match?(/\A\d+\z/)

        Time.zone.parse(str)
      rescue ArgumentError, TypeError
        nil
      end

      def update_channel_config!(attrs)
        return if attrs.blank?

        merged = @channel.provider_config_hash.merge(attrs.deep_stringify_keys)
        @channel.update_column(:provider_config, merged)
        @channel.provider_config = merged
      end
    end
  end
end

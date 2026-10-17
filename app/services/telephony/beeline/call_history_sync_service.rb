# frozen_string_literal: true

require 'digest'
require 'securerandom'

module Telephony
  module Beeline
    class CallHistorySyncService
      DEFAULT_LOOKBACK = 2.hours
      SUBSCRIPTION_RENEWAL_BUFFER = 2.hours
      SUBSCRIPTION_EXPIRES_SECONDS = 86_400
      PROXIMITY_CORRELATION_WINDOW = 3.minutes
      PAGE_SIZE = 100
      MAX_PAGES = 10

      def initialize(channel: nil, inbox: nil, api_client: nil, lookback: DEFAULT_LOOKBACK, subscribe_webhook: :auto)
        @channel = channel || inbox&.channel
        @inbox = inbox || @channel&.inbox
        @api_client = api_client
        @lookback = lookback || DEFAULT_LOOKBACK
        @subscribe_webhook = subscribe_webhook
      end

      def perform
        return { ok: false, reason: 'invalid_channel', synced: 0, skipped: 0 } unless valid_beeline_channel?
        return { ok: true, reason: 'sync_disabled', synced: 0, skipped: 0 } if sync_explicitly_disabled?
        return { ok: false, reason: 'api_token_not_configured', synced: 0, skipped: 0 } unless client.configured?

        ensure_webhook_token!
        ensure_webhook_subscription! if should_subscribe_webhook?

        date_to = Time.current
        date_from = date_to - @lookback
        records = fetch_statistics_records(date_from, date_to)

        synced = 0
        skipped = 0

        records.each do |raw_record|
          result = sync_record(raw_record)
          if result == :synced
            synced += 1
          else
            skipped += 1
          end
        rescue StandardError => e
          skipped += 1
          Rails.logger.warn(
            "TELEPHONY_BEELINE_CALL_HISTORY_RECORD_ERROR channel_id=#{@channel.id} " \
            "error=#{e.class.name}: #{e.message}"
          )
        end

        update_channel_config!('beeline_last_synced_at' => Time.current.iso8601)
        { ok: true, synced: synced, skipped: skipped, total: records.size }
      rescue ApiClient::ApiError => e
        Rails.logger.warn(
          "TELEPHONY_BEELINE_CALL_HISTORY_API_ERROR channel_id=#{@channel&.id} " \
          "status=#{e.status} message=#{e.message}"
        )
        { ok: false, reason: 'api_error', status: e.status, error: e.message, synced: 0, skipped: 0 }
      end

      alias call perform

      private

      def valid_beeline_channel?
        @channel.is_a?(Channel::Voice) && @channel.provider == 'beeline' && @inbox.present?
      end

      def sync_explicitly_disabled?
        return false if @subscribe_webhook == true

        cfg = @channel.provider_config_hash
        cfg.key?('beeline_sync_enabled') && !ActiveModel::Type::Boolean.new.cast(cfg['beeline_sync_enabled'])
      end

      def client
        @api_client ||= ApiClient.for_channel(@channel)
      end

      def ensure_webhook_token!
        cfg = @channel.provider_config_hash
        token = cfg['beeline_events_webhook_token'].to_s.strip.presence ||
                cfg['beeline_webhook_token'].to_s.strip.presence
        return token if token.present?

        generated = SecureRandom.hex(24)
        update_channel_config!('beeline_events_webhook_token' => generated)
        generated
      end

      def should_subscribe_webhook?
        return false if @subscribe_webhook == false
        return true if @subscribe_webhook == true

        cfg = @channel.provider_config_hash
        expires_at = parse_timestamp(cfg['beeline_subscription_expires_at'])
        return true if expires_at.blank?

        expires_at <= (Time.current + SUBSCRIPTION_RENEWAL_BUFFER)
      end

      def ensure_webhook_subscription!
        token = ensure_webhook_token!
        webhook_url = build_webhook_url(token)
        return if webhook_url.blank?

        cfg = @channel.provider_config_hash
        existing_sub_id = cfg['beeline_subscription_id'].to_s.strip.presence
        existing_sub_url = cfg['beeline_subscription_url'].to_s.strip.presence

        response = if existing_sub_id.present? && (existing_sub_url.blank? || existing_sub_url == webhook_url)
                     begin
                       client.renew_subscription(
                         subscription_id: existing_sub_id,
                         expires: SUBSCRIPTION_EXPIRES_SECONDS
                       )
                     rescue StandardError
                       client.subscribe_webhook(
                         url: webhook_url,
                         expires: SUBSCRIPTION_EXPIRES_SECONDS,
                         subscription_type: 'BASIC_CALL'
                       )
                     end
                   else
                     client.subscribe_webhook(
                       url: webhook_url,
                       expires: SUBSCRIPTION_EXPIRES_SECONDS,
                       subscription_type: 'BASIC_CALL'
                     )
                   end

        subscription_id = if response.is_a?(Hash)
                            response['subscriptionId'] || response['id'] || existing_sub_id
                          else
                            existing_sub_id
                          end
        expires_seconds = if response.is_a?(Hash) && response['expires'].present?
                            response['expires'].to_i
                          else
                            SUBSCRIPTION_EXPIRES_SECONDS
                          end
        expires_at = Time.current + expires_seconds.seconds

        update_channel_config!(
          {
            'beeline_subscription_id' => subscription_id,
            'beeline_subscription_url' => webhook_url,
            'beeline_subscription_expires_at' => expires_at.iso8601
          }.compact
        )
      rescue StandardError => e
        Rails.logger.warn(
          "TELEPHONY_BEELINE_WEBHOOK_SUBSCRIBE_FAILED channel_id=#{@channel.id} " \
          "error=#{e.class.name}: #{e.message}"
        )
      end

      def build_webhook_url(token)
        base = ENV.fetch('FRONTEND_URL', '').to_s.strip.presence ||
               ENV.fetch('BACKEND_URL', '').to_s.strip.presence
        return nil if base.blank? || token.blank?

        "#{base.sub(%r{/+\z}, '')}/beeline/events/#{token}"
      end

      def fetch_statistics_records(date_from, date_to)
        all_records = []
        MAX_PAGES.times do |page|
          raw_response = client.statistics(
            date_from: date_from,
            date_to: date_to,
            page: page,
            page_size: PAGE_SIZE
          )
          batch = extract_records(raw_response)
          all_records.concat(batch)
          break if batch.size < PAGE_SIZE
        end
        all_records
      end

      def extract_records(raw_response)
        case raw_response
        when Array
          raw_response
        when Hash
          %w[records items data list content results].each do |key|
            return raw_response[key] if raw_response[key].is_a?(Array)
          end
          []
        else
          []
        end
      end

      def sync_record(raw_record)
        return :skipped unless raw_record.is_a?(Hash)

        row = raw_record.deep_stringify_keys
        direction = resolve_direction(row)
        return :skipped unless %w[inbound outbound].include?(direction)

        started_at = parse_timestamp(
          row['startDate'] || row['start_date'] || row['date'] || row['startTime'] || row['start_time'] || row['started_at']
        )
        return :skipped if started_at.blank?

        record_uid = extract_record_uid(row, direction, started_at)
        return :skipped if record_uid.blank?

        abonent = row['abonent'].is_a?(Hash) ? row['abonent'].deep_stringify_keys : {}
        operator_extension = (
          row['extension'] || row['abonent_extension'] || abonent['extension'] ||
          extract_extension(abonent['userId'] || row['userId'])
        ).to_s.strip.presence
        operator_user_id = (abonent['userId'] || row['userId'] || abonent['phone']).to_s.strip.presence

        contact_phone = extract_contact_phone(row, direction)
        return :skipped if contact_phone.blank?

        duration_seconds = parse_duration_seconds(row)
        answered_at = parse_timestamp(row['answerTime'] || row['answer_time'] || row['answered_at'])
        was_answered = record_answered?(row, answered_at, duration_seconds)
        answered_at ||= started_at if was_answered
        ended_at = parse_timestamp(row['releaseTime'] || row['release_time'] || row['endDate'] || row['ended_at']) ||
                   (started_at + duration_seconds.to_i.seconds)

        event, status = resolve_event_and_status(row, direction, was_answered)
        cdr_ref = "beeline:cdr:#{record_uid}"

        existing = find_existing_session(
          record_uid: record_uid,
          ext_tracking_id: row['extTrackingId'] || row['ext_tracking_id'],
          cdr_ref: cdr_ref,
          direction: direction,
          contact_phone: contact_phone,
          operator_extension: operator_extension,
          operator_user_id: operator_user_id,
          started_at: started_at
        )

        record_id = (row['recordId'] || row['record_id'] || row['recording_id']).to_s.strip.presence

        if existing.present? && existing.terminal? && existing_already_synced?(existing, cdr_ref, status: status, record_id: record_id)
          import_recording_if_needed!(existing, record_id) if record_id.present?
          return :skipped
        end

        if existing.present? && existing.answered_at.present? && %w[missed no_answer].include?(status)
          event = 'completed'
          status = 'completed'
          answered_at ||= existing.answered_at
        end

        profile = resolve_operator_profile(operator_extension, operator_user_id)
        binding = @inbox.telephony_number_binding
        did = normalize_phone(binding&.phone_number.presence || @channel.phone_number) ||
              operator_extension ||
              normalize_phone(abonent['phone'])

        from_number = direction == 'inbound' ? contact_phone : (did.presence || operator_extension)
        to_number = direction == 'inbound' ? (did.presence || operator_extension) : contact_phone

        provider_sid = if existing.blank? || existing.provider_call_sid.blank? || existing.provider_call_sid == record_uid
                         record_uid
                       else
                         existing.provider_call_sid
                       end

        payload = {
          'account_id' => @inbox.account_id,
          'inbox_id' => @inbox.id,
          'call_ref' => existing&.external_call_ref || cdr_ref,
          'provider_call_sid' => provider_sid,
          'event_key' => "#{cdr_ref}:final:#{status}",
          'event' => event,
          'status' => status,
          'provider' => 'beeline',
          'direction' => direction,
          'number_ref' => binding&.number_ref,
          'ingress_number' => binding&.phone_number.presence || @channel.phone_number,
          'from' => from_number,
          'to' => to_number,
          'from_number' => from_number,
          'to_number' => to_number,
          'started_at' => started_at.iso8601,
          'answered_at' => answered_at&.iso8601,
          'answered_by' => ("user:#{profile.user_id}" if answered_at.present? && profile&.user_id.present?),
          'ended_at' => ended_at.iso8601,
          'occurred_at' => ended_at.iso8601,
          'duration' => duration_seconds,
          'metadata' => {
            'chatwoot_account_id' => @inbox.account_id,
            'chatwoot_inbox_id' => @inbox.id,
            'chatwoot_user_id' => profile&.user_id,
            'source' => 'beeline_call_history_sync',
            'beeline_cdr_ref' => cdr_ref,
            'beeline_call_id' => record_uid,
            'beeline_ext_tracking_id' => row['extTrackingId'] || row['ext_tracking_id'],
            'beeline_record_id' => record_id,
            'abonent_extension' => operator_extension,
            'abonent_user_id' => operator_user_id,
            'route_action' => 'operator',
            'routing_mode' => 'operator'
          }.compact
        }.compact
        payload['callee_leg_answered'] = true if direction == 'outbound' && status == 'completed'

        if existing.blank?
          payload = TerminalFallbackAdapter.new(payload: payload).call || payload
        end

        session = Telephony::EventsIngestionService.new(payload: payload).perform
        return :skipped if session.blank?

        import_recording_if_needed!(session, record_id) if record_id.present?
        :synced
      end

      def find_existing_session(record_uid:, ext_tracking_id:, cdr_ref:, direction:, contact_phone:, operator_extension:, operator_user_id:, started_at:)
        scope = @inbox.account.telephony_call_sessions.where(inbox_id: @inbox.id)
        direct_refs = [cdr_ref, "beeline:#{record_uid}", ("beeline:#{ext_tracking_id}" if ext_tracking_id.present?)].compact.uniq
        direct = scope.where(external_call_ref: direct_refs).order(id: :desc).first
        return resolve_winner_leg(direct) if direct.present?

        sids = [record_uid, ext_tracking_id].compact_blank.uniq
        if sids.any?
          by_sid = scope.where(provider_call_sid: sids).order(id: :desc).first
          return resolve_winner_leg(by_sid) if by_sid.present?
        end

        correlated_webphone = NativeWebphoneCorrelator.new(
          inbox: @inbox,
          direction: direction,
          contact_phone: contact_phone,
          beeline_call_id: record_uid,
          ext_tracking_id: ext_tracking_id,
          operator_extension: operator_extension,
          operator_user_id: operator_user_id,
          event_time: started_at
        ).call
        return correlated_webphone if correlated_webphone.present?

        find_proximity_beeline_session(
          record_uid: record_uid,
          direction: direction,
          contact_phone: contact_phone,
          started_at: started_at
        )
      end

      def resolve_winner_leg(session)
        return nil if session.blank?
        return session unless session.end_reason.to_s == Telephony::SiblingLegCloser::END_REASON

        winner = session.logical_group_sessions.find do |sibling|
          sibling.id != session.id &&
            (sibling.answered_at.present? || %w[connecting in_progress completed].include?(sibling.canonical_status))
        end
        return session if winner.blank?

        session.update_column(:provider_call_sid, nil) if session.provider_call_sid.present?
        winner
      end

      def find_proximity_beeline_session(record_uid:, direction:, contact_phone:, started_at:)
        return nil if contact_phone.blank? || started_at.blank?

        target_digits = comparable_phone_digits(contact_phone)
        return nil if target_digits.blank?

        window_start = started_at - PROXIMITY_CORRELATION_WINDOW
        window_end = started_at + PROXIMITY_CORRELATION_WINDOW

        candidates = @inbox.account.telephony_call_sessions
                           .where(inbox_id: @inbox.id, provider: 'beeline', direction: direction)
                           .where("external_call_ref LIKE 'beeline:%'")
                           .where("external_call_ref NOT LIKE 'beeline:janus:%' AND external_call_ref NOT LIKE 'beeline:local:%'")
                           .where('COALESCE(started_at, created_at) BETWEEN ? AND ?', window_start, window_end)
                           .order(id: :desc)
                           .to_a

        matching = candidates.select do |session|
          session_phone = direction == 'inbound' ? session.from_number : session.to_number
          next false unless comparable_phone_digits(session_phone) == target_digits

          existing_cdr_id = session_beeline_call_id(session)
          existing_cdr_id.blank? || existing_cdr_id == record_uid.to_s
        end

        matching.min_by { |session| ((session.started_at || session.created_at) - started_at).abs }
      end

      def session_beeline_call_id(session)
        meta = session.metadata.is_a?(Hash) ? session.metadata : {}
        nested = meta['metadata'].is_a?(Hash) ? meta['metadata'] : {}
        cdr_ref = (meta['beeline_cdr_ref'] || nested['beeline_cdr_ref']).to_s.strip
        return cdr_ref.delete_prefix('beeline:cdr:') if cdr_ref.start_with?('beeline:cdr:')
        return session.external_call_ref.delete_prefix('beeline:cdr:') if session.external_call_ref.to_s.start_with?('beeline:cdr:')

        nil
      end

      def comparable_phone_digits(raw_phone)
        digits = raw_phone.to_s.gsub(/\D+/, '')
        return nil if digits.length < 7

        digits.length > 10 ? digits[-10, 10] : digits
      end

      def existing_already_synced?(session, cdr_ref, status: nil, record_id: nil)
        meta = session.metadata.is_a?(Hash) ? session.metadata : {}
        nested = meta['metadata'].is_a?(Hash) ? meta['metadata'] : {}
        return true if (meta['beeline_cdr_ref'] == cdr_ref || nested['beeline_cdr_ref'] == cdr_ref) ||
                       session.external_call_ref == cdr_ref

        session.terminal? &&
          status.present? &&
          session.canonical_status.to_s == status.to_s &&
          (record_id.blank? || session.recording_ref.present?)
      end

      def import_recording_if_needed!(session, record_id)
        return if record_id.blank?

        RecordingSyncService.new(
          call_session: session,
          record_id: record_id,
          api_client: client
        ).perform
      end

      def resolve_operator_profile(operator_extension, operator_user_id)
        return nil if operator_extension.blank? && operator_user_id.blank?

        candidates = [
          operator_extension,
          operator_user_id,
          operator_user_id&.split('@')&.first
        ].compact.map(&:to_s).map(&:strip).reject(&:blank?).uniq
        return nil if candidates.empty?

        @inbox.telephony_sip_profiles.where(enabled: true).find do |profile|
          profile_tokens = [
            profile.internal_extension,
            profile.sip_username,
            profile.sip_username.to_s.split('@').first
          ].compact.map(&:to_s).map(&:strip)
          (profile_tokens & candidates).any?
        end
      end

      def resolve_direction(row)
        raw = (row['direction'] || row['call_direction'] || row['type']).to_s.strip.downcase
        return 'inbound' if %w[inbound in incoming terminator 1].include?(raw)
        return 'outbound' if %w[outbound out outgoing originator click-to-dial 2].include?(raw)

        status = row['status'].to_s.strip.downcase
        return 'outbound' if status == 'placed'
        return 'inbound' if %w[received missed].include?(status)

        nil
      end

      def extract_record_uid(row, direction, started_at)
        explicit = row['id'] || row['callId'] || row['call_id'] || row['extTrackingId'] ||
                   row['ext_tracking_id'] || row['uid'] || row['recordId']
        return explicit.to_s.strip if explicit.to_s.strip.present?

        phone = row['phone'] || row['phone_from'] || row['phone_to'] || row['from'] || row['to']
        return nil if phone.blank?

        Digest::SHA256.hexdigest("#{direction}:#{phone}:#{started_at.to_i}")[0, 24]
      end

      def extract_contact_phone(row, direction)
        raw = row['phone'].presence ||
              (direction == 'inbound' ? (row['phone_from'] || row['from'] || row['caller'] || row['src']) : (row['phone_to'] || row['to'] || row['callee'] || row['dst']))
        normalize_phone(raw)
      end

      def record_answered?(row, answered_at, duration_seconds)
        status = row['status'].to_s.strip.downcase
        return false if %w[missed noanswer no_answer abandoned busy failed cancelled canceled].include?(status)
        return true if answered_at.present?
        return true if status == 'received' && (duration_seconds.nil? || duration_seconds.to_i >= 0)
        return true if %w[placed completed answered success].include?(status) && duration_seconds.to_i.positive?

        duration_seconds.to_i.positive?
      end

      def resolve_event_and_status(row, direction, was_answered)
        return %w[completed completed] if was_answered

        status = row['status'].to_s.strip.downcase
        case status
        when 'busy'
          %w[busy busy]
        when 'failed', 'error'
          %w[failed failed]
        when 'cancel', 'cancelled', 'canceled'
          %w[cancelled cancelled]
        else
          direction == 'outbound' ? %w[no_answer no_answer] : %w[missed missed]
        end
      end

      def parse_duration_seconds(row)
        return (row['duration_ms'].to_i / 1000) if row['duration_ms'].present?
        return row['duration_seconds'].to_i if row['duration_seconds'].present?

        raw = row['duration']
        return 0 if raw.blank?

        val = raw.to_i
        return 0 if val <= 0

        # Beeline /v2/statistics returns startDate as 13-digit epoch ms and duration in ms
        raw_start = (row['startDate'] || row['date']).to_s.strip
        if raw_start.match?(/\A\d{13}\z/) && val >= 1000 && (val % 1000).zero?
          return val / 1000
        end

        val
      end

      def parse_timestamp(raw)
        return nil if raw.blank?
        return raw if raw.is_a?(Time) || raw.is_a?(ActiveSupport::TimeWithZone)

        str = raw.to_s.strip
        if str.match?(/\A\d+\z/)
          num = str.to_i
          return nil if num <= 0

          return num > 10_000_000_000 ? Time.zone.at(num / 1000.0) : Time.zone.at(num)
        end

        Time.zone.parse(str)
      rescue ArgumentError, TypeError
        nil
      end

      def extract_extension(raw_user_id)
        return nil if raw_user_id.blank?

        raw_user_id.to_s.strip.sub(/\A(?:sip|sips|tel):/i, '').split('@').first.to_s.strip.presence
      end

      def normalize_phone(raw)
        return nil if raw.blank?

        cleaned = raw.to_s.strip.sub(/\A(?:tel|sip|sips):/i, '').split('@').first.to_s.split(';').first.to_s.strip
        return nil if cleaned.blank?

        normalized = Contacts::PhoneNumberNormalizer.normalize(cleaned) ||
                     Contacts::PhoneNumberNormalizer.normalize(cleaned, default_country: 'KZ')
        return normalized if normalized.present?

        digits = cleaned.gsub(/\D+/, '')
        return nil if digits.blank?
        return "+7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
        return "+#{digits}" if digits.length >= 10

        cleaned
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

# frozen_string_literal: true

require 'digest'
require 'nokogiri'

module Telephony
  module Beeline
    class EventAdapter
      ANSWERED_CACHE_TTL = 6.hours

      attr_reader :correlated_session, :correlation_status

      def initialize(params:, inbox:, raw_body: nil)
        @params = normalize_params(params)
        @inbox = inbox
        @raw_body = raw_body.to_s.strip
        @correlated_session = nil
        @correlation_status = :not_attempted
      end

      def call
        return nil if @inbox.blank?

        parsed = xml_payload? ? parse_xsi_xml : parse_structured_params
        return nil if parsed.blank?

        tracking_id = parsed[:ext_tracking_id].presence || parsed[:call_id].presence
        return nil if tracking_id.blank?

        direction = parsed[:direction].presence || 'inbound'
        contact_phone = direction == 'inbound' ? parsed[:from_number] : parsed[:to_number]
        return nil if contact_phone.blank? && parsed[:from_number].blank? && parsed[:to_number].blank?

        event_time = parsed[:occurred_at] || parsed[:ended_at] || parsed[:answered_at] || parsed[:started_at] || Time.current

        @correlated_session = NativeWebphoneCorrelator.new(
          inbox: @inbox,
          direction: direction,
          contact_phone: contact_phone,
          beeline_call_id: parsed[:call_id],
          ext_tracking_id: parsed[:ext_tracking_id],
          operator_extension: parsed[:operator_extension],
          operator_user_id: parsed[:operator_user_id],
          event_time: event_time
        ).call
        @correlation_status = @correlated_session.present? ? :matched : :unmatched

        reconciled = reconcile_event_and_status(parsed, tracking_id, direction)
        return nil if reconciled.nil?

        event, status, answered_at, ended_at, duration_seconds = reconciled
        remember_answered_leg!(tracking_id, parsed[:call_id], answered_at, parsed[:operator_extension]) if answered_at.present? || status == 'in_progress'

        build_ingestion_payload(
          parsed: parsed,
          tracking_id: tracking_id,
          direction: direction,
          event: event,
          status: status,
          answered_at: answered_at,
          ended_at: ended_at,
          duration_seconds: duration_seconds,
          occurred_at: event_time
        )
      end

      private

      def normalize_params(raw)
        case raw
        when ActionController::Parameters
          raw.to_unsafe_h.deep_stringify_keys
        when Hash
          raw.deep_stringify_keys
        else
          {}
        end
      end

      def xml_payload?
        return true if @raw_body.start_with?('<')
        return true if @params['xml'].to_s.strip.start_with?('<')

        false
      end

      def parse_xsi_xml
        xml_source = @raw_body.start_with?('<') ? @raw_body : @params['xml'].to_s.strip
        return nil if xml_source.blank?

        doc = Nokogiri::XML(xml_source) { |config| config.nonet.norecover }
        return nil if doc.root.blank?

        annotate_xsi_types!(doc)
        doc.remove_namespaces!

        call_node = doc.at_xpath('//call') || doc.at_xpath('//Call')
        return nil if call_node.blank?

        event_data_node = doc.at_xpath('//eventData') || doc.at_xpath('//EventData') || doc.root
        xsi_event_type = event_data_node&.attribute('data-xsi-type')&.value.to_s.split(':').last.presence ||
                         doc.root&.attribute('data-xsi-type')&.value.to_s.split(':').last.presence ||
                         event_data_node&.name.to_s

        call_id = xml_text(call_node, 'callId', 'CallId')
        ext_tracking_id = xml_text(call_node, 'extTrackingId', 'ExtTrackingId')
        network_call_id = xml_text(call_node, 'networkCallId', 'NetworkCallId')
        personality = xml_text(call_node, 'personality', 'Personality')
        state = xml_text(call_node, 'state', 'State')
        releasing_party = xml_text(call_node, 'releasingParty', 'ReleasingParty')

        remote_address = xml_text(call_node, 'remoteParty/address', 'RemoteParty/Address', 'remoteParty/userId')
        remote_name = xml_text(call_node, 'remoteParty/name', 'RemoteParty/Name')
        remote_call_type = xml_text(call_node, 'remoteParty/callType', 'RemoteParty/CallType')

        endpoint_aor = xml_text(
          call_node,
          'endpoint/addressOfRecord',
          'Endpoint/AddressOfRecord',
          'endpoint/userId',
          'Endpoint/UserId'
        )
        target_id = xml_text(doc, '//targetId', '//TargetId', '//userId', '//UserId')
        event_id = xml_text(doc, '//eventID', '//eventId', '//EventID', '//EventId')
        sequence_number = xml_text(doc, '//sequenceNumber', '//SequenceNumber')
        subscription_id = xml_text(doc, '//subscriptionId', '//SubscriptionId')

        direction = map_xsi_personality(personality)
        remote_phone = normalize_phone(extract_address_number(remote_address))
        operator_user_id = endpoint_aor.presence || target_id.presence
        operator_extension = extract_operator_extension(operator_user_id)
        channel_phone = normalize_phone(@inbox.channel&.phone_number)
        local_party = operator_extension.presence || channel_phone.presence || extract_address_number(operator_user_id)

        from_number = direction == 'inbound' ? remote_phone : local_party
        to_number = direction == 'inbound' ? (channel_phone.presence || local_party) : remote_phone

        started_at = parse_timestamp(xml_text(call_node, 'startTime', 'StartTime'))
        answered_at = parse_timestamp(xml_text(call_node, 'answerTime', 'AnswerTime'))
        ended_at = parse_timestamp(xml_text(call_node, 'releaseTime', 'ReleaseTime'))
        duration_seconds = if answered_at.present? && ended_at.present? && ended_at >= answered_at
                             (ended_at - answered_at).to_i
                           end

        raw_event, raw_status = classify_xsi_event(xsi_event_type, state, direction, answered_at)
        return nil if raw_event.blank?

        {
          format: 'xsi_xml',
          xsi_event_type: xsi_event_type,
          event_id: event_id,
          sequence_number: sequence_number,
          subscription_id: subscription_id,
          call_id: call_id.presence || ext_tracking_id,
          ext_tracking_id: ext_tracking_id.presence || call_id,
          network_call_id: network_call_id,
          direction: direction,
          raw_event: raw_event,
          raw_status: raw_status,
          state: state,
          releasing_party: releasing_party,
          from_number: from_number,
          to_number: to_number,
          remote_name: remote_name,
          remote_call_type: remote_call_type,
          operator_extension: operator_extension,
          operator_user_id: operator_user_id,
          started_at: started_at,
          answered_at: answered_at,
          ended_at: ended_at,
          occurred_at: ended_at || answered_at || started_at || Time.current,
          duration_seconds: duration_seconds,
          raw_summary: {
            'xsi_event_type' => xsi_event_type,
            'event_id' => event_id,
            'sequence_number' => sequence_number,
            'call_id' => call_id,
            'ext_tracking_id' => ext_tracking_id,
            'personality' => personality,
            'state' => state,
            'releasing_party' => releasing_party,
            'remote_address' => remote_address,
            'endpoint_aor' => endpoint_aor,
            'target_id' => target_id
          }.compact
        }
      rescue Nokogiri::XML::SyntaxError
        nil
      end

      def annotate_xsi_types!(doc)
        doc.traverse do |node|
          next unless node.element?

          type_attr = node.attribute_nodes.find { |attr| attr.name == 'type' }
          node['data-xsi-type'] = type_attr.value if type_attr.present?
        end
      end

      def xml_text(context_node, *xpaths)
        xpaths.each do |xpath|
          node = context_node.at_xpath(xpath)
          value = node&.text.to_s.strip
          return value if value.present?
        end
        nil
      end

      def map_xsi_personality(personality)
        case personality.to_s.strip.downcase
        when 'originator', 'click-to-dial', 'click_to_dial', 'outbound'
          'outbound'
        else
          'inbound'
        end
      end

      def classify_xsi_event(xsi_event_type, state, direction, answered_at)
        type_down = xsi_event_type.to_s.downcase
        state_down = state.to_s.strip.downcase

        return [nil, nil] if type_down.include?('subscriptionterminated') || type_down.include?('keepalive')

        if type_down.include?('callabandoned')
          return direction == 'outbound' ? %w[no_answer no_answer] : %w[missed missed]
        end

        if type_down.include?('callreleased') || state_down == 'released'
          if answered_at.present?
            return %w[completed completed]
          else
            return direction == 'outbound' ? %w[no_answer no_answer] : %w[missed missed]
          end
        end

        if type_down.include?('callanswered') || (state_down == 'active' && answered_at.present?)
          return %w[answered in_progress]
        end

        if type_down.include?('calloriginated')
          return %w[initiated ringing]
        end

        if type_down.include?('callreceived') || type_down.include?('callalerting') || state_down == 'alerting'
          return direction == 'outbound' ? %w[initiated ringing] : %w[ringing ringing]
        end

        if state_down == 'active'
          return %w[answered in_progress]
        end

        [nil, nil]
      end

      def parse_structured_params
        payload = @params['data'].is_a?(Hash) ? @params.merge(@params['data']) : @params
        call_hash = payload['call'].is_a?(Hash) ? payload['call'] : {}
        merged = call_hash.merge(payload)

        ext_tracking_id = first_value(merged, 'extTrackingId', 'ext_tracking_id', 'trackingId', 'tracking_id')
        call_id = first_value(merged, 'callId', 'call_id', 'callid', 'id', 'uid', 'uuid', 'session_id') || ext_tracking_id
        return nil if call_id.blank? && ext_tracking_id.blank?

        abonent = merged['abonent'].is_a?(Hash) ? merged['abonent'].deep_stringify_keys : {}
        operator_extension = first_value(merged, 'extension', 'abonent_extension', 'internal_number', 'internalNumber') ||
                             first_value(abonent, 'extension', 'number')
        operator_user_id = first_value(merged, 'userId', 'user_id', 'targetId', 'target_id') ||
                           first_value(abonent, 'userId', 'user_id', 'phone')
        operator_extension ||= extract_operator_extension(operator_user_id)

        raw_from = first_value(merged, 'phone_from', 'from_number', 'fromNumber', 'from', 'caller', 'caller_number', 'src', 'callingNumber', 'ani')
        raw_to = first_value(merged, 'phone_to', 'to_number', 'toNumber', 'to', 'callee', 'callee_number', 'dst', 'calledNumber', 'dnis', 'diversion', 'did')
        remote_phone = first_value(merged, 'phone', 'remote_phone', 'remotePhone', 'client_phone', 'contact_phone')

        direction = resolve_structured_direction(merged, raw_from, raw_to)
        channel_phone = normalize_phone(@inbox.channel&.phone_number)
        abonent_party = operator_extension.presence || normalize_phone(abonent['phone']) || channel_phone

        if raw_from.blank? && raw_to.blank? && remote_phone.present?
          if direction == 'outbound'
            raw_from = abonent_party
            raw_to = remote_phone
          else
            raw_from = remote_phone
            raw_to = channel_phone.presence || abonent_party
          end
        end

        from_number = normalize_party_number(raw_from, fallback: direction == 'outbound' ? abonent_party : nil)
        to_number = normalize_party_number(raw_to, fallback: direction == 'inbound' ? (channel_phone.presence || abonent_party) : nil)

        started_at = parse_timestamp(first_value(merged, 'startDate', 'start_date', 'startTime', 'start_time', 'started_at', 'startedAt', 'date', 'timestamp'))
        answered_at = parse_timestamp(first_value(merged, 'answerTime', 'answer_time', 'answered_at', 'answeredAt'))
        ended_at = parse_timestamp(first_value(merged, 'releaseTime', 'release_time', 'endDate', 'end_date', 'endTime', 'end_time', 'ended_at', 'endedAt'))
        duration_seconds = parse_duration_seconds(merged, answered_at: answered_at, ended_at: ended_at)

        if answered_at.blank? && started_at.present? && duration_seconds.to_i.positive? &&
           classify_structured_answered?(merged, duration_seconds)
          answered_at = started_at
          ended_at ||= started_at + duration_seconds.to_i.seconds
        end

        raw_event, raw_status = classify_structured_event_and_status(merged, direction, answered_at, duration_seconds)
        return nil if raw_event.blank?

        ended_at ||= (started_at + duration_seconds.to_i.seconds) if started_at.present? && duration_seconds.to_i.positive? && terminal_status?(raw_status)
        occurred_at = parse_timestamp(first_value(merged, 'occurred_at', 'occurredAt')) ||
                      ended_at || answered_at || started_at || Time.current

        record_id = first_value(merged, 'recordId', 'record_id', 'recording_id', 'recordingId')
        recording_url = first_value(merged, 'recordUrl', 'record_url', 'recording_url', 'recordingUrl', 'audio_url')

        remote_name = first_value(merged, 'caller_name', 'callerName', 'remote_name', 'name')
        if remote_name.blank? && abonent.present?
          abonent_name = [abonent['firstName'], abonent['lastName']].map { |v| v.to_s.strip }.reject(&:blank?).join(' ')
          metadata_abonent_name = abonent_name.presence
        end

        {
          format: 'json',
          event_id: first_value(merged, 'eventId', 'event_id'),
          sequence_number: first_value(merged, 'sequenceNumber', 'sequence_number'),
          call_id: call_id.to_s,
          ext_tracking_id: (ext_tracking_id.presence || call_id).to_s,
          direction: direction,
          raw_event: raw_event,
          raw_status: raw_status,
          from_number: from_number,
          to_number: to_number,
          remote_name: remote_name,
          abonent_name: metadata_abonent_name,
          operator_extension: operator_extension,
          operator_user_id: operator_user_id,
          started_at: started_at,
          answered_at: answered_at,
          ended_at: ended_at,
          occurred_at: occurred_at,
          duration_seconds: duration_seconds,
          record_id: record_id,
          recording_url: recording_url,
          raw_summary: merged.except('controller', 'action', 'token')
        }
      end

      def resolve_structured_direction(merged, raw_from, raw_to)
        raw_dir = first_value(merged, 'direction', 'call_direction', 'callDirection', 'personality', 'type', 'call_type').to_s.strip.downcase
        return 'inbound' if %w[inbound in incoming terminator from_pstn 1].include?(raw_dir)
        return 'outbound' if %w[outbound out outgoing originator click-to-dial click_to_dial to_pstn 2].include?(raw_dir)

        raw_status = first_value(merged, 'status', 'disposition', 'call_status').to_s.strip.downcase
        return 'outbound' if raw_status == 'placed'

        if internal_number?(raw_from) && !internal_number?(raw_to)
          'outbound'
        else
          'inbound'
        end
      end

      def classify_structured_answered?(merged, duration_seconds)
        raw_status = first_value(merged, 'status', 'disposition', 'call_status', 'event', 'event_type', 'cmd').to_s.strip.downcase
        return false if %w[missed noanswer no_answer unanswered abandoned busy failed error cancel cancelled canceled ringing alerting initiated].include?(raw_status)

        %w[received answered completed placed success hangup released call_released].include?(raw_status) && duration_seconds.to_i.positive?
      end

      def classify_structured_event_and_status(merged, direction, answered_at, duration_seconds)
        raw_token = first_value(merged, 'event', 'event_type', 'eventType', 'cmd', 'type').to_s.strip.downcase
        raw_status = first_value(merged, 'status', 'disposition', 'call_status', 'callStatus', 'state').to_s.strip.downcase
        combined = [raw_token, raw_status].reject(&:blank?)
        return [nil, nil] if combined.empty?

        token = raw_token.presence || raw_status

        case token
        when 'ringing', 'incoming', 'alerting', 'call_received', 'callreceived', 'callreceivedevent'
          direction == 'outbound' ? %w[initiated ringing] : %w[ringing ringing]
        when 'initiated', 'outbound', 'call_originated', 'calloriginated', 'calloriginatedevent', 'dialing'
          %w[initiated ringing]
        when 'answered', 'accepted', 'in_progress', 'active', 'call_answered', 'callanswered', 'callansweredevent'
          %w[answered in_progress]
        when 'missed', 'abandoned', 'call_abandoned', 'callabandoned', 'callabandonedevent'
          direction == 'outbound' ? %w[no_answer no_answer] : %w[missed missed]
        when 'no_answer', 'noanswer', 'unanswered'
          direction == 'inbound' ? %w[missed missed] : %w[no_answer no_answer]
        when 'busy'
          %w[busy busy]
        when 'failed', 'error', 'congestion', 'rejected'
          %w[failed failed]
        when 'cancel', 'cancelled', 'canceled'
          %w[cancelled cancelled]
        when 'received', 'answer', 'success'
          %w[completed completed]
        when 'placed'
          if raw_status.in?(%w[missed no_answer noanswer])
            %w[no_answer no_answer]
          elsif answered_at.present? || duration_seconds.nil? || duration_seconds.to_i.positive?
            %w[completed completed]
          else
            %w[no_answer no_answer]
          end
        when 'completed', 'hangup', 'released', 'call_released', 'callreleased', 'callreleasedevent', 'history', 'cdr'
          classify_release_or_cdr_status(raw_status, direction, answered_at, duration_seconds)
        else
          classify_release_or_cdr_status(raw_status.presence || token, direction, answered_at, duration_seconds)
        end
      end

      def classify_release_or_cdr_status(raw_status, direction, answered_at, duration_seconds)
        case raw_status.to_s.strip.downcase
        when 'missed', 'abandoned'
          direction == 'outbound' ? %w[no_answer no_answer] : %w[missed missed]
        when 'no_answer', 'noanswer', 'unanswered'
          direction == 'inbound' ? %w[missed missed] : %w[no_answer no_answer]
        when 'busy'
          %w[busy busy]
        when 'failed', 'error', 'congestion'
          %w[failed failed]
        when 'cancel', 'cancelled', 'canceled'
          %w[cancelled cancelled]
        when 'ringing', 'alerting'
          direction == 'outbound' ? %w[initiated ringing] : %w[ringing ringing]
        when 'in_progress', 'active', 'answered'
          if answered_at.present? || duration_seconds.to_i.positive?
            %w[completed completed]
          else
            %w[answered in_progress]
          end
        when 'received', 'completed', 'success'
          %w[completed completed]
        when 'placed'
          if answered_at.present? || duration_seconds.nil? || duration_seconds.to_i.positive?
            %w[completed completed]
          else
            %w[no_answer no_answer]
          end
        else
          if answered_at.present? || duration_seconds.to_i.positive?
            %w[completed completed]
          else
            direction == 'outbound' ? %w[no_answer no_answer] : %w[missed missed]
          end
        end
      end

      def reconcile_event_and_status(parsed, tracking_id, direction)
        event = parsed[:raw_event]
        status = parsed[:raw_status]
        answered_at = parsed[:answered_at]
        ended_at = parsed[:ended_at]
        duration_seconds = parsed[:duration_seconds]

        cached_answer = read_answered_leg(tracking_id)
        session_was_answered = @correlated_session&.answered_at.present? ||
                               %w[in_progress completed].include?(@correlated_session&.status.to_s) ||
                               cached_answer.present?

        if %w[missed no_answer].include?(status) && session_was_answered
          answered_call_id = cached_answer&.dig('call_id') ||
                             @correlated_session&.metadata.to_h['beeline_answered_call_id']
          if answered_call_id.present? && parsed[:call_id].present? && answered_call_id != parsed[:call_id]
            return nil
          end

          event = 'completed'
          status = 'completed'
          answered_at ||= @correlated_session&.answered_at || parse_timestamp(cached_answer&.dig('answered_at'))
          if duration_seconds.to_i <= 0 && answered_at.present? && ended_at.present? && ended_at >= answered_at
            duration_seconds = (ended_at - answered_at).to_i
          end
        end

        if status == 'completed' && duration_seconds.nil? && answered_at.present? && ended_at.present? && ended_at >= answered_at
          duration_seconds = (ended_at - answered_at).to_i
        end

        if direction == 'outbound' && status == 'completed' && answered_at.blank?
          base_start = parsed[:started_at] || @correlated_session&.started_at || (ended_at && duration_seconds ? ended_at - duration_seconds.to_i.seconds : nil) || Time.current
          answered_at = base_start
        end

        [event, status, answered_at, ended_at, duration_seconds]
      end

      def build_ingestion_payload(parsed:, tracking_id:, direction:, event:, status:, answered_at:, ended_at:, duration_seconds:, occurred_at:)
        binding = @inbox.telephony_number_binding
        ingress_number = binding&.phone_number.presence || @inbox.channel&.phone_number
        call_ref = @correlated_session&.external_call_ref || "beeline:#{tracking_id}"

        provider_sid = if @correlated_session.blank? || @correlated_session.provider_call_sid.blank? || @correlated_session.provider_call_sid == tracking_id
                         tracking_id
                       else
                         @correlated_session.provider_call_sid
                       end

        dedupe_suffix = parsed[:event_id].presence ||
                        parsed[:sequence_number].presence ||
                        [status, (ended_at || answered_at || parsed[:started_at])&.to_i].compact.join(':')
        event_key = "beeline:#{@inbox.id}:#{tracking_id}:#{event}:#{dedupe_suffix}"

        metadata = {
          'chatwoot_account_id' => @inbox.account_id,
          'chatwoot_inbox_id' => @inbox.id,
          'source' => 'beeline_webhook',
          'beeline_format' => parsed[:format],
          'beeline_call_id' => parsed[:call_id],
          'beeline_ext_tracking_id' => parsed[:ext_tracking_id],
          'beeline_network_call_id' => parsed[:network_call_id],
          'beeline_xsi_event_type' => parsed[:xsi_event_type],
          'beeline_record_id' => parsed[:record_id],
          'beeline_native_webphone_correlation' => @correlation_status.to_s,
          'beeline_correlated_call_ref' => @correlated_session&.external_call_ref,
          'abonent_extension' => parsed[:operator_extension],
          'abonent_user_id' => parsed[:operator_user_id],
          'abonent_name' => parsed[:abonent_name],
          'remote_party_name' => parsed[:remote_name],
          'raw_event' => parsed[:raw_summary]
        }.compact
        metadata['beeline_answered_call_id'] = parsed[:call_id] if (status == 'in_progress' || answered_at.present?) && parsed[:call_id].present?

        payload = {
          'event_key' => event_key,
          'event' => event,
          'status' => status,
          'call_ref' => call_ref,
          'provider_call_sid' => provider_sid,
          'provider' => 'beeline',
          'account_id' => @inbox.account_id,
          'inbox_id' => @inbox.id,
          'number_ref' => binding&.number_ref,
          'ingress_number' => ingress_number,
          'direction' => direction,
          'from' => parsed[:from_number],
          'to' => parsed[:to_number],
          'started_at' => parsed[:started_at]&.iso8601,
          'answered_at' => answered_at&.iso8601,
          'ended_at' => ended_at&.iso8601,
          'occurred_at' => occurred_at&.iso8601,
          'duration' => duration_seconds,
          'recording_url' => parsed[:recording_url],
          'recording_ref' => parsed[:recording_url].presence || parsed[:record_id],
          'metadata' => metadata
        }
        payload['callee_leg_answered'] = true if direction == 'outbound' && status == 'completed'
        payload.compact
      end

      def answered_cache_key(tracking_id)
        "telephony:beeline:answered:#{@inbox.id}:#{tracking_id}"
      end

      def remember_answered_leg!(tracking_id, call_id, answered_at, operator_extension)
        return if tracking_id.blank?

        entry = {
          'call_id' => call_id,
          'answered_at' => (answered_at || Time.current).iso8601,
          'operator_extension' => operator_extension
        }.compact
        key = answered_cache_key(tracking_id)
        Rails.cache.write(key, entry, expires_in: ANSWERED_CACHE_TTL)
        $alfred&.with { |conn| conn.set(key, entry.to_json, ex: ANSWERED_CACHE_TTL.to_i) }
      rescue StandardError
        nil
      end

      def read_answered_leg(tracking_id)
        return nil if tracking_id.blank?

        key = answered_cache_key(tracking_id)
        cached = Rails.cache.read(key)
        return cached if cached.is_a?(Hash)

        raw = $alfred&.with { |conn| conn.get(key) }
        return JSON.parse(raw) if raw.present?

        nil
      rescue StandardError
        nil
      end

      def first_value(hash, *keys)
        return nil unless hash.is_a?(Hash)

        keys.each do |key|
          val = hash[key.to_s]
          return val.to_s.strip if val.present? && !val.is_a?(Hash) && !val.is_a?(Array)
        end
        nil
      end

      def extract_address_number(raw)
        return nil if raw.blank?

        cleaned = raw.to_s.strip
        cleaned = cleaned.sub(/\A(?:tel|sip|sips):/i, '')
        cleaned = cleaned.split('@').first.to_s
        cleaned = cleaned.split(';').first.to_s
        cleaned.strip.presence
      end

      def extract_operator_extension(raw_user_id)
        return nil if raw_user_id.blank?

        local_part = raw_user_id.to_s.strip.sub(/\A(?:sip|sips|tel):/i, '').split('@').first.to_s.strip
        return nil if local_part.blank?

        local_part
      end

      def internal_number?(value)
        return false if value.blank?

        str = value.to_s.strip
        return true if str.include?('@cloudpbx.beeline.kz')

        digits = str.gsub(/\D+/, '')
        digits.present? && digits.length <= 5
      end

      def normalize_party_number(raw, fallback: nil)
        candidate = extract_address_number(raw)
        return fallback if candidate.blank?
        return candidate if internal_number?(candidate) && candidate.gsub(/\D+/, '').length <= 5

        normalize_phone(candidate) || candidate
      end

      def normalize_phone(raw)
        return nil if raw.blank?

        cleaned = extract_address_number(raw)
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

      def parse_duration_seconds(merged, answered_at: nil, ended_at: nil)
        raw_ms = first_value(merged, 'duration_ms', 'durationMs')
        return (raw_ms.to_i / 1000) if raw_ms.present?

        raw_sec = first_value(merged, 'duration_seconds', 'durationSeconds', 'billsec', 'talk_time')
        return raw_sec.to_i if raw_sec.present?

        raw_duration = first_value(merged, 'duration', 'call_duration', 'callDuration')
        if raw_duration.present?
          val = raw_duration.to_i
          if answered_at.present? && ended_at.present? && ended_at >= answered_at
            span = (ended_at - answered_at).to_i
            return (val / 1000) if val >= 1000 && (val / 1000 - span).abs <= 5
          end
          # Beeline portal /v2/statistics returns startDate in epoch ms (13 digits) and duration in ms when large
          raw_start = first_value(merged, 'startDate', 'date')
          if raw_start.to_s.match?(/\A\d{13}\z/) && val >= 1000 && (val % 1000).zero? && merged.key?('startDate')
            return val / 1000
          end

          return val
        end

        if answered_at.present? && ended_at.present? && ended_at >= answered_at
          return (ended_at - answered_at).to_i
        end

        nil
      end

      def terminal_status?(status)
        Telephony::CallSession::TERMINAL_STATUSES.include?(status.to_s)
      end
    end
  end
end

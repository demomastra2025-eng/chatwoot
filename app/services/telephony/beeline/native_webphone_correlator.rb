# frozen_string_literal: true

module Telephony
  module Beeline
    class NativeWebphoneCorrelator
      CORRELATION_WINDOW = 15.minutes
      MAX_START_SKEW_SECONDS = 180
      SIBLING_BURST_WINDOW_SECONDS = 20

      def initialize(
        inbox:,
        direction:,
        contact_phone:,
        beeline_call_id: nil,
        ext_tracking_id: nil,
        operator_extension: nil,
        operator_user_id: nil,
        event_time: nil
      )
        @inbox = inbox
        @direction = direction.to_s
        @contact_phone = contact_phone.to_s
        @beeline_call_id = beeline_call_id.to_s.strip.presence
        @ext_tracking_id = ext_tracking_id.to_s.strip.presence
        @operator_extension = operator_extension.to_s.strip.presence
        @operator_user_id = operator_user_id.to_s.strip.presence
        @event_time = event_time || Time.current
      end

      def call
        return nil if @inbox.blank?

        already_linked = find_already_linked_session
        return already_linked if already_linked.present?

        return nil if @direction.blank?

        target_digits = comparable_phone_digits(@contact_phone)
        return nil if target_digits.blank?

        candidates = base_browser_candidates.select do |session|
          comparable_phone_digits(session_phone(session)) == target_digits
        end
        return nil if candidates.empty?

        select_best_candidate(candidates)
      end

      private

      def find_already_linked_session
        identifiers = [@ext_tracking_id, @beeline_call_id].compact.uniq
        return nil if identifiers.empty?

        scope = @inbox.account.telephony_call_sessions.where(inbox_id: @inbox.id)

        by_sid = scope.where(provider_call_sid: identifiers).order(id: :desc).to_a
        if by_sid.any?
          expanded = expand_with_logical_group(by_sid)
          winner = prefer_browser_session(expanded)
          transfer_provider_sid_if_needed!(from_sessions: by_sid, winner: winner)
          return winner
        end

        recent = scope.where('created_at >= ?', (@event_time || Time.current) - 12.hours).order(id: :desc).to_a
        matched = recent.select do |session|
          meta = session.metadata.is_a?(Hash) ? session.metadata : {}
          nested = meta['metadata'].is_a?(Hash) ? meta['metadata'] : {}
          known_ids = [
            session.provider_call_sid,
            meta['beeline_ext_tracking_id'],
            meta['beeline_call_id'],
            meta['beeline_cdr_ref'],
            nested['beeline_ext_tracking_id'],
            nested['beeline_call_id'],
            nested['beeline_cdr_ref'],
            meta.dig('provider_Correlation', 'ext_tracking_id'),
            meta.dig('provider_correlation', 'ext_tracking_id'),
            meta.dig('provider_correlation', 'beeline_call_id')
          ].compact.map(&:to_s)
          (known_ids & identifiers).any?
        end

        expanded = expand_with_logical_group(matched)
        winner = prefer_browser_session(expanded)
        transfer_provider_sid_if_needed!(from_sessions: matched, winner: winner)
        winner
      end

      def expand_with_logical_group(sessions)
        return [] if sessions.blank?

        sessions.flat_map do |session|
          if session.respond_to?(:logical_group_sessions)
            Array(session.logical_group_sessions)
          else
            [session]
          end
        end.uniq(&:id)
      end

      def transfer_provider_sid_if_needed!(from_sessions:, winner:)
        return if winner.blank? || from_sessions.blank?

        from_sessions.each do |session|
          next if session.id == winner.id
          next if session.provider_call_sid.blank?

          session.update_column(:provider_call_sid, nil)
        end
      end

      def prefer_browser_session(sessions)
        return nil if sessions.blank?

        browser = sessions.select do |s|
          ref = s.external_call_ref.to_s
          ref.start_with?('beeline:janus:', 'beeline:local:')
        end
        pool = browser.presence || sessions

        answered = pool.select do |s|
          !answered_by_other_operator?(s) &&
            (s.answered_at.present? || %w[connecting in_progress completed].include?(s.canonical_status.to_s))
        end
        return answered.first if answered.one?

        operator_matched = filter_by_operator(pool.reject { |s| answered_by_other_operator?(s) })
        return operator_matched.first if operator_matched.one?

        select_winner_from_group(pool)
      end

      def answered_by_other_operator?(session)
        meta = session.metadata.is_a?(Hash) ? session.metadata : {}
        nested = meta['metadata'].is_a?(Hash) ? meta['metadata'] : {}
        [session.end_reason, meta['end_reason'], nested['end_reason']].any? do |val|
          val.to_s == Telephony::SiblingLegCloser::END_REASON
        end
      end

      def base_browser_candidates
        reference_time = @event_time || Time.current
        window_start = reference_time - CORRELATION_WINDOW
        window_end = reference_time + CORRELATION_WINDOW

        scope = @inbox.account.telephony_call_sessions
                      .where(inbox_id: @inbox.id, direction: @direction)
                      .where('started_at >= ? AND started_at <= ?', window_start, window_end)

        if @direction == 'inbound'
          scope = scope.where("external_call_ref LIKE 'beeline:janus:%'")
        else
          scope = scope.where("external_call_ref LIKE 'beeline:local:%' OR external_call_ref LIKE 'beeline:janus:%'")
        end

        scope.order(started_at: :desc, id: :desc).to_a
      end

      def select_best_candidate(candidates)
        with_skew = candidates.filter_map do |session|
          skew = start_distance(session)
          next if skew > MAX_START_SKEW_SECONDS

          [session, skew]
        end
        return nil if with_skew.empty?

        in_window_sessions = with_skew.map(&:first)
        return in_window_sessions.first if in_window_sessions.one?

        operator_matched = filter_by_operator(in_window_sessions)
        return operator_matched.first if operator_matched.one?

        pool = operator_matched.presence || in_window_sessions
        winner = select_winner_from_group(pool)
        return winner if winner.present?

        sorted = with_skew.sort_by { |session, skew| [skew, session.id] }
        best_session, best_skew = sorted.first
        second_skew = sorted.second&.last
        return best_session if second_skew.nil? || (second_skew - best_skew) >= 10

        nil
      end

      def filter_by_operator(sessions)
        return [] if @operator_extension.blank? && @operator_user_id.blank?

        target_tokens = [@operator_extension, @operator_user_id, @operator_user_id&.split('@')&.first]
                        .compact.map { |v| v.to_s.strip.downcase }.reject(&:blank?).uniq
        return [] if target_tokens.empty?

        sessions.select do |session|
          session_tokens = extract_operator_tokens(session)
          (session_tokens & target_tokens).any?
        end
      end

      def extract_operator_tokens(session)
        meta = session.metadata.is_a?(Hash) ? session.metadata : {}
        route_meta = meta['metadata'].is_a?(Hash) ? meta['metadata'] : {}
        claim_meta = meta['operator_claim'].is_a?(Hash) ? meta['operator_claim'] : {}

        raw_values = [
          meta['sip_username'],
          meta['operator_extension'],
          meta['internal_extension'],
          meta['target_extension'],
          meta['extension'],
          meta['abonent_extension'],
          meta['abonent_user_id'],
          claim_meta['sip_username'],
          claim_meta['internal_extension'],
          route_meta['sip_username'],
          route_meta['target_sip_username'],
          route_meta['operator_internal_extension'],
          route_meta['internal_extension'],
          route_meta['target_extension'],
          route_meta['target_aor'],
          route_meta['operator_agent_aor']
        ]

        profile_id = route_meta['telephony_sip_profile_id'].presence ||
                     route_meta['target_sip_profile_id'].presence ||
                     meta['telephony_sip_profile_id'].presence ||
                     meta['target_sip_profile_id'].presence
        if profile_id.present? && @inbox.present?
          profile = @inbox.telephony_sip_profiles.find_by(id: profile_id)
          if profile.present?
            raw_values << profile.sip_username
            raw_values << profile.internal_extension
          end
        end

        raw_values.compact.flat_map do |val|
          cleaned = val.to_s.strip.sub(/\A(?:sip|sips|tel):/i, '').downcase
          [cleaned, cleaned.split('@').first]
        end.reject(&:blank?).uniq
      end

      def select_winner_from_group(sessions)
        return sessions.first if sessions.one?

        answered = sessions.select do |s|
          !answered_by_other_operator?(s) &&
            (s.answered_at.present? || %w[connecting in_progress completed].include?(s.canonical_status.to_s))
        end
        return answered.first if answered.one?

        claimed = sessions.select do |s|
          meta = s.metadata.is_a?(Hash) ? s.metadata : {}
          meta['operator_claim'].is_a?(Hash) && meta['operator_claim']['user_id'].present?
        end
        return claimed.first if claimed.one?

        if sibling_burst?(sessions)
          ordered = sessions.sort_by { |s| [(s.started_at || s.created_at).to_f, s.id.to_i] }
          canonical = ordered.find do |s|
            meta = s.metadata.is_a?(Hash) ? s.metadata : {}
            route_meta = meta['metadata'].is_a?(Hash) ? meta['metadata'] : {}
            root_ref = meta['logical_call_root_ref'].presence ||
                       route_meta['logical_call_root_ref'].presence ||
                       meta['logical_call_group_ref'].presence ||
                       route_meta['logical_call_group_ref'].presence ||
                       (s.respond_to?(:logical_call_group_ref) ? s.logical_call_group_ref : nil)
            root_ref.present? && root_ref.to_s == s.external_call_ref.to_s
          end
          return canonical if canonical.present?

          return ordered.first
        end

        nil
      end

      def sibling_burst?(sessions)
        group_refs = sessions.map { |s| Telephony::SiblingLegGrouping.group_ref(s) }.compact.uniq
        return true if group_refs.one?

        timestamps = sessions.filter_map { |s| (s.started_at || s.created_at)&.to_f }
        return false if timestamps.empty?

        (timestamps.max - timestamps.min) <= SIBLING_BURST_WINDOW_SECONDS
      end

      def start_distance(session)
        started_at = session.started_at || session.created_at
        return Float::INFINITY if started_at.blank?

        ((@event_time || Time.current) - started_at).abs
      end

      def session_phone(session)
        meta = session.metadata.is_a?(Hash) ? session.metadata : {}
        external = session.direction.to_s == 'outbound' ? session.to_number : session.from_number
        external.presence ||
          session.from_number.presence ||
          session.to_number.presence ||
          meta['caller_number'].presence ||
          meta['callee_number'].presence ||
          meta['from'].presence ||
          meta['to'].presence
      end

      def comparable_phone_digits(raw_phone)
        digits = raw_phone.to_s.gsub(/\D+/, '')
        return nil if digits.length < 7

        digits.length > 10 ? digits[-10, 10] : digits
      end
    end
  end
end

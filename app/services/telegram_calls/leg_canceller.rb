class TelegramCalls::LegCanceller
  class << self
    def cancel_if_disabled!(account:, leg_id:)
      return false if TelegramCalls::Config.enabled_for?(account)

      cancel_single_leg!(leg_id: leg_id, status_text: '⚪ Звонки через Telegram-бота отключены')
      true
    end

    def cancel_for_source!(source_type:, account_id:, source_call_ref:, status_text:, **options)
      group = TelegramCalls::Registry.fetch_source_group(
        source_type: source_type, account_id: account_id, source_call_ref: source_call_ref
      )
      return if group.blank?

      preserved_id = resolve_preserved_leg_id(
        source_type: source_type, account_id: account_id, source_call_ref: source_call_ref, options: options
      )
      cancel_group_legs!(group['leg_ids'], preserved_id: preserved_id, status_text: status_text)
    rescue StandardError => e
      Rails.logger.warn("TELEGRAM_CALLS_CANCEL_LEGS_ERROR ref=#{source_call_ref} error=#{e.message}")
    end

    def cancel_voip_on_accept!(call, source_type:, agent:)
      cancel_for_source!(
        source_type: source_type,
        account_id: call.account_id,
        source_call_ref: call.id.to_s,
        status_text: "ℹ️ Принял(а): #{ERB::Util.html_escape(agent&.name.to_s)}"
      )
    end

    def cancel_voip_on_end!(call, source_type:)
      cancel_for_source!(
        source_type: source_type,
        account_id: call.account_id,
        source_call_ref: call.id.to_s,
        status_text: '✅ <b>Звонок завершён</b>',
        include_claimed: true
      )
    end

    def cancel_single_leg!(leg_id:, status_text:, decline_sip: false)
      leg = TelegramCalls::Registry.fetch_leg(leg_id)
      return nil if leg.blank? || leg['status'].in?(%w[cancelled ended])

      term_res = terminate_gateway_leg(leg_id, leg, decline_sip: decline_sip)
      TelegramCalls::Registry.update_leg!(leg_id, 'status' => 'cancelled')
      update_card_status(leg, status_text, state: :ended)
      term_res
    end

    def update_card_status(leg, status_text, state:)
      return if leg['chat_id'].blank? || leg['message_id'].blank?

      text = TelegramCalls::CallerCardBuilder.build_text(meta: leg, status_line: status_text)
      markup = TelegramCalls::BotClient.call_inline_keyboard(
        leg_id: leg['leg_id'], conversation_url: leg['conversation_url'], state: state
      )
      TelegramCalls::BotClient.new.edit_message_text(
        chat_id: leg['chat_id'], message_id: leg['message_id'], text: text, reply_markup: markup
      )
    end

    private

    def resolve_preserved_leg_id(source_type:, account_id:, source_call_ref:, options:)
      return options[:except_leg_id].to_s if options[:except_leg_id].present?
      return nil if options[:include_claimed]

      claim = TelegramCalls::Registry.fetch_claim(
        source_type: source_type, account_id: account_id, source_call_ref: source_call_ref
      )
      claim&.dig('leg_id')
    end

    def cancel_group_legs!(leg_ids, preserved_id:, status_text:)
      Array.wrap(leg_ids).each do |leg_id|
        next if preserved_id.present? && leg_id.to_s == preserved_id.to_s

        cancel_single_leg!(leg_id: leg_id, status_text: status_text)
      end
    end

    def terminate_gateway_leg(leg_id, leg, decline_sip:)
      client = TelegramCalls::GatewaySoftphoneClient.new
      return nil unless client.configured?

      term_res = leg['voice_ring_started'] ? client.terminate_leg!(leg_id: leg_id, reason: 'cancelled_elsewhere') : nil
      if decline_sip && leg['line_key'].present?
        client.decline_sip_call!(
          line_key: leg['line_key'], janus_call_id: leg['janus_call_id'], call_ref: leg['source_call_ref']
        )
      end
      term_res
    rescue StandardError => e
      Rails.logger.info("TELEGRAM_CALLS_TERMINATE_LEG_SKIP leg=#{leg_id} error=#{e.message}")
      nil
    end
  end
end

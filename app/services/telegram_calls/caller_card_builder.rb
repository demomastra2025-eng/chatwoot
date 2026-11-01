class TelegramCalls::CallerCardBuilder
  PROVIDER_LABELS = {
    'wazo' => 'Altel / Wazo',
    'sipuni' => 'Sipuni',
    'beeline' => 'Beeline',
    'binotel' => 'Binotel',
    'asterisk_analog' => 'Asterisk SIP'
  }.freeze

  class << self
    def build_text(meta:, status_line:)
      data = meta.deep_stringify_keys
      lines = [header_line(data)]
      lines << "👤 Клиент: <b>#{esc(data['caller_title'].presence || 'Неизвестный контакт')}</b>"
      lines << "📱 Номер: <code>#{esc(data['caller_phone'])}</code>" if data['caller_phone'].present?
      lines << "📥 Канал: #{esc(data['inbox_name'])}" if data['inbox_name'].present?
      lines << "💼 Сделка: #{esc(data['crm_summary'])}" if data['crm_summary'].present?
      lines << ''
      lines << status_line
      lines.join("\n")
    end

    def crm_summary_for_contact(account:, contact:)
      return nil if account.blank? || contact.blank?

      deal = Crm::Deal.joins(:deal_contacts)
                      .where(account_id: account.id, archived_at: nil, closed_at: nil, crm_deal_contacts: { contact_id: contact.id })
                      .includes(:stage)
                      .order(updated_at: :desc)
                      .first
      return nil unless deal

      format_deal_summary(deal)
    rescue StandardError
      nil
    end

    def provider_label(provider)
      PROVIDER_LABELS[provider.to_s] || provider.to_s.humanize.presence || 'SIP'
    end

    private

    def header_line(data)
      case data['source_type']
      when 'whatsapp'
        '🟢 <b>Звонок WhatsApp Business</b>'
      when 'telegram_personal'
        '🔵 <b>Звонок Telegram (личный номер)</b>'
      when 'telephony_sip_outbound'
        "📤 <b>Исходящий звонок · #{esc(data['provider_label'] || 'Телефония')}</b>"
      else
        "📞 <b>Звонок · #{esc(data['provider_label'] || 'Телефония')}</b>"
      end
    end

    def format_deal_summary(deal)
      parts = [deal.title.to_s.strip]
      parts << deal.stage.name if deal.stage&.name.present?
      if deal.amount_minor.to_i.positive?
        whole = (deal.amount_minor.to_f / 100.0).round
        currency = deal.currency.presence || 'KZT'
        parts << "#{whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse} #{currency}"
      end
      parts.compact.join(' · ')
    end

    def esc(text)
      ERB::Util.html_escape(text.to_s)
    end
  end
end

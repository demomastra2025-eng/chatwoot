# frozen_string_literal: true

# The state of the connection to OpenRouter in plain words, for the first tab of the «Модели ИИ» page: is the key working,
# how much money is left, what the models cost in the last 24 hours, is the catalog of models loaded. It reads the hash
# of Llm::OpenRouterDiagnostics (the technical details stay in the block «Для разработчика») and never touches a key.
#
#   state = SuperAdmin::AiConnectionState.new(Llm::OpenRouterDiagnostics.call)
#   state.key_text    # => "Рабочий"
#   state.balance_text # => "$12,50 осталось"
class SuperAdmin::AiConnectionState
  SCOPE = 'super_admin.app_config.captain'
  BAD_KEY_STATES = %w[missing invalid expired credits_exhausted key_limit_exhausted unavailable].freeze
  # A cost below this is shown as «меньше цента»: «$0,00» would read as «nothing was spent»
  CENT = 0.01

  def initialize(diagnostics)
    diagnostics = diagnostics.to_h
    @key = diagnostics[:key_status].to_h
    @health = @key[:health].to_h
    @credits = @health[:credits].to_h
    @key_details = @health[:key].to_h
    @catalog = diagnostics[:catalog].to_h
    @runtime = diagnostics[:runtime].to_h
  end

  # missing, not_checked, valid, invalid, expired, credits_exhausted, ...
  def key_state
    @key_state ||= @health[:status].presence || (@key[:effective_configured] ? 'not_checked' : 'missing')
  end

  def key_text
    I18n.t("#{SCOPE}.diagnostics.statuses.key.#{key_state}", default: key_state.to_s)
  end

  # teal: works; amber: not checked yet; ruby: the models do not work
  def key_tone
    return 'ruby' if BAD_KEY_STATES.include?(key_state)

    key_state == 'valid' ? 'teal' : 'amber'
  end

  def key_note
    case key_state
    when 'missing' then I18n.t("#{SCOPE}.connection.key_missing")
    when 'not_checked' then I18n.t("#{SCOPE}.connection.key_not_checked")
    else [(I18n.t("#{SCOPE}.connection.key_ok") if key_state == 'valid'), @health[:error].presence, checked_note].compact.join(' ')
    end
  end

  def balance?
    @credits[:status] == 'available'
  end

  def balance_text
    return I18n.t("#{SCOPE}.connection.balance_available", amount: SuperAdmin::DisplayHelper.format_usd(@credits[:remaining_credits].to_f)) if balance?

    I18n.t("#{SCOPE}.connection.balance_unknown")
  end

  def balance_note
    return limit_note || '' if balance?
    return I18n.t("#{SCOPE}.connection.balance_need_key") if @credits[:status].blank? || @credits[:status] == 'management_key_required'

    @credits[:error].presence || I18n.t("#{SCOPE}.connection.balance_error")
  end

  def spend_text
    cost = @runtime[:estimated_cost].to_f
    return "< #{SuperAdmin::DisplayHelper.format_usd(CENT)}" if cost.positive? && cost < CENT

    SuperAdmin::DisplayHelper.format_usd(cost)
  end

  def spend_note
    requests = @runtime[:request_count].to_i
    I18n.t("#{SCOPE}.connection.spend_note", count: requests, errors: SuperAdmin::DisplayHelper.format_number(@runtime[:error_count].to_i))
  end

  # The catalog of OpenRouter was loaded (the built-in list is the one in use otherwise)
  def catalog_loaded?
    @catalog[:last_refreshed_at].present? && !@catalog[:using_fallback]
  end

  def catalog_refreshed_at
    @catalog[:last_refreshed_at]
  end

  def catalog_models
    @catalog[:total_models].to_i
  end

  def catalog_text
    return I18n.t("#{SCOPE}.connection.catalog_not_loaded") unless catalog_loaded?

    I18n.t("#{SCOPE}.connection.catalog_loaded", time: SuperAdmin::DisplayHelper.format_time(@catalog[:last_refreshed_at]))
  end

  def catalog_note
    return I18n.t("#{SCOPE}.connection.catalog_note_fallback", count: catalog_models) unless catalog_loaded?

    I18n.t("#{SCOPE}.connection.catalog_note_loaded", count: catalog_models)
  end

  def catalog_error
    @catalog[:last_refresh_error].presence
  end

  # The key is stored: without it nothing but the built-in models is on the lists
  def key_set?
    @key[:effective_configured] == true
  end

  private

  def checked_note
    checked_at = @health[:checked_at]
    return if checked_at.blank?

    I18n.t("#{SCOPE}.connection.checked_at", time: SuperAdmin::DisplayHelper.format_time(checked_at))
  end

  def limit_note
    return if @key_details[:limit].blank?

    I18n.t("#{SCOPE}.connection.balance_limit", limit: SuperAdmin::DisplayHelper.format_usd(@key_details[:limit].to_f),
                                                left: SuperAdmin::DisplayHelper.format_usd(@key_details[:limit_remaining].to_f))
  end
end

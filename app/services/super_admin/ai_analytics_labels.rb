# frozen_string_literal: true

# The names the chips of «AI-аналитика» show for the functions, models and providers of the AI events: Russian names
# for the functions of the platform, the display name of a model or provider from the catalogue. A key nobody described
# is shown as it is (it is data of the event, not text of the platform).
module SuperAdmin::AiAnalyticsLabels
  module_function

  # kind: :features, :models or :providers
  def label(kind, key)
    case kind.to_sym
    when :features then feature(key)
    when :models then model(key)
    else provider(key)
    end
  end

  def feature(key)
    I18n.t("super_admin.ai_analytics.feature_names.#{key}", default: key.to_s)
  end

  def model(key)
    name = key.to_s
    Llm::Models.model_config(name).to_h['display_name'].presence || name
  rescue StandardError
    name
  end

  def provider(key)
    name = key.to_s
    Llm::Models.provider_config(name).to_h['display_name'].presence || name
  rescue StandardError
    name
  end
end

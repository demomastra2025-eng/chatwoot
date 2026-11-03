# frozen_string_literal: true

# What one change of a save of the «Модели ИИ» page is, in words, for the message after the save:
#
#   SuperAdmin::AiModelsChangeText.new(change).to_s # => "Расшифровка голоса: GPT Audio Mini → встроенная"
#
# `change` is a SuperAdmin::AiModelsForm::Change. A secret is never quoted (only that it was renewed), a list of models
# is told by its size («3 → 5»; a blank list is the platform's recommended one: «рекомендуемый (5)»), the rules by a phrase.
class SuperAdmin::AiModelsChangeText
  SCOPE = 'super_admin.app_config.captain.form'

  def initialize(change)
    @change = change
  end

  def to_s
    title = SuperAdmin::AppConfigLabels.title(@change.key, SuperAdmin::InstallationConfigs.definitions[@change.key])
    return I18n.t("#{SCOPE}.changed.secret", title: title) if @change.secret

    "#{title}: #{detail}"
  end

  private

  def detail
    case @change.key
    when Llm::InstallationModelConfig::ALLOWLIST_CONFIG then list_change
    when Captain::Assistant::GLOBAL_SYSTEM_PROMPTS_INSTALLATION_CONFIG then I18n.t("#{SCOPE}.changed.prompts")
    else single_change
    end
  end

  def single_change
    return "#{model_text(@change.old)} → #{model_text(@change.new)}" if SuperAdmin::AiModelsPage::MODEL_KEYS.include?(@change.key)

    @change.new.to_s.presence ? I18n.t("#{SCOPE}.changed.value") : I18n.t("#{SCOPE}.changed.cleared")
  end

  def list_change
    I18n.t("#{SCOPE}.changed.list", before: list_size_text(@change.old), after: list_size_text(@change.new))
  end

  # «3», or «рекомендуемый (5)» for a blank list: the platform shows its recommended models then
  def list_size_text(raw)
    models = Llm::InstallationModelConfig.parse_models(raw).to_a
    return models.size.to_s if models.any?

    I18n.t("#{SCOPE}.changed.list_recommended", count: Llm::Models::DEFAULT_CURATED_MODELS.size)
  end

  def model_text(model_id)
    name = SuperAdmin::AiModelOptions.name_of(model_id)
    return name if name.present?

    defaults = SuperAdmin::AiModelsPage.new(keys: [], values: {}, definitions: {}, masked_keys: [])
    return I18n.t('super_admin.app_config.captain.models.not_configured') if defaults.default_for(@change.key).blank?

    I18n.t("#{SCOPE}.changed.builtin")
  end
end

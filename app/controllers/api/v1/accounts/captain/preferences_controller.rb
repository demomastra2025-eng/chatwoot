class Api::V1::Accounts::Captain::PreferencesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action :authorize_account_update, only: [:update]

  def show
    render json: preferences_payload
  end

  def update
    params_to_update = captain_params
    @current_account.captain_models = params_to_update[:captain_models] if params_to_update[:captain_models]
    @current_account.captain_features = params_to_update[:captain_features] if params_to_update[:captain_features]
    @current_account.captain_runtime = params_to_update[:captain_runtime] if params_to_update[:captain_runtime]
    @current_account.save!

    render json: preferences_payload
  end

  private

  def preferences_payload
    {
      providers: Llm::Models.providers,
      models: Llm::Models.models,
      features: features_with_account_preferences,
      runtime: runtime_with_account_preferences,
      runtime_metadata: Llm::ModelRegistryService.runtime_metadata(account: Current.account)
    }
  end

  def authorize_account_update
    authorize @current_account, :update?
  end

  def captain_params
    permitted = {}
    permitted[:captain_models] = merged_captain_models if params[:captain_models].present?
    permitted[:captain_features] = merged_captain_features if params[:captain_features].present?
    permitted[:captain_runtime] = merged_captain_runtime if params[:captain_runtime].present?
    permitted
  end

  def merged_captain_models
    existing_models = @current_account.captain_models || {}
    existing_models.merge(permitted_captain_models)
  end

  def merged_captain_features
    existing_features = @current_account.captain_features || {}
    existing_features.merge(permitted_captain_features)
  end

  def merged_captain_runtime
    existing_runtime = @current_account.captain_runtime || {}
    existing_runtime.merge(permitted_captain_runtime)
  end

  def permitted_captain_models
    params.require(:captain_models).permit(
      :editor, :assistant, :copilot, :label_suggestion,
      :audio_transcription, :help_center_search
    ).to_h.stringify_keys
  end

  def permitted_captain_features
    params.require(:captain_features).permit(
      :editor, :assistant, :copilot, :label_suggestion,
      :audio_transcription, :help_center_search
    ).to_h.stringify_keys
  end

  def permitted_captain_runtime
    params.require(:captain_runtime).permit(
      :assistant_thinking_effort,
      :copilot_thinking_effort,
      :assistant_moderation,
      :copilot_moderation
    ).to_h.stringify_keys
  end

  def features_with_account_preferences
    preferences = Current.account.captain_preferences
    account_features = preferences[:features] || {}

    Llm::Models.feature_keys.index_with do |feature_key|
      config = Llm::Models.feature_config(feature_key)
      selected_model = Llm::Config.model_for(feature: feature_key, account: Current.account)
      config.merge(
        enabled: account_features[feature_key] == true,
        selected: selected_model,
        selected_provider: Llm::Config.provider_for_model(selected_model),
        selected_supports_thinking: Llm::Models.supports_thinking?(selected_model),
        selected_known_to_registry: Llm::Models.registry_known?(selected_model)
      )
    end
  end

  def runtime_with_account_preferences
    Current.account.captain_preferences[:runtime] || {}
  end
end

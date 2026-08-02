# rubocop:disable Metrics/ClassLength
class Api::V1::Accounts::Captain::FishVoicesController < Api::V1::Accounts::BaseController
  ProviderModelInvalidError = Class.new(StandardError)
  MAX_UPLOAD_SIZE = 20.megabytes
  ALLOWED_EXTENSIONS = %w[.wav .mp3 .m4a .ogg .opus].freeze
  DELETING_STATE = 'deleting'.freeze

  before_action :authorize_voice_management!
  before_action :set_fish_voice, only: [:show, :destroy]

  def index
    render json: { payload: fish_voices.map { |voice| voice_payload(voice) } }
  end

  def show
    render json: { payload: refreshed_voice_payload }
  rescue Telephony::AiVoice::FishAudioClient::ConfigurationError
    render json: { error: 'fish_voice_not_configured' }, status: :service_unavailable
  rescue ProviderModelInvalidError
    render_provider_error('fish_voice_invalid_response')
  rescue Telephony::AiVoice::FishAudioClient::NotFoundError => e
    log_provider_error('show', e)
    mark_provider_missing!
    render json: { payload: voice_payload(@fish_voice).merge(provider_missing: true) }
  rescue Telephony::AiVoice::FishAudioClient::Error => e
    log_provider_error('show', e)
    render_provider_error('fish_voice_refresh_failed')
  end

  def create
    validation_error = validate_create_request
    return render json: { error: validation_error }, status: :unprocessable_content if validation_error

    render json: { payload: voice_payload(create_fish_voice!) }, status: :created
  rescue ProviderModelInvalidError
    render_provider_error('fish_voice_invalid_response')
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn "[FISH VOICE] registry create failed account=#{Current.account.id}: #{e.record.errors.full_messages.join(', ')}"
    render json: { error: 'fish_voice_registry_failed' }, status: :unprocessable_content
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn "[FISH VOICE] registry persistence failed account=#{Current.account.id} error=#{e.class.name}"
    render json: { error: 'fish_voice_registry_failed' }, status: :service_unavailable
  rescue Telephony::AiVoice::FishAudioClient::ConfigurationError
    render json: { error: 'fish_voice_not_configured' }, status: :service_unavailable
  rescue Telephony::AiVoice::FishAudioClient::Error => e
    log_provider_error('create', e)
    render_provider_error('fish_voice_create_failed')
  end

  def destroy
    in_use, previous_state = mark_voice_deleting!
    return render json: { error: 'fish_voice_in_use' }, status: :unprocessable_content if in_use

    delete_provider_model_or_ignore_missing(@fish_voice.provider_model_id)
    with_account_registry_lock do
      @fish_voice.reload
      @fish_voice.destroy!
    end
    head :no_content
  rescue Telephony::AiVoice::FishAudioClient::ConfigurationError
    restore_voice_state(previous_state)
    render json: { error: 'fish_voice_not_configured' }, status: :service_unavailable
  rescue Telephony::AiVoice::FishAudioClient::Error => e
    restore_voice_state(previous_state)
    log_provider_error('destroy', e)
    render_provider_error('fish_voice_delete_failed')
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn "[FISH VOICE] registry delete failed account=#{Current.account.id} error=#{e.class.name}"
    render json: { error: 'fish_voice_registry_failed' }, status: :service_unavailable
  end

  private

  def authorize_voice_management!
    authorize Captain::Assistant, :update?
  end

  def fish_voices
    @fish_voices ||= Telephony::AiVoice::FishVoice.where(account: Current.account).recent_first
  end

  def set_fish_voice
    @fish_voice = fish_voices.find(params[:id])
  end

  def fish_client
    @fish_client ||= Telephony::AiVoice::FishAudioClient.new
  end

  def create_params
    @create_params ||= params.permit(:title, :voice, :transcript, :consent_confirmed)
  end

  def create_fish_voice!
    provider_model = validated_provider_model!(create_provider_model, compensate: true)
    provider_model_id = provider_model.fetch('_id')
    with_provider_model_registry_lock(provider_model_id) { register_fish_voice!(provider_model) }
  rescue ActiveRecord::RecordNotUnique
    raise
  rescue ActiveRecord::ActiveRecordError
    safely_delete_unregistered_provider_model(provider_model_id)
    raise
  end

  def create_provider_model
    fish_client.create_model(
      title: create_params[:title].strip,
      upload: create_params[:voice],
      transcript: create_params[:transcript].presence
    )
  end

  def validated_provider_model!(provider_model, expected_id: nil, compensate: false)
    provider_model_id = provider_model_id_from(provider_model)
    return provider_model.merge('_id' => provider_model_id) if valid_provider_model?(provider_model, provider_model_id, expected_id)

    safely_delete_unregistered_provider_model(provider_model_id) if compensate && provider_model_id.present?
    Rails.logger.warn "[FISH VOICE] invalid provider response model_id_present=#{provider_model_id.present?}"
    raise ProviderModelInvalidError
  end

  def provider_model_id_from(provider_model)
    return unless provider_model.is_a?(Hash)

    raw_id = provider_model['_id'].presence || provider_model['id'].presence
    raw_id.strip if raw_id.is_a?(String) && raw_id.strip.present?
  end

  def optional_string?(value)
    value.nil? || value.is_a?(String)
  end

  def valid_provider_model?(provider_model, provider_model_id, expected_id)
    return false unless provider_model.is_a?(Hash) && provider_model_id.present?
    return false unless provider_model['visibility'] == 'private'
    return false unless optional_string?(provider_model['title']) && optional_string?(provider_model['state'])

    expected_id.nil? || provider_model_id == expected_id
  end

  def register_fish_voice!(provider_model)
    fish_voices.create!(
      created_by: Current.user,
      provider_model_id: provider_model.fetch('_id'),
      title: provider_model['title'].presence || create_params[:title].strip,
      state: provider_model['state'].presence || 'created',
      visibility: provider_model['visibility']
    )
  end

  def safely_delete_provider_model(provider_model_id)
    return if provider_model_id.blank?

    fish_client.delete_model(provider_model_id)
  rescue Telephony::AiVoice::FishAudioClient::Error => e
    log_provider_error('create_compensation', e)
  end

  def safely_delete_unregistered_provider_model(provider_model_id)
    return if provider_model_id.blank?

    with_provider_model_registry_lock(provider_model_id) do
      safely_delete_provider_model(provider_model_id) unless provider_model_registered?(provider_model_id)
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn "[FISH VOICE] compensation skipped: registry unavailable error=#{e.class.name}"
  end

  def provider_model_registered?(provider_model_id)
    Telephony::AiVoice::FishVoice.exists?(provider_model_id: provider_model_id)
  end

  def with_provider_model_registry_lock(provider_model_id, &)
    Telephony::AiVoice::FishVoice.with_provider_model_lock(provider_model_id, &)
  end

  def with_account_registry_lock(&)
    Telephony::AiVoice::FishVoice.with_account_lock(Current.account, &)
  end

  def refreshed_voice_payload
    with_account_registry_lock do
      @fish_voice.reload
      next voice_payload(@fish_voice) if @fish_voice.state == DELETING_STATE

      refresh_voice_from_provider!
      voice_payload(@fish_voice)
    end
  end

  def refresh_voice_from_provider!
    provider_model = validated_provider_model!(
      fish_client.model(@fish_voice.provider_model_id),
      expected_id: @fish_voice.provider_model_id
    )
    @fish_voice.update!(
      title: provider_model['title'].presence || @fish_voice.title,
      state: provider_model['state'].presence || @fish_voice.state,
      visibility: provider_model['visibility']
    )
  end

  def mark_voice_deleting!
    with_account_registry_lock do
      @fish_voice.reload
      next [true, nil] if @fish_voice.selected_assistants.exists?

      previous_state = @fish_voice.state
      @fish_voice.update!(state: DELETING_STATE) unless previous_state == DELETING_STATE
      [false, previous_state]
    end
  end

  def restore_voice_state(previous_state)
    return if previous_state.blank? || !@fish_voice.persisted?

    with_account_registry_lock do
      @fish_voice.reload
      @fish_voice.update!(state: previous_state) if @fish_voice.state == DELETING_STATE
    end
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn "[FISH VOICE] state restore failed account=#{Current.account.id} error=#{e.class.name}"
  end

  def mark_provider_missing!
    with_account_registry_lock do
      @fish_voice.reload
      @fish_voice.update!(state: 'failed') unless @fish_voice.state == DELETING_STATE
    end
  end

  def delete_provider_model_or_ignore_missing(provider_model_id)
    fish_client.delete_model(provider_model_id)
  rescue Telephony::AiVoice::FishAudioClient::NotFoundError
    nil
  end

  def validate_create_request
    return 'fish_voice_consent_required' unless ActiveModel::Type::Boolean.new.cast(create_params[:consent_confirmed])
    return 'fish_voice_title_required' if create_params[:title].to_s.strip.blank?
    return 'fish_voice_title_too_long' if create_params[:title].to_s.strip.length > 100

    upload = create_params[:voice]
    return 'fish_voice_audio_required' unless upload.is_a?(ActionDispatch::Http::UploadedFile)
    return 'fish_voice_audio_too_large' if upload.size.to_i > MAX_UPLOAD_SIZE
    return 'fish_voice_audio_invalid' unless allowed_audio_upload?(upload)
  end

  def allowed_audio_upload?(upload)
    extension = File.extname(upload.original_filename.to_s).downcase
    upload.content_type.to_s.start_with?('audio/') && ALLOWED_EXTENSIONS.include?(extension)
  end

  def voice_payload(voice)
    selected_count = voice.selected_assistants_count
    {
      id: voice.id,
      reference_id: voice.provider_model_id,
      title: voice.title,
      state: voice.state,
      visibility: voice.visibility,
      in_use: selected_count.positive?,
      selected_assistants_count: selected_count,
      created_at: voice.created_at
    }
  end

  def render_provider_error(code)
    render json: { error: code }, status: :bad_gateway
  end

  def log_provider_error(action, error)
    Rails.logger.warn(
      "[FISH VOICE] #{action} failed account=#{Current.account.id} status=#{error.http_status || 'network'} error=#{error.class.name}"
    )
  end
end
# rubocop:enable Metrics/ClassLength

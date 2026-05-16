class Api::V1::Accounts::Telephony::CallsController < Api::V1::Accounts::Telephony::BaseController
  before_action :set_call_session, only: [:show, :recording]

  def index
    sessions = Current.account.telephony_call_sessions.includes(:contact, :conversation, :inbox, :number_binding, :agent_binding).recent
    sessions = sessions.where(inbox_id: params[:inbox_id]) if params[:inbox_id].present?
    sessions = sessions.where(status: params[:status]) if params[:status].present?
    sessions = sessions.where(direction: params[:direction]) if params[:direction].present?
    sessions = sessions.limit(limit_param)

    render_payload(
      sessions.map(&:to_telephony_h),
      meta: { count: sessions.size }
    )
  end

  def show
    payload = @call_session.to_telephony_h
    payload[:recording_url] = recording_url_for_call_session if recording_available?
    payload[:bridge] = calls_service.find_remote(@call_session.external_call_ref) if parse_boolean(params[:include_bridge], default: false)
    render_payload(payload)
  end

  def recording
    authorize_recording_access!

    if external_recording_url.present?
      redirect_to external_recording_url, allow_other_host: true
      return
    end

    path = recording_file_path
    raise ActiveRecord::RecordNotFound, 'Recording could not be found' if path.blank?

    send_file(
      path,
      type: recording_content_type,
      disposition: 'inline',
      filename: File.basename(path),
      x_sendfile: true
    )
  end

  def outbound
    contact = Current.account.contacts.find(params.require(:contact_id))
    inbox = Current.user.assigned_inboxes.where(account_id: Current.account.id, channel_type: 'Channel::Voice').find(params.require(:inbox_id))

    authorize contact, :show?
    authorize inbox, :show?

    result = Voice::OutboundCallBuilder.perform!(
      account: Current.account,
      inbox: inbox,
      user: Current.user,
      contact: contact
    )

    render json: {
      conversation_id: result[:conversation].display_id,
      inbox_id: inbox.id,
      call_sid: result[:call_sid],
      conference_sid: result[:conversation].additional_attributes['conference_sid'],
      call_session: result[:call_session]&.to_telephony_h
    }, status: :created
  end

  private

  def set_call_session
    @call_session = Current.account.telephony_call_sessions.find_by!(external_call_ref: params[:call_ref])
  end

  def authorize_recording_access!
    if @call_session.conversation.present?
      authorize @call_session.conversation, :show?
      return
    end

    if @call_session.inbox.present?
      authorize @call_session.inbox, :show?
      return
    end

    raise ActiveRecord::RecordNotFound, 'Recording could not be found'
  end

  def recording_available?
    recording_storage_key.present? || external_recording_url.present?
  end

  def recording_url_for_call_session
    external_recording_url || recording_api_v1_account_telephony_call_path(Current.account.id, @call_session.external_call_ref)
  end

  def external_recording_url
    return @external_recording_url if defined?(@external_recording_url)

    @external_recording_url = parsed_external_recording_url
  end

  def parsed_external_recording_url
    candidate = recording_metadata['recording_url'].presence || recording_metadata['recording_ref'].presence || @call_session.recording_ref.presence
    return if candidate.blank?

    uri = URI.parse(candidate.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def recording_file_path
    storage_key = recording_storage_key
    return if storage_key.blank?

    return unless storage_key.start_with?('voice-recordings/')

    storage_root = Rails.root.join('storage').realpath
    path = storage_root.join(storage_key).cleanpath
    return unless path.to_s.start_with?("#{storage_root}/")
    return unless File.file?(path)

    real_path = Pathname.new(File.realpath(path.to_s))
    return unless real_path.to_s.start_with?("#{storage_root}/")

    real_path.to_s
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    nil
  end

  def recording_storage_key
    recording_metadata['storage_key'].presence || recording_metadata['recording_ref'].presence || @call_session.recording_ref.presence
  end

  def recording_content_type
    content_type = recording_metadata['content_type'].to_s
    return content_type if content_type.start_with?('audio/')

    'audio/wav'
  end

  def recording_metadata
    metadata = @call_session.metadata
    recording = metadata.is_a?(Hash) ? metadata['recording'] : nil
    recording.is_a?(Hash) ? recording : {}
  end

  def calls_service
    @calls_service ||= Telephony::CallsService.new(account: Current.account)
  end

  def limit_param
    value = params[:limit].to_i
    return 50 if value <= 0

    [value, 100].min
  end
end

class RoomChannel < ApplicationCable::Channel
  def subscribed
    current_user
    current_account
    ensure_stream
    update_subscription
    broadcast_presence
  rescue ActiveRecord::RecordNotFound
    reject
  end

  def update_presence
    return if @impersonation_context && !refresh_impersonation_context!

    update_subscription
    broadcast_presence
  end

  private

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a? User
    ActionCable.server.broadcast(pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    if @impersonation_context
      callback = ->(payload) { transmit_support_payload(payload) }
      stream_from pubsub_token, coder: ActiveSupport::JSON, &callback
      stream_from "account_#{@current_account.id}", coder: ActiveSupport::JSON, &callback
      return
    end

    stream_from pubsub_token
    stream_from "account_#{@current_account.id}" if @current_account.present? && @current_user.is_a?(User)
    stream_from @current_user.auth_session_stream_name(auth_client_id) if @current_user.is_a?(User)
  end

  def transmit_support_payload(payload)
    return unless refresh_impersonation_context!

    event = payload.respond_to?(:with_indifferent_access) ? payload.with_indifferent_access : {}
    data = event[:data]
    return unless data.respond_to?(:[])
    return unless data[:account_id].to_s == @current_account.id.to_s

    transmit(payload)
  end

  def refresh_impersonation_context!
    context = SuperAdmin::ImpersonationService.context_for_websocket(
      auth_client_id,
      target_user_id: @current_user.id,
      account_id: params[:account_id],
      pubsub_token: pubsub_token
    )
    unless context && context['account_id'].to_s == @current_account&.id.to_s
      stop_all_streams
      reject
      return false
    end

    @impersonation_context = context
    true
  end

  def update_subscription
    return if @current_account.blank?

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  def auth_client_id
    @auth_client_id ||= params[:auth_client_id].presence
  end

  def current_user
    @current_user ||= if params[:user_id].blank?
                        ContactInbox.find_by!(pubsub_token: pubsub_token).contact
                      else
                        find_authenticated_user!
                      end
  end

  def find_authenticated_user!
    user = User.find(params[:user_id])
    if auth_client_id.to_s.start_with?(SuperAdmin::ImpersonationService::CLIENT_PREFIX)
      @impersonation_context = SuperAdmin::ImpersonationService.context_for_websocket(
        auth_client_id,
        target_user_id: user.id,
        account_id: params[:account_id],
        pubsub_token: pubsub_token
      )
      raise ActiveRecord::RecordNotFound unless @impersonation_context
    else
      user = User.find_by!(pubsub_token: pubsub_token, id: params[:user_id])
      raise ActiveRecord::RecordNotFound unless user.active_auth_client?(auth_client_id)
    end

    user
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         elsif @impersonation_context
                           Account.find(@impersonation_context['account_id'])
                         else
                           @current_user.accounts.find(params[:account_id])
                         end
  end
end

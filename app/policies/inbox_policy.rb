class InboxPolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account, :account_user

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @account_user = user_context[:account_user]
      @scope = scope
    end

    def resolve
      scope.where(id: user.assigned_inboxes.select(:id))
    end
  end

  def index?
    true
  end

  def show?
    # FIXME: for agent bots, lets bring this validation to policies as well in future
    return true if @user.is_a?(AgentBot)

    Current.user.assigned_inboxes.include? record
  end

  def assignable_agents?
    true
  end

  def agent_bot?
    true
  end

  def campaigns?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end

  def set_agent_bot?
    @account_user.administrator?
  end

  def avatar?
    @account_user.administrator?
  end

  def sync_templates?
    @account_user.administrator?
  end

  def whatsapp_templates?
    @account_user.administrator?
  end

  def health?
    @account_user.administrator?
  end

  def reset_secret?
    @account_user.administrator?
  end

  def refresh_whatsapp_web_qr?
    @account_user.administrator?
  end

  def reconnect_whatsapp_web?
    @account_user.administrator?
  end

  def disconnect_whatsapp_web?
    @account_user.administrator?
  end

  def repair_whatsapp_web?
    @account_user.administrator?
  end

  def whatsapp_web_diagnostics?
    @account_user.administrator?
  end

  def telegram_personal_request_code?
    @account_user.administrator?
  end

  def telegram_personal_request_qr?
    @account_user.administrator?
  end

  def telegram_personal_verify_code?
    @account_user.administrator?
  end

  def telegram_personal_verify_password?
    @account_user.administrator?
  end

  def telegram_personal_reconnect?
    @account_user.administrator?
  end

  def telegram_personal_history_sync?
    @account_user.administrator?
  end

  def telegram_personal_contacts_sync?
    @account_user.administrator?
  end

  def telegram_personal_disconnect?
    @account_user.administrator?
  end

  def telegram_personal_diagnostics?
    @account_user.administrator?
  end
end

class ApplicationPolicy
  attr_reader :user_context, :user, :record, :account, :account_user

  def initialize(user_context, record)
    @user_context = user_context
    @user = user_context[:user]
    @account = user_context[:account]
    @account_user = user_context[:account_user]
    @record = record
  end

  def index?
    false
  end

  def show?
    scope.exists?(id: record.id)
  end

  def create?
    false
  end

  def new?
    create?
  end

  def update?
    false
  end

  def edit?
    update?
  end

  def destroy?
    false
  end

  def scope
    Pundit.policy_scope!(user_context, record.class)
  end

  private

  def permission_tokens
    Array(account_user&.permissions)
  end

  def has_permission?(*permissions)
    (permission_tokens & permissions.flatten).any?
  end

  def administrator_access?
    has_permission?('administrator')
  end

  def plain_agent_access?
    account_user&.custom_role_id.blank? && has_permission?('agent')
  end

  def contact_access?
    administrator_access? || plain_agent_access? || has_permission?('contact_manage')
  end

  def runtime_access?
    administrator_access? || plain_agent_access? || has_permission?(
      'conversation_manage',
      'conversation_unassigned_manage',
      'conversation_participating_manage',
      'conversation_team_manage',
      'contact_manage',
      'crm_deal_view',
      'crm_deal_manage',
      'crm_task_view',
      'crm_task_manage'
    )
  end

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
      scope
    end
  end
end

class Crm::Tasks::RealtimeRecipients
  def initialize(account:, task:, changes: {})
    @account = account
    @task = task
    @changes = changes
  end

  # Task bodies are sent only to members who can read this task through the
  # same policy used by the API. The account stream receives a separate
  # non-sensitive invalidation for older dashboard subscribers.
  def tokens
    account.account_users.includes(:user, :custom_role).filter_map do |account_user|
      user = account_user.user
      next if user.blank? || user.pubsub_token.blank?

      user_context = { user: user, account: account, account_user: account_user }
      user.pubsub_token if Crm::TaskPolicy.new(user_context, task).show?
    end.uniq
  end

  def relay_tokens
    ["account_#{account.id}"]
  end

  private

  attr_reader :account, :task, :changes
end

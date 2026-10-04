class Crm::Deals::RealtimeRecipients
  def initialize(account:, deal:, changes: {})
    @account = account
    @deal = deal
    @changes = changes
  end

  def tokens
    account.account_users.includes(:user).filter_map do |account_user|
      user = account_user.user
      next if user.blank? || user.pubsub_token.blank?

      user_context = { user: user, account: account, account_user: account_user }
      user.pubsub_token if Crm::DealPolicy.new(user_context, deal).show?
    end.uniq
  end

  private

  attr_reader :account, :deal, :changes
end

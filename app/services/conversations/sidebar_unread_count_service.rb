class Conversations::SidebarUnreadCountService
  # The dashboard only shows the unread badge of a team. The other breakdowns (statuses, inboxes,
  # labels, pipelines, stages, appointment statuses and the overall total) are no longer counted;
  # their keys stay in the response as empty values so API and mobile clients keep the same shape.
  UNCOUNTED_UNREAD_DIMENSIONS = {
    all: 0,
    statuses: {},
    inboxes: {},
    labels: {},
    pipelines: {},
    stages: {},
    appointment_statuses: {}
  }.freeze

  attr_reader :account, :user

  def initialize(account:, user:)
    @account = account
    @user = user
  end

  def perform
    self.class.unread_counts_with(teams: team_unread_counts(unread_message_scope))
  end

  # Shared by the finders and filter services so every counts payload has the same keys.
  def self.unread_counts_with(teams:)
    UNCOUNTED_UNREAD_DIMENSIONS.deep_dup.merge(teams: teams)
  end

  private

  def team_unread_counts(scope)
    normalize_counts(scope.where.not(team_id: nil).group(:team_id).distinct.count('conversations.id'))
  end

  def accessible_conversations
    Conversations::PermissionFilterService.new(
      account.conversations,
      user,
      account
    ).perform
  end

  def unread_message_scope
    Conversations::UnreadScopeBuilder.new(scope: accessible_conversations, account: account).perform
  end

  def normalize_counts(counts)
    counts.each_with_object({}) do |(key, value), result|
      next if key.blank?

      result[key.to_s] = value
    end
  end
end

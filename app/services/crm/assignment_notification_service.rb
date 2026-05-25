class Crm::AssignmentNotificationService
  def initialize(account:, record:, user:, notification_type:, actor: nil)
    @account = account
    @record = record
    @user = user
    @notification_type = notification_type
    @actor = actor
  end

  def perform
    return unless deliverable?

    remove_previous_assignment_notifications
    create_assignment_notification
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("Skipped duplicate #{notification_type} notification for #{record.class.name}##{record.id}")
  end

  private

  attr_reader :account, :actor, :notification_type, :record, :user

  def deliverable?
    account.present? &&
      record.present? &&
      user.present? &&
      !self_assignment? &&
      account.users.exists?(id: user.id)
  end

  def self_assignment?
    actor.present? && actor.id == user.id
  end

  def remove_previous_assignment_notifications
    Notification.where(primary_actor: record, notification_type: notification_type).destroy_all
  end

  def create_assignment_notification
    NotificationBuilder.new(
      notification_type: notification_type,
      user: user,
      account: account,
      primary_actor: record,
      secondary_actor: actor
    ).perform
  end
end

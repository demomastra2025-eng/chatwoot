class NotificationFinder
  attr_reader :current_user, :current_account, :params

  RESULTS_PER_PAGE = 15

  def initialize(current_user, current_account, params = {})
    @current_user = current_user
    @current_account = current_account
    @params = params
    set_up
  end

  def notifications
    after_cursor(@notifications)
      .page(current_page)
      .per(RESULTS_PER_PAGE)
      .order(last_activity_at: sort_order, id: sort_order)
  end

  # Always the number of unread notifications, whichever list is requested:
  # the sidebar badge keeps its value while the archive tab is browsed.
  def unread_count
    @unread_notifications.count
  end

  # The size of the requested list; a cursor does not change it.
  def count
    @notifications.count
  end

  private

  def set_up
    find_all_notifications
    filter_inbox_notification_types
    filter_snoozed_notifications
    @unread_notifications = @notifications.where(read_at: nil)
    filter_read_notifications
  end

  def account_notifications
    current_user.notifications.where(account_id: @current_account.id)
  end

  def find_all_notifications
    @notifications = account_notifications
  end

  def filter_inbox_notification_types
    notification_setting = current_user.notification_settings.find_by(account_id: @current_account.id)
    return if notification_setting.blank?

    selected_types = notification_setting.selected_inbox_flags.filter_map do |flag|
      flag.to_s.delete_prefix('inbox_').presence
    end
    return @notifications = @notifications.none if selected_types.blank?

    @notifications = @notifications.where(notification_type: selected_types)
  end

  def filter_snoozed_notifications
    @notifications = @notifications.where(snoozed_until: nil) unless type_included?('snoozed')
  end

  # `archived` lists notifications the user already read (the panel archive);
  # `read` lists read and unread ones together.
  def filter_read_notifications
    if type_included?('archived')
      @notifications = @notifications.where.not(read_at: nil)
    elsif !type_included?('read')
      @notifications = @notifications.where(read_at: nil)
    end
  end

  # Cursor pages for lists that change while they are browsed (the panel
  # archives notifications between pages): `cursor_id` is the last
  # notification of the previous page and the next page starts right after
  # it, however many notifications were archived or added meanwhile.
  def after_cursor(scope)
    cursor_id = integer_param(:cursor_id)
    return scope if cursor_id.nil?

    # Looked up among all notifications: the cursor may be archived by now.
    cursor = account_notifications.find_by(id: cursor_id)
    return after_missing_cursor(scope) if cursor.blank?

    operator = descending? ? '<' : '>'
    scope.where("(notifications.last_activity_at, notifications.id) #{operator} (?, ?)", cursor.last_activity_at, cursor.id)
  end

  # A newer notification of the same conversation replaces the cursor
  # (Notification::RemoveDuplicateNotificationJob). The whole second of its
  # `cursor_last_activity_at` is listed again then, so nothing is skipped.
  def after_missing_cursor(scope)
    seconds = integer_param(:cursor_last_activity_at)
    return scope if seconds.nil?

    if descending?
      scope.where('notifications.last_activity_at < ?', Time.zone.at(seconds + 1))
    else
      scope.where('notifications.last_activity_at >= ?', Time.zone.at(seconds))
    end
  end

  def integer_param(key)
    Integer(params[key].to_s, 10, exception: false)
  end

  def type_included?(type)
    (params[:includes] || []).include?(type)
  end

  def current_page
    params[:page] || 1
  end

  def sort_order
    params[:sort_order] || :desc
  end

  def descending?
    sort_order.to_s.downcase != 'asc'
  end
end

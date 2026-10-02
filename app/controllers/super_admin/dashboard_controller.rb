# frozen_string_literal: true

class SuperAdmin::DashboardController < SuperAdmin::ApplicationController
  include ActionView::Helpers::NumberHelper

  def index
    @data = begin
      Conversation.unscoped.group_by_day(:created_at, range: 30.days.ago..2.seconds.ago).count.to_a
    rescue StandardError
      []
    end
    @accounts_count = number_with_delimiter(Account.count)
    @users_count = number_with_delimiter(User.count)
    @inboxes_count = number_with_delimiter(Inbox.count)
    @conversations_count = number_with_delimiter(Conversation.count)

    force_refresh = params[:refresh].present? || params[:force_refresh].present?
    @health_accounts, @health_summary = SuperAdmin::HealthMatrixService.build(force_refresh: force_refresh)
  end
end

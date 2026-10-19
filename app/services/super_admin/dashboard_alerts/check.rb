# frozen_string_literal: true

# What every check of SuperAdmin::DashboardAlerts has in common: it answers `alerts` (a list of the hashes described there)
# and builds them with the Russian texts of `super_admin.alerts.<key>.title` / `.text`. The texts are Russian whatever the
# language of the request: the answer is cached for every viewer.
class SuperAdmin::DashboardAlerts::Check
  def alerts = raise(NotImplementedError)

  private

  def routes
    Rails.application.routes.url_helpers
  end

  def text(key, **)
    I18n.t("super_admin.alerts.#{key}", locale: :ru, **)
  end

  # extra: count (the number of things found; the items by default), more_url, title and body (the texts of the key by default)
  def alert(key, severity:, items:, **extra)
    {
      key: key.to_s.tr('.', '_'), severity: severity, title: extra.fetch(:title) { text("#{key}.title") },
      text: extra.fetch(:body) { text("#{key}.text") }, count: extra.fetch(:count, items.size),
      items: items.first(SuperAdmin::DashboardAlerts::LIST_LIMIT), more_url: extra[:more_url]
    }
  end

  def account_item(id, name, note = nil)
    { label: name, url: routes.super_admin_account_path(id), note: note }
  end

  def accounts_list_url(filter)
    routes.super_admin_accounts_path(search: filter)
  end
end

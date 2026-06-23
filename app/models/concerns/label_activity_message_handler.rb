module LabelActivityMessageHandler
  extend ActiveSupport::Concern

  private

  def create_label_added(user_name, labels = [])
    create_label_change_activity('added', user_name, labels)
  end

  def create_label_removed(user_name, labels = [])
    create_label_change_activity('removed', user_name, labels)
  end

  def create_label_change_activity(change_type, user_name, labels = [])
    return unless labels.size.positive?

    display_labels = display_names_for_label_titles(labels)
    content = I18n.t("conversations.activity.labels.#{change_type}", user_name: user_name, labels: display_labels.join(', '))
    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content)) if content
  end

  def display_names_for_label_titles(label_titles)
    titles = Array(label_titles).map(&:to_s)
    labels_by_title = account.labels.where(title: titles).index_by(&:title)

    titles.map do |title|
      labels_by_title[title]&.display_title.presence || title
    end
  end
end
